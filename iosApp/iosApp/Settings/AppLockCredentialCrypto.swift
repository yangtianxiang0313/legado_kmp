import CommonCrypto
import Foundation
import Security

enum AppLockFailure: LocalizedError {
    case wrongPassword, emptyPassword, passwordTooLong, mismatch, alreadyEnabled, notEnabled
    case storageUnavailable, damagedCredential, credentialChanged, busy, inactive
    case retryAfter(Int)

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "密码错误"
        case .emptyPassword: return "密码不能为空"
        case .passwordTooLong: return "密码不能超过 1024 字节"
        case .mismatch: return "两次输入的密码不一致"
        case .alreadyEnabled, .credentialChanged: return "应用锁状态已变化，请返回后重试"
        case .notEnabled: return "尚未设置应用密码"
        case .storageUnavailable: return "暂时无法访问安全凭据，请解锁设备后重试"
        case .damagedCredential: return "应用锁凭据不完整，无法解锁。请保留本机数据，不要重置或覆盖凭据。"
        case .busy: return "另一项密码操作正在进行，请稍后重试"
        case .inactive: return "应用已离开前台，请重新输入密码"
        case .retryAfter(let seconds): return "密码尝试过于频繁，请在 \(seconds) 秒后重试"
        }
    }
}

enum AppLockCredentialCrypto {
    static let rounds = 600_000

    static func validateNewPassword(_ password: String, confirmation: String) throws {
        guard !password.isEmpty else { throw AppLockFailure.emptyPassword }
        guard password.utf8.count <= 1024 else { throw AppLockFailure.passwordTooLong }
        guard password == confirmation else { throw AppLockFailure.mismatch }
    }

    static func salt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppLockFailure.storageUnavailable
        }
        return Data(bytes)
    }

    static func derive(_ password: String, salt: Data, rounds: Int) throws -> Data {
        // Called exclusively on the credential store's serial worker queue.
        var input = Array(password.utf8)
        defer { input.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var result = [UInt8](repeating: 0, count: 32)
        let status = input.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), input.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw AppLockFailure.storageUnavailable }
        return Data(result)
    }

    static func verifyLegacy(_ password: String, salt: String, digest: Data) -> Bool {
        var input = Data((salt + password).utf8)
        defer { input.resetBytes(in: 0..<input.count) }
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        input.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(input.count), &result) }
        return constantTimeEqual(Data(result), digest)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

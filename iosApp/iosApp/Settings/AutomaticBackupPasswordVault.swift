import CryptoKit
import Foundation
import Security

/// Only the AES-GCM ciphertext and its device-only wrapping key are persisted, never the user password.
@MainActor
final class AutomaticBackupPasswordVault {
    private let service: String
    private var sessionScope: String?
    private var sessionPassword: String?

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.legado.kmp.iosApp") {
        service = bundleIdentifier + ".automatic-backup.v1"
    }

    func authorize(password: String, scope: String, rememberOnDevice: Bool) throws {
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            password.utf8.count <= 4096, valid(scope)
        else { throw failure("请输入有效的非空备份密码（最多 4096 字节）") }
        if rememberOnDevice {
            let key = try deviceKey(create: true)
            let sealed = try AES.GCM.seal(Data(password.utf8), using: key, authenticating: Data(scope.utf8))
            guard let combined = sealed.combined else { throw failure("备份密码加密失败，未保存") }
            try write(combined, account: "password." + scope)
        } else {
            // Choosing session-only explicitly removes any previously remembered password for this scope.
            try remove(account: "password." + scope)
        }
        sessionScope = scope
        sessionPassword = password
    }

    func password(scope: String) throws -> String? {
        guard valid(scope) else { throw failure("备份配置无效") }
        if sessionScope == scope, let sessionPassword { return sessionPassword }
        guard let encrypted = try read(account: "password." + scope) else { return nil }
        do {
            let sealed = try AES.GCM.SealedBox(combined: encrypted)
            var plain = try AES.GCM.open(sealed, using: deviceKey(create: false), authenticating: Data(scope.utf8))
            defer { plain.resetBytes(in: 0..<plain.count) }
            guard let password = String(data: plain, encoding: .utf8),
                !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw failure("本机备份密码无法读取，请重新设置") }
            // Remembered secrets are decrypted only for one operation, not retained as a session cache.
            return password
        } catch {
            throw failure("本机备份密码暂不可用，请解锁设备或重新设置")
        }
    }

    func hasRememberedPassword(scope: String) throws -> Bool {
        try read(account: "password." + scope) != nil
    }

    func hasSessionPassword(scope: String) -> Bool { sessionScope == scope && sessionPassword != nil }

    func clearSession() { sessionPassword = nil; sessionScope = nil }

    func forget(scope: String) throws {
        try remove(account: "password." + scope)
        if sessionScope == scope { clearSession() }
    }

    private func deviceKey(create: Bool) throws -> SymmetricKey {
        if let bytes = try read(account: "device-key") {
            guard bytes.count == 32 else { throw failure("本机密码密钥损坏，请重新设置") }
            return SymmetricKey(data: bytes)
        }
        guard create else { throw failure("本机密码密钥不可用，请重新设置") }
        let key = SymmetricKey(size: .bits256)
        var bytes = key.withUnsafeBytes { Data($0) }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        try write(bytes, account: "device-key")
        return key
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
        ]
    }

    private func read(account: String) throws -> Data? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 8192 else {
            throw failure("安全存储暂不可用，请解锁设备后重试")
        }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            values.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw failure("安全存储写入失败，未保存备份密码")
            }
        } else if status != errSecSuccess {
            throw failure("安全存储写入失败，未保存备份密码")
        }
    }

    private func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure("安全存储删除失败，请解锁设备后重试")
        }
    }

    private func valid(_ scope: String) -> Bool {
        scope.count == 64 && scope.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.automaticBackup.password", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

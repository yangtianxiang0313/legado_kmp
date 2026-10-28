import Foundation
import Security
import LocalAuthentication

enum AppLockStatus: Equatable {
    case checking, disabled, enabled, unavailable
}

/// Keychain and all password derivation are serialized off the main thread.
final class AppLockCredentialStore: @unchecked Sendable {
    struct Mutation {
        fileprivate let expected: Snapshot
        fileprivate let record: Record
    }

    fileprivate struct Record: Codable {
        let version: Int
        let enabled: Bool
        let rounds: Int?
        let salt: Data?
        let digest: Data?

        static let disabled = Record(version: 1, enabled: false, rounds: nil, salt: nil, digest: nil)

        func validate() throws {
            guard version == 1 else { throw AppLockFailure.damagedCredential }
            if enabled {
                guard let rounds, (600_000...2_000_000).contains(rounds),
                    salt?.count == 32, digest?.count == 32
                else { throw AppLockFailure.damagedCredential }
            } else {
                guard rounds == nil, salt == nil, digest == nil else { throw AppLockFailure.damagedCredential }
            }
        }
    }

    fileprivate enum Snapshot: Equatable {
        case absent
        case keychain(Data)
        case legacy(hash: String, salt: String)
    }

    private let queue = DispatchQueue(label: "io.legado.app-lock.credentials", qos: .userInitiated)
    private let defaults = UserDefaults.standard
    private let bundleID = Bundle.main.bundleIdentifier ?? ""
    private let legacyHash = "appLockPasswordHash"
    private let legacySalt = "appLockPasswordSalt"
    private let requiredKey = "appLockCredentialRequired"
    private var failedAttempts = 0
    private var nextAttemptAt: TimeInterval = 0

    func status() async throws -> AppLockStatus {
        try await work {
            switch try self.read() {
            case .absent: return .disabled
            case .legacy: return .enabled
            case .keychain(let data): return try self.decode(data).enabled ? .enabled : .disabled
            }
        }
    }

    func verify(_ password: String) async throws {
        try await work {
            let snapshot = try self.read()
            try self.authenticate(password, snapshot: snapshot)
            if case .legacy = snapshot {
                let record = try self.makeRecord(password)
                try self.write(record, replacing: snapshot)
            }
        }
    }

    func prepareEnable(_ password: String) async throws -> Mutation {
        try await work {
            let snapshot = try self.read()
            guard try !self.isEnabled(snapshot) else { throw AppLockFailure.alreadyEnabled }
            return Mutation(expected: snapshot, record: try self.makeRecord(password))
        }
    }

    func prepareChange(oldPassword: String, newPassword: String) async throws -> Mutation {
        try await work {
            let snapshot = try self.read()
            try self.authenticate(oldPassword, snapshot: snapshot)
            return Mutation(expected: snapshot, record: try self.makeRecord(newPassword))
        }
    }

    func prepareDisable(_ password: String) async throws -> Mutation {
        try await work {
            let snapshot = try self.read()
            try self.authenticate(password, snapshot: snapshot)
            return Mutation(expected: snapshot, record: .disabled)
        }
    }

    func commit(_ mutation: Mutation) async throws -> AppLockStatus {
        try await work {
            guard try self.read() == mutation.expected else { throw AppLockFailure.credentialChanged }
            try self.write(mutation.record, replacing: mutation.expected)
            return mutation.record.enabled ? .enabled : .disabled
        }
    }

    private func work<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleID + ".app-lock",
            kSecAttrAccount as String: "credential-v1",
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func read() throws -> Snapshot {
        guard !bundleID.isEmpty else { throw AppLockFailure.storageUnavailable }
        var request = query
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = authentication
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count <= 4096 else { throw AppLockFailure.damagedCredential }
            let record = try decode(data)
            defaults.set(record.enabled, forKey: requiredKey)
            return .keychain(data)
        }
        guard status == errSecItemNotFound else { throw AppLockFailure.storageUnavailable }
        let hash = defaults.object(forKey: legacyHash)
        let salt = defaults.object(forKey: legacySalt)
        if hash != nil || salt != nil {
            guard let hash = hash as? String, let salt = salt as? String,
                hash.utf8.count == 44, salt.utf8.count == 24,
                Data(base64Encoded: hash)?.count == 32, Data(base64Encoded: salt)?.count == 16
            else { throw AppLockFailure.damagedCredential }
            return .legacy(hash: hash, salt: salt)
        }
        // A disappeared credential must never disable an existing lock.
        guard !defaults.bool(forKey: requiredKey) else { throw AppLockFailure.damagedCredential }
        return .absent
    }

    private func decode(_ data: Data) throws -> Record {
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else {
            throw AppLockFailure.damagedCredential
        }
        try record.validate()
        return record
    }

    private func isEnabled(_ snapshot: Snapshot) throws -> Bool {
        switch snapshot {
        case .absent: return false
        case .legacy: return true
        case .keychain(let data): return try decode(data).enabled
        }
    }

    private func authenticate(_ password: String, snapshot: Snapshot) throws {
        let remaining = nextAttemptAt - ProcessInfo.processInfo.systemUptime
        guard remaining <= 0 else { throw AppLockFailure.retryAfter(Int(ceil(remaining))) }
        guard try isEnabled(snapshot) else { throw AppLockFailure.notEnabled }
        guard password.utf8.count <= 65_536 else { throw AppLockFailure.passwordTooLong }
        let matches: Bool
        switch snapshot {
        case .legacy(let hash, let salt):
            guard let digest = Data(base64Encoded: hash) else { throw AppLockFailure.damagedCredential }
            matches = AppLockCredentialCrypto.verifyLegacy(password, salt: salt, digest: digest)
        case .keychain(let data):
            let record = try decode(data)
            guard let salt = record.salt, let digest = record.digest, let rounds = record.rounds else {
                throw AppLockFailure.damagedCredential
            }
            matches = AppLockCredentialCrypto.constantTimeEqual(
                try AppLockCredentialCrypto.derive(password, salt: salt, rounds: rounds), digest)
        case .absent: throw AppLockFailure.notEnabled
        }
        guard matches else {
            failedAttempts = min(failedAttempts + 1, 10)
            if failedAttempts >= 5 {
                nextAttemptAt = ProcessInfo.processInfo.systemUptime + min(30, pow(2, Double(failedAttempts - 5)))
            }
            throw AppLockFailure.wrongPassword
        }
        failedAttempts = 0
        nextAttemptAt = 0
    }

    private func makeRecord(_ password: String) throws -> Record {
        let salt = try AppLockCredentialCrypto.salt()
        return Record(
            version: 1, enabled: true, rounds: AppLockCredentialCrypto.rounds, salt: salt,
            digest: try AppLockCredentialCrypto.derive(password, salt: salt, rounds: AppLockCredentialCrypto.rounds))
    }

    private func write(_ record: Record, replacing snapshot: Snapshot) throws {
        guard !bundleID.isEmpty else { throw AppLockFailure.storageUnavailable }
        try record.validate()
        let data = try JSONEncoder().encode(record)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status: OSStatus
        if case .keychain = snapshot {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppLockFailure.storageUnavailable }
        defaults.set(record.enabled, forKey: requiredKey)
        // Cleanup follows the successful atomic Keychain write, including the disabled tombstone.
        defaults.removeObject(forKey: legacyHash)
        defaults.removeObject(forKey: legacySalt)
    }
}

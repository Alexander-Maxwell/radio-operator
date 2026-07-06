import Foundation
import CryptoKit
import Security

/// AES-256-GCM encryption for the dictation-history columns. The key is
/// generated once and lives in the login Keychain as a non-synchronizable
/// generic password, so it does not iCloud-sync. Deleting the key is a
/// cryptographic erase of every encrypted row — the panic-wipe primitive.
///
/// Note on at-rest protection: the login (file-based) Keychain does not honor
/// `kSecAttrAccessible` protection classes — those apply to the iOS-style
/// data-protection Keychain, which on macOS needs an application-identifier
/// entitlement this self-signed build does not carry. So the honest posture is:
/// the item is encrypted by the login keychain (unlocked with the login
/// password) and never syncs; it is NOT hardware device-bound. Adding
/// `kSecUseDataProtectionKeychain` here would fail with errSecMissingEntitlement
/// and trip the plaintext fallback — strictly worse — so we don't.
///
/// Injectable so tests run against a throwaway key with zero Keychain access.
struct HistoryCipher: Sendable {
    let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// nonce ‖ ciphertext ‖ tag, ready to store as a BLOB.
    func seal(_ text: String) -> Data? {
        try? AES.GCM.seal(Data(text.utf8), using: key).combined
    }

    func open(_ data: Data) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// Shown in place of a row that cannot be decrypted (wrong/missing key).
    static let unreadableMarker = "[unreadable — history key missing]"

    // MARK: - Keychain-backed app key

    private static let service = "com.warroom.radiooperator"
    private static let account = "history-db-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Reads the persistent key, or nil if it is absent/unreadable.
    private static func readKey() -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Loads the persistent history key, creating it on first use.
    /// Returns nil only when the Keychain is genuinely unavailable; the caller
    /// falls back to plaintext and must say so loudly.
    static func loadOrCreate() -> HistoryCipher? {
        // Fast path: key already exists.
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return HistoryCipher(key: SymmetricKey(data: data))
        }
        guard status == errSecItemNotFound else {
            NSLog("HistoryCipher: Keychain read failed (\(status)) — history will be stored UNENCRYPTED this session")
            return nil
        }

        // Create it. kSecAttrSynchronizable is left unset, so the item never
        // iCloud-syncs.
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        var add = baseQuery
        add[kSecValueData as String] = keyData
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return HistoryCipher(key: key)
        }
        // Lost a first-launch race with another process/instance: the winner's
        // key is now present — read and use it rather than downgrading.
        if addStatus == errSecDuplicateItem, let existing = readKey() {
            return HistoryCipher(key: existing)
        }
        NSLog("HistoryCipher: Keychain write failed (\(addStatus)) — history will be stored UNENCRYPTED this session")
        return nil
    }

    /// Cryptographic erase: deletes the key so no encrypted row is ever
    /// recoverable. Returns true if the key is gone afterward.
    ///
    /// Hard backstop: refuses to run under `--run-tests` so a future unit test
    /// can never delete the production key (the `make test` landmine).
    @discardableResult
    static func destroyKey() -> Bool {
        guard !CommandLine.arguments.contains("--run-tests") else {
            NSLog("HistoryCipher.destroyKey: refused under --run-tests")
            return false
        }
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

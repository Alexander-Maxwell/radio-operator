import Foundation
import CryptoKit
import Security

/// AES-256-GCM encryption for the dictation-history columns. The key is
/// generated once and lives in the login Keychain, device-only (never syncs
/// to iCloud Keychain). Deleting the key is a cryptographic erase of every
/// encrypted row — the future panic-wipe primitive.
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

    /// Loads the persistent history key, creating it on first use.
    /// Returns nil only when the Keychain is unavailable; the caller falls
    /// back to plaintext and must say so loudly.
    static func loadOrCreate() -> HistoryCipher? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return HistoryCipher(key: SymmetricKey(data: data))
        }
        guard status == errSecItemNotFound else {
            NSLog("HistoryCipher: Keychain read failed (\(status)) — history will be stored UNENCRYPTED")
            return nil
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            // Device-bound: usable after first unlock (dictation can land while
            // the screen is locked mid-session), never leaves this Mac.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("HistoryCipher: Keychain write failed (\(addStatus)) — history will be stored UNENCRYPTED")
            return nil
        }
        return HistoryCipher(key: key)
    }
}

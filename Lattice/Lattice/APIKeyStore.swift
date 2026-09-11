import Combine
import Foundation
import Security

/// Stores provider API keys in the login Keychain (generic passwords) instead of
/// UserDefaults, with a one-time migration that erases legacy plaintext copies.
@MainActor
final class APIKeyStore: ObservableObject {
    static let shared = APIKeyStore()

    @Published private(set) var anthropicKey: String
    @Published private(set) var openAIKey: String
    @Published private(set) var zaiKey: String

    private static let service = "com.lattice.app.keys"

    private enum Account: String, CaseIterable {
        case anthropic
        case openAI = "openai"
        case zai
    }

    private init() {
        anthropicKey = Self.read(.anthropic)
        openAIKey = Self.read(.openAI)
        zaiKey = Self.read(.zai)
    }

    func key(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return anthropicKey
        case .openAI: return openAIKey
        case .zai: return zaiKey
        }
    }

    func setKey(_ value: String, for provider: LLMProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .anthropic: anthropicKey = trimmed
        case .openAI: openAIKey = trimmed
        case .zai: zaiKey = trimmed
        }
        Self.write(trimmed, account: Self.account(for: provider))
    }

    // MARK: Custom provider keys

    func customKey(id: UUID) -> String {
        Self.readAccount("custom.\(id.uuidString)")
    }

    func setCustomKey(_ value: String, id: UUID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.write(trimmed, account: "custom.\(id.uuidString)")
    }

    func removeCustomKey(id: UUID) {
        Self.deleteAccount("custom.\(id.uuidString)")
    }

    private static func account(for provider: LLMProvider) -> Account {
        switch provider {
        case .anthropic: return .anthropic
        case .openAI: return .openAI
        case .zai: return .zai
        }
    }

    // MARK: - Legacy migration

    private static let legacyUserDefaultsKeys: [(udKey: String, account: Account)] = [
        ("anthropicAPIKey", .anthropic),
        ("openAIAPIKey", .openAI),
        ("zaiAPIKey", .zai),
    ]

    /// Moves any plaintext keys from UserDefaults into the Keychain, then deletes the
    /// UserDefaults copies. Safe to call repeatedly; only non-empty legacy keys act.
    static func migrateLegacyKeysFromUserDefaults() {
        let defaults = UserDefaults.standard
        for legacy in legacyUserDefaultsKeys {
            guard let value = defaults.string(forKey: legacy.udKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { continue }
            if read(legacy.account).isEmpty {
                write(value, account: legacy.account)
            }
            defaults.removeObject(forKey: legacy.udKey)
        }
    }

    // MARK: - Keychain

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ account: Account) -> String {
        readAccount(account.rawValue)
    }

    private static func readAccount(_ account: String) -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func write(_ value: String, account: Account) {
        write(value, account: account.rawValue)
    }

    private static func write(_ value: String, account: String) {
        if value.isEmpty {
            deleteAccount(account)
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func deleteAccount(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

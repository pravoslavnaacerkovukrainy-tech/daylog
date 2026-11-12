import Foundation
import Security

/// Ключ Groq в Связке ключей этого Mac. В файл дневника не пишется.
enum GroqKeyStore {
    static let service = "local.daylog.app.groq"
    static let account = "api-key"

    /// Сначала Связка ключей, затем переменная окружения запуска `GROQ_API_KEY`.
    static func resolve() -> String? {
        if let saved = load() { return saved }
        return validKey(ProcessInfo.processInfo.environment["GROQ_API_KEY"] ?? "")
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return validKey(text)
    }

    static func save(_ key: String) throws {
        guard let trimmed = validKey(key) else { throw GroqKeyStoreError.invalidKey }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw GroqKeyStoreError.status(status) }
            return
        }
        guard update == errSecSuccess else { throw GroqKeyStoreError.status(update) }
    }

    static func validKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("gsk_"), (5...512).contains(key.utf8.count), key.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        return key
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GroqKeyStoreError.status(status)
        }
    }
}

enum GroqKeyStoreError: Error, LocalizedError {
    case invalidKey
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Вставьте ключ из Groq Console. Ключ Groq начинается с gsk_."
        case .status(let code):
            if let message = SecCopyErrorMessageString(code, nil) as String? {
                return "Связка ключей: \(message)"
            }
            return "Связка ключей не сохранила ключ (код \(code))."
        }
    }
}

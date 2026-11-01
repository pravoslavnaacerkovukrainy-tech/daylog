import Foundation
import Security

/// Ключ xAI в Связке ключей этого Mac. В файл дневника не пишется.
enum XAIKeyStore {
    static let service = "local.daylog.app.xai"
    static let account = "api-key"

    /// Сначала Связка ключей, затем переменная окружения запуска `XAI_API_KEY`.
    static func resolve() -> String? {
        if let saved = load() { return saved }
        let env = ProcessInfo.processInfo.environment["XAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return env.isEmpty ? nil : env
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftPolishError.noKey }
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
            guard status == errSecSuccess else { throw XAIKeyStoreError.status(status) }
            return
        }
        guard update == errSecSuccess else { throw XAIKeyStoreError.status(update) }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw XAIKeyStoreError.status(status)
        }
    }
}

enum XAIKeyStoreError: Error, LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let code):
            if let message = SecCopyErrorMessageString(code, nil) as String? {
                return "Связка ключей: \(message)"
            }
            return "Связка ключей не сохранила ключ (код \(code))."
        }
    }
}

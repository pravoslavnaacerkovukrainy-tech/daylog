import Foundation

public enum QwenRegion: String, CaseIterable, Identifiable {
    case singapore = "ap-southeast-1"
    case frankfurt = "eu-central-1"
    case virginia = "us-east-1"
    case tokyo = "ap-northeast-1"
    case hongKong = "cn-hongkong"
    case beijing = "cn-beijing"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .singapore: return "Сингапур"
        case .frankfurt: return "Франкфурт"
        case .virginia: return "Вирджиния"
        case .tokyo: return "Токио"
        case .hongKong: return "Гонконг"
        case .beijing: return "Пекин"
        }
    }
    public var endpoint: URL {
        URL(string: "https://\(rawValue).maas.qwencloudapi.com/compatible-mode/v1/chat/completions")!
    }
}

/// Общие настройки и разбор ответа QwenCloud Chat Completions.
public enum QwenChat {
    public static let model = "qwen3.8-flash"
    public static let regionPreference = "qwencloud.region"
    public static var endpoint: URL {
        let region = QwenRegion(rawValue: UserDefaults.standard.string(forKey: regionPreference) ?? "") ?? .singapore
        return region.endpoint
    }
    public static func extractText(_ data: Data) throws -> String {
        try extractText(data) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    static func extractText(_ data: Data, cleanOutput: (String) -> String) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw DraftPolishError.badResponse
        }
        if choice["finish_reason"] as? String == "length" {
            throw DraftPolishError.truncatedResponse
        }
        // reasoning_content и tool_calls не подменяют итоговый текст.
        guard let content = message["content"] as? String else {
            throw DraftPolishError.badResponse
        }
        let text = cleanOutput(content)
        guard !text.isEmpty else { throw DraftPolishError.badResponse }
        return text
    }
    public static func stripCodeFence(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "^```[A-Za-z]*\\n?", with: "", options: .regularExpression)
            if let fence = s.range(of: "```", options: .backwards) {
                s = String(s[..<fence.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}

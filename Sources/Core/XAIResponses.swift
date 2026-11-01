import Foundation

/// Общий разбор текстового ответа xAI Responses API.
public enum XAIResponses {
    public static func extractText(_ data: Data) throws -> String {
        try extractText(data) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Очистка участвует в выборе fallback, чтобы сохранить поведение вызывающего кода.
    static func extractText(_ data: Data, cleanOutput: (String) -> String) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DraftPolishError.badResponse
        }
        if let output = json["output"] as? [Any] {
            var parts: [String] = []
            for item in output {
                guard let obj = item as? [String: Any] else { continue }
                if (obj["type"] as? String) == "reasoning" { continue }
                if let content = obj["content"] as? String {
                    parts.append(content)
                    continue
                }
                guard let blocks = obj["content"] as? [Any] else { continue }
                for block in blocks {
                    guard let piece = block as? [String: Any] else { continue }
                    let kind = piece["type"] as? String
                    guard kind == nil || kind == "output_text" || kind == "text" else { continue }
                    if let text = piece["text"] as? String { parts.append(text) }
                }
            }
            let cleaned = cleanOutput(parts.joined(separator: "\n"))
            if !cleaned.isEmpty { return cleaned }
        }
        if let direct = json["output_text"] as? String {
            let cleaned = cleanOutput(direct)
            if !cleaned.isEmpty { return cleaned }
        }
        throw DraftPolishError.badResponse
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

import Foundation

/// Превращение сумбурного наброска в заметку {заголовок, тело} через QwenCloud Chat Completions API.
/// В запрос попадает только текст наброска. Дневник, план и другие заметки не передаются.
public enum NotePolish {
    public static let model = QwenChat.model
    public static var endpoint: URL { QwenChat.endpoint }
    public static let maxCharacters = 6_000

    public static let systemPrompt = """
    Из сырого наброска сделай чистую заметку. \
    Верни СТРОГО JSON-объект {"title": "...", "body": "..."} и ничего кроме него. \
    title — короткий, до ~60 знаков. body — связный, по возможности структурированный текст заметки. \
    Сохрани все факты, имена и числа. Ничего не выдумывай и не оценивай. Язык — как у наброска.
    """

    /// Обычный запрос Chat Completions; условия обработки определяет QwenCloud.
    public static func requestBody(draft: String) throws -> Data {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DraftPolishError.empty }
        guard text.count <= maxCharacters else { throw DraftPolishError.tooLong(text.count) }
        let payload: [String: Any] = [
            "model": model,
            "enable_thinking": false,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public static func request(draft: String, apiKey: String) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try requestBody(draft: draft)
        return req
    }

    /// Разбор ответа: текст → снятие ограды → JSON {title, body}; при неудаче — фолбэк.
    public static func parse(_ data: Data) throws -> (title: String, body: String) {
        let text = try QwenChat.extractText(data)
        let unfenced = QwenChat.stripCodeFence(text)
        if let d = unfenced.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let rawBody = obj["body"] as? String {
            let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (title, body)
            }
        }
        // Фолбэк: весь текст — тело; заголовок — первая непустая строка (до 60 знаков).
        // Если после очистки ничего не осталось — это не пустая заметка, а неудачный ответ.
        let fallbackBody = unfenced.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackBody.isEmpty else { throw DraftPolishError.badResponse }
        let firstLine = unfenced.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return (String(firstLine.prefix(60)), fallbackBody)
    }
}

public struct NotePolishClient {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func polish(draft: String, apiKey: String) async throws -> (title: String, body: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftPolishError.noKey }
        let req = try NotePolish.request(draft: draft, apiKey: trimmed)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else { throw DraftPolishError.badResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            throw DraftPolishError.http(http.statusCode, DraftPolish.errorMessage(from: data).replacingOccurrences(of: trimmed, with: "[ключ скрыт]"))
        }
        return try NotePolish.parse(data)
    }
}

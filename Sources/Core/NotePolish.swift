import Foundation

/// Превращение сумбурного наброска в заметку {заголовок, тело} через Groq Chat Completions API.
/// В запрос попадает только текст наброска. Дневник, план и другие заметки не передаются.
public enum NotePolish {
    public static let model = GroqChat.model
    public static var endpoint: URL { GroqChat.endpoint }
    public static let maxCharacters = 6_000

    public static let systemPrompt = """
    Из сырого наброска сделай чистую заметку. \
    Верни СТРОГО JSON-объект {"title": "...", "body": "..."} и ничего кроме него. \
    title - короткий, до ~60 знаков. body - связный, по возможности структурированный текст заметки. \
    Сохрани все факты, имена и числа. Ничего не выдумывай и не оценивай. Язык - как у наброска.
    """

    /// Обычный запрос Chat Completions; условия обработки определяет Groq.
    public static func requestBody(draft: String) throws -> Data {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DraftPolishError.empty }
        guard text.count <= maxCharacters else { throw DraftPolishError.tooLong(text.count, limit: maxCharacters) }
        return try GroqChat.requestBody(messages: [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": text],
        ], jsonObject: true)
    }

    public static func request(draft: String, apiKey: String) throws -> URLRequest {
        try GroqChat.request(body: requestBody(draft: draft), apiKey: apiKey)
    }

    /// Разбор ответа: текст → снятие ограды → JSON {title, body}; при неудаче - фолбэк.
    public static func parse(_ data: Data) throws -> (title: String, body: String) {
        let text = try GroqChat.extractText(data)
        let unfenced = GroqChat.stripCodeFence(text)
        if let d = unfenced.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let rawBody = obj["body"] as? String {
            let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (title, body)
            }
        }
        // Фолбэк: весь текст - тело; заголовок - первая непустая строка (до 60 знаков).
        // Если после очистки ничего не осталось - это не пустая заметка, а неудачный ответ.
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

    public init(session: URLSession = GroqChat.session) {
        self.session = session
    }

    public func polish(draft: String, apiKey: String) async throws -> (title: String, body: String) {
        let request = try NotePolish.request(draft: draft, apiKey: apiKey)
        return try NotePolish.parse(await GroqChat.send(request, using: session))
    }
}

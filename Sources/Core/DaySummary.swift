import Foundation

/// Одноразовый спокойный итог прожитого дня через Groq Chat Completions API.
/// В запрос попадают только записи выбранного дня. План и другие дни не передаются.
/// Ответ не сохраняется приложением и не записывается в `entries.json`.
public enum DaySummary {
    public static let model = GroqChat.model
    public static var endpoint: URL { GroqChat.endpoint }
    public static let maxContextCharacters = 8_000

    public static let systemPrompt = """
    Ты подводишь спокойный итог одного прожитого дня по записям дневника ниже. \
    Верни 2–4 коротких фразы на языке записей. Сохрани факты, имена и числа. \
    Не оценивай, не хвали, не давай советов и мотивации; не перечисляй, чего не сделано. \
    Ничего не выдумывай сверх записей. Если в записях есть «на чём остановился», \
    можно мягко напомнить, к чему стоит вернуться. Без кавычек, списков и пояснений.
    """

    /// Записи дня в текст для запроса: «HH:mm - текст» и, при наличии, строка контекста.
    /// Многострочный текст переносится с отступом, чтобы не ломать перечисление.
    public static func buildDayText(_ entries: [DiaryEntry]) -> String {
        entries.map { entry in
            let text = entry.text.replacingOccurrences(of: "\n", with: "\n  ")
            var block = "\(DiaryFormat.time(entry.timestamp)) - \(text)"
            if let context = entry.context?.trimmingCharacters(in: .whitespacesAndNewlines),
               !context.isEmpty {
                let ctx = context.replacingOccurrences(of: "\n", with: "\n    ")
                block += "\n  на чём остановился: \(ctx)"
            }
            return block
        }.joined(separator: "\n\n")
    }

    public static func buildInput(entries: [DiaryEntry]) throws -> [[String: Any]] {
        let dayText = buildDayText(entries).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dayText.isEmpty else { throw DraftPolishError.empty }
        guard dayText.count <= maxContextCharacters else {
            throw DraftPolishError.contextTooLarge(dayText.count)
        }
        return [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": dayText],
        ]
    }

    /// Обычный запрос Chat Completions; условия обработки определяет Groq.
    public static func requestBody(entries: [DiaryEntry]) throws -> Data {
        return try GroqChat.requestBody(messages: try buildInput(entries: entries))
    }

    public static func request(entries: [DiaryEntry], apiKey: String) throws -> URLRequest {
        try GroqChat.request(body: requestBody(entries: entries), apiKey: apiKey)
    }

    /// Достаёт текст итога из ответа Chat Completions API и пропускает блок рассуждения.
    public static func parse(_ data: Data) throws -> String {
        try GroqChat.extractText(data) { GroqChat.stripCodeFence($0) }
    }
}

public struct DaySummaryClient {
    public var session: URLSession

    public init(session: URLSession = GroqChat.session) {
        self.session = session
    }

    public func summarize(entries: [DiaryEntry], apiKey: String) async throws -> String {
        let request = try DaySummary.request(entries: entries, apiKey: apiKey)
        return try DaySummary.parse(await GroqChat.send(request, using: session))
    }
}

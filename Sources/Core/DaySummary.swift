import Foundation

/// Одноразовый спокойный итог прожитого дня через xAI Responses API.
/// В запрос попадают только записи выбранного дня. План и другие дни не передаются.
/// Ответ не сохраняется приложением и не записывается в `entries.json`.
public enum DaySummary {
    public static let model = "grok-4.7"
    public static let endpoint = URL(string: "https://api.x.ai/v1/responses")!
    public static let maxContextCharacters = 120_000

    public static let systemPrompt = """
    Ты подводишь спокойный итог одного прожитого дня по записям дневника ниже. \
    Верни 2–4 коротких фразы на языке записей. Сохрани факты, имена и числа. \
    Не оценивай, не хвали, не давай советов и мотивации; не перечисляй, чего не сделано. \
    Ничего не выдумывай сверх записей. Если в записях есть «на чём остановился», \
    можно мягко напомнить, к чему стоит вернуться. Без кавычек, списков и пояснений.
    """

    /// Записи дня в текст для запроса: «HH:mm — текст» и, при наличии, строка контекста.
    /// Многострочный текст переносится с отступом, чтобы не ломать перечисление.
    public static func buildDayText(_ entries: [DiaryEntry]) -> String {
        entries.map { entry in
            let text = entry.text.replacingOccurrences(of: "\n", with: "\n  ")
            var block = "\(DiaryFormat.time(entry.timestamp)) — \(text)"
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

    /// `store: false` просит xAI не сохранять запрос; условия обработки определяет xAI.
    public static func requestBody(entries: [DiaryEntry]) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "store": false,
            "input": try buildInput(entries: entries),
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public static func request(entries: [DiaryEntry], apiKey: String) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try requestBody(entries: entries)
        return req
    }

    /// Достаёт текст итога из ответа Responses API и пропускает блок рассуждения.
    public static func parse(_ data: Data) throws -> String {
        try XAIResponses.extractText(data) { XAIResponses.stripCodeFence($0) }
    }
}

public struct DaySummaryClient {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func summarize(entries: [DiaryEntry], apiKey: String) async throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftPolishError.noKey }
        let req = try DaySummary.request(entries: entries, apiKey: trimmed)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else { throw DraftPolishError.badResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            throw DraftPolishError.http(http.statusCode, DraftPolish.errorMessage(from: data))
        }
        return try DaySummary.parse(data)
    }
}

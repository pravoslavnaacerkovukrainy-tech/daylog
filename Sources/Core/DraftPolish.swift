import Foundation

/// Причёсывание одного черновика через xAI Responses API.
/// В запрос попадает только переданный текст. Дневник и план сюда не передаются.
public enum DraftPolish {
    public static let model = "grok-4.7"
    public static let endpoint = URL(string: "https://api.x.ai/v1/responses")!
    public static let maxCharacters = 2_000

    public static let systemPrompt = """
    Ты правишь черновик одной записи личного дневника. \
    Верни одну короткую фразу на языке черновика. \
    Сохрани факты, имена и числа. Ничего не добавляй и не оценивай. \
    Без кавычек, списков и пояснений.
    """

    /// Тело запроса. `store: false` — xAI не сохраняет этот запрос у себя.
    public static func requestBody(draft: String) throws -> Data {
        let text = normalizeInput(draft)
        guard !text.isEmpty else { throw DraftPolishError.empty }
        guard text.count <= maxCharacters else { throw DraftPolishError.tooLong(text.count) }
        let payload: [String: Any] = [
            "model": model,
            "store": false,
            "input": [
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

    /// Достаёт текст записи из ответа Responses API и пропускает блок рассуждения.
    public static func parse(_ data: Data) throws -> String {
        try XAIResponses.extractText(data, cleanOutput: cleanOutput)
    }

    public static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let err = json["error"] as? [String: Any], let message = err["message"] as? String {
            return message
        }
        if let message = json["message"] as? String { return message }
        return ""
    }

    public static func normalizeInput(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Одна фраза для поля ввода: без ограды кода, внешней кавычки и подписи «Запись:».
    public static func cleanOutput(_ raw: String) -> String {
        let s = stripOnePair(XAIResponses.stripCodeFence(raw))
        let lines = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines.first else { return "" }
        for prefix in ["Запись:", "Черновик:", "Фраза:"] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return stripOnePair(line)
    }

    private static func stripOnePair(_ s: String) -> String {
        let pairs = [("«", "»"), ("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in pairs where s.hasPrefix(open) && s.hasSuffix(close) && s.count > open.count + close.count {
            return String(s.dropFirst(open.count).dropLast(close.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}

public enum DraftPolishError: Error, Equatable, LocalizedError {
    case empty
    case tooLong(Int)
    case badResponse
    case http(Int, String)
    case noKey

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Нечего причёсывать: поле записи пустое."
        case .tooLong(let count):
            return "Черновик слишком длинный для одного запроса (\(count) знаков, лимит \(DraftPolish.maxCharacters))."
        case .badResponse:
            return "xAI ответил, но в ответе не нашлось текста записи."
        case .http(let code, let message):
            return message.isEmpty ? "xAI ответил с ошибкой \(code)." : "xAI ответил с ошибкой \(code): \(message)"
        case .noKey:
            return "Нет ключа xAI. Укажите его в меню «День» → «Ключ xAI…»."
        }
    }
}

public struct DraftPolishClient {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func polish(draft: String, apiKey: String) async throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftPolishError.noKey }
        let req = try DraftPolish.request(draft: draft, apiKey: trimmed)
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
        return try DraftPolish.parse(data)
    }
}

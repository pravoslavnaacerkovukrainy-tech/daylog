import Foundation

/// Причёсывание одного черновика через QwenCloud Chat Completions API.
/// В запрос попадает только переданный текст. Дневник и план сюда не передаются.
public enum DraftPolish {
    public static let model = QwenChat.model
    public static var endpoint: URL { QwenChat.endpoint }
    public static let maxCharacters = 2_000

    public static let systemPrompt = """
    Ты правишь черновик одной записи личного дневника. \
    Верни одну короткую фразу на языке черновика. \
    Сохрани факты, имена и числа. Ничего не добавляй и не оценивай. \
    Без кавычек, списков и пояснений.
    """

    /// Обычный запрос Chat Completions; условия обработки определяет QwenCloud.
    public static func requestBody(draft: String) throws -> Data {
        let text = normalizeInput(draft)
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

    /// Достаёт текст записи из ответа Chat Completions API и пропускает блок рассуждения.
    public static func parse(_ data: Data) throws -> String {
        try QwenChat.extractText(data, cleanOutput: cleanOutput)
    }

    public static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        // QwenCloud отвечает {"code":…,"error":"текст"}; формат {"error":{"message":…}} оставлен для совместимости.
        let candidates: [String?] = [
            (json["error"] as? [String: Any])?["message"] as? String,
            json["error"] as? String,
            json["message"] as? String,
        ]
        for candidate in candidates {
            let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
        }
        return ""
    }

    public static func normalizeInput(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Одна фраза для поля ввода: без ограды кода, внешней кавычки и подписи «Запись:».
    public static func cleanOutput(_ raw: String) -> String {
        let s = stripOnePair(QwenChat.stripCodeFence(raw))
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
    case contextTooLarge(Int)
    case badResponse
    case truncatedResponse
    case http(Int, String)
    case noKey

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Нечего причёсывать: поле записи пустое."
        case .tooLong(let count):
            return "Черновик слишком длинный для одного запроса (\(count) знаков, лимит \(DraftPolish.maxCharacters))."
        case .contextTooLarge(let count):
            return "Заметок слишком много для одного запроса (\(count) знаков). Удалите часть или задайте вопрос по меньшему объёму."
        case .badResponse:
            return "QwenCloud ответил, но в ответе не нашлось текста записи."
        case .truncatedResponse:
            return "Ответ QwenCloud оборвался по лимиту длины. Попробуйте сократить исходный текст."
        case .http(let code, let message):
            return message.isEmpty ? "QwenCloud ответил с ошибкой \(code)." : "QwenCloud ответил с ошибкой \(code): \(message)"
        case .noKey:
            return "Нет ключа QwenCloud. Укажите его в меню «День» → «Ключ QwenCloud…»."
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
            throw DraftPolishError.http(http.statusCode, DraftPolish.errorMessage(from: data).replacingOccurrences(of: trimmed, with: "[ключ скрыт]"))
        }
        return try DraftPolish.parse(data)
    }
}

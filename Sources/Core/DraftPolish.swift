import Foundation

/// Редактура одного черновика через Groq Chat Completions API.
/// В запрос попадает только переданный текст. Дневник и план сюда не передаются.
public enum DraftPolish {
    public static let model = GroqChat.model
    public static var endpoint: URL { GroqChat.endpoint }
    public static let maxCharacters = 2_000

    public static let systemPrompt = """
    Перепиши черновик одной записи личного дневника яснее и естественнее на языке автора.
    Исправь опечатки, убери повторы и выстрой понятный порядок мыслей.
    Сохрани голос автора, имена, числа и все существенные факты. Не превращай планы и сомнения в свершившиеся факты.
    Ничего не добавляй от себя. Верни только готовую запись одним абзацем, без списков и пояснений.
    """

    /// Обычный запрос Chat Completions; условия обработки определяет Groq.
    public static func requestBody(draft: String) throws -> Data {
        let text = normalizeInput(draft)
        guard !text.isEmpty else { throw DraftPolishError.empty }
        guard text.count <= maxCharacters else { throw DraftPolishError.tooLong(text.count, limit: maxCharacters) }
        return try GroqChat.requestBody(messages: [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": text],
        ])
    }

    public static func request(draft: String, apiKey: String) throws -> URLRequest {
        try GroqChat.request(body: requestBody(draft: draft), apiKey: apiKey)
    }

    /// Достаёт текст записи из ответа Chat Completions API и пропускает блок рассуждения.
    public static func parse(_ data: Data) throws -> String {
        try GroqChat.extractText(data, cleanOutput: cleanOutput)
    }

    public static func normalizeInput(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Один абзац для поля ввода: без ограды кода, внешней кавычки и подписи «Запись:».
    public static func cleanOutput(_ raw: String) -> String {
        let s = stripOnePair(GroqChat.stripCodeFence(raw))
        let lines = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines.first else { return "" }
        for prefix in ["Запись:", "Черновик:", "Фраза:"] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let continuation = lines.dropFirst().prefix { !$0.hasPrefix("Пояснение:") }
        return stripOnePair(([line] + continuation).joined(separator: " "))
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
    case tooLong(Int, limit: Int)
    case contextTooLarge(Int)
    case badResponse
    case truncatedResponse
    case requestTooLarge
    case responseTooLarge
    case network
    case http(Int)
    case noKey

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Введите текст записи."
        case .tooLong(let count, let limit):
            return "Черновик слишком длинный для одного запроса (\(count) знаков, лимит \(limit))."
        case .contextTooLarge(let count):
            return "Слишком много текста для одного запроса (\(count) знаков). Выберите меньше заметок или более короткую запись."
        case .badResponse:
            return "Groq ответил, но в ответе не нашлось текста записи."
        case .truncatedResponse:
            return "Ответ Groq оборвался по лимиту длины. Попробуйте сократить исходный текст."
        case .requestTooLarge:
            return "Слишком много текста для одного запроса. Сократите текст или выберите меньше заметок."
        case .responseTooLarge:
            return "Groq прислал слишком длинный ответ. Попробуйте сократить запрос."
        case .network:
            return "Не удалось связаться с Groq. Проверьте интернет и повторите запрос."
        case .http(429):
            return "Достигнут лимит Groq. Повторите позже или сократите запрос."
        case .http(401), .http(403):
            return "Groq отклонил доступ. Проверьте ключ и права в аккаунте Groq."
        case .http(let code):
            return "Groq отклонил запрос (код \(code))."
        case .noKey:
            return "Нет ключа Groq. Укажите его в меню «День» → «Ключ Groq…»."
        }
    }
}

public struct DraftPolishClient {
    public var session: URLSession

    public init(session: URLSession = GroqChat.session) {
        self.session = session
    }

    public func polish(draft: String, apiKey: String) async throws -> String {
        let request = try DraftPolish.request(draft: draft, apiKey: apiKey)
        return try DraftPolish.parse(await GroqChat.send(request, using: session))
    }
}

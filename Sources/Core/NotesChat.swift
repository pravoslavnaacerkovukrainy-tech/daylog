import Foundation

public struct ChatMessage: Identifiable, Equatable {
    public enum Role {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var sourceNoteIDs: [UUID]
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        sourceNoteIDs: [UUID] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.sourceNoteIDs = sourceNoteIDs
        self.timestamp = timestamp
    }
}

public enum NotesChat {
    public static let model = "grok-4.7"
    public static let endpoint = URL(string: "https://api.x.ai/v1/responses")!
    public static let maxContextCharacters = 120_000

    public static let systemPrompt = """
    Ты отвечаешь на вопросы пользователя, опираясь ТОЛЬКО на его заметки ниже. \
    Если ответа в заметках нет — честно скажи об этом. Заметки пронумерованы. \
    В КОНЦЕ ответа на отдельной строке укажи номера использованных заметок в формате \
    «⟦источники: 1, 3⟧», либо «⟦источники: нет⟧», если не опирался ни на одну. \
    Язык ответа — как у вопроса. Ничего не выдумывай сверх заметок.
    """

    public static func numberedNotes(_ notes: [DiaryNote]) -> String {
        notes.enumerated().map { index, note in
            let title = note.title.isEmpty ? "Без заголовка" : note.title
            return "[\(index + 1)] \(title)\n\(note.body)"
        }.joined(separator: "\n\n")
    }

    public static func buildInput(
        notes: [DiaryNote],
        history: [ChatMessage],
        question: String
    ) throws -> [[String: Any]] {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw DraftPolishError.empty }

        let ctx = numberedNotes(notes)
        guard ctx.count <= maxContextCharacters else {
            throw DraftPolishError.contextTooLarge(ctx.count)
        }

        var input: [[String: Any]] = [
            ["role": "system", "content": systemPrompt + "\n\nЗаметки:\n" + ctx],
        ]
        for message in history {
            let role = message.role == .user ? "user" : "assistant"
            input.append(["role": role, "content": message.text])
        }
        input.append(["role": "user", "content": q])
        return input
    }

    public static func requestBody(
        notes: [DiaryNote],
        history: [ChatMessage],
        question: String
    ) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "store": false,
            "input": try buildInput(notes: notes, history: history, question: question),
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    public static func request(
        notes: [DiaryNote],
        history: [ChatMessage],
        question: String,
        apiKey: String
    ) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try requestBody(notes: notes, history: history, question: question)
        return req
    }

    public static func parse(_ data: Data) throws -> (answer: String, sources: [Int]) {
        let text = try XAIResponses.extractText(data)
        let markerPattern = #"^[\t ]*(?:⟦[\t ]*источники[\t ]*:[^\r\n]*?⟧|\[[\t ]*источники[\t ]*:[^\r\n]*?\])[\t ]*$"#
        let markerRegex = try NSRegularExpression(
            pattern: markerPattern,
            options: [.caseInsensitive, .anchorsMatchLines]
        )
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = markerRegex.matches(in: text, range: fullRange)

        guard let marker = matches.last, let markerRange = Range(marker.range, in: text) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }

        let markerLine = String(text[markerRange])
        let sources: [Int]
        if markerLine.lowercased().components(separatedBy: CharacterSet.letters.inverted).contains("нет") {
            sources = []
        } else {
            let numberRegex = try NSRegularExpression(pattern: #"-?\d+"#)
            let markerNSRange = NSRange(markerLine.startIndex..., in: markerLine)
            sources = numberRegex.matches(in: markerLine, range: markerNSRange).compactMap { match in
                guard let range = Range(match.range, in: markerLine) else { return nil }
                return Int(markerLine[range])
            }
        }

        var answer = text
        answer.removeSubrange(markerRange)
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw DraftPolishError.badResponse }
        return (answer, sources)
    }

    public static func resolveSources(_ numbers: [Int], noteCount: Int) -> [Int] {
        var seen = Set<Int>()
        return numbers.filter { number in
            guard number >= 1, number <= noteCount else { return false }
            return seen.insert(number).inserted
        }
    }
}

public struct NotesChatClient {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func ask(
        notes: [DiaryNote],
        history: [ChatMessage],
        question: String,
        apiKey: String
    ) async throws -> (answer: String, sources: [Int]) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftPolishError.noKey }
        let req = try NotesChat.request(
            notes: notes,
            history: history,
            question: question,
            apiKey: trimmed
        )
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
        return try NotesChat.parse(data)
    }
}

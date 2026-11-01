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
}

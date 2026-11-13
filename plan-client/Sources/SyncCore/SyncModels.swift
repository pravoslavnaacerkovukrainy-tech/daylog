import Foundation

// Модель синхронизации задач. Общая для приложения, CLI и самопроверки.
// Протокол: GET /api/tasks, GET /api/tasks/:id, POST /api/sync/tasks/:id.

/// Поля, которые клиент умеет менять через синхронизацию.
public enum SyncField: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case day, text, details

    public var title: String {
        switch self {
        case .day: return "Рабочий день"
        case .text: return "Название"
        case .details: return "Подробности"
        }
    }
}

/// Значение поля в протоколе: строка или JSON null (null бывает только у details).
public enum FieldValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var json: Any {
        switch self {
        case .string(let s): return s
        case .null: return NSNull()
        }
    }
}

/// Задача в том виде, в каком её отдаёт сервер. Клиент читает только нужные поля.
public struct SyncTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var day: String
    public var details: String?
    public var deadline: String?
    public var area: String?
    public var status: String?
    public var isCompleted: Bool
    public var isRemoved: Bool
    public var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, text, day, details, deadline, area, status
        case isCompleted = "is_completed"
        case isRemoved = "is_removed"
        case updatedAt = "updated_at"
    }

    public init(id: String, text: String, day: String = "", details: String? = nil,
                deadline: String? = nil, area: String? = "work", status: String? = "ready",
                isCompleted: Bool = false, isRemoved: Bool = false, updatedAt: String? = nil) {
        self.id = SyncNormalize.id(id)
        self.text = text
        self.day = day
        self.details = details
        self.deadline = deadline
        self.area = area
        self.status = status
        self.isCompleted = isCompleted
        self.isRemoved = isRemoved
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = SyncNormalize.id(try c.decode(String.self, forKey: .id))
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details)
        deadline = try c.decodeIfPresent(String.self, forKey: .deadline)
        area = try c.decodeIfPresent(String.self, forKey: .area)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        isRemoved = try c.decodeIfPresent(Bool.self, forKey: .isRemoved) ?? false
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public var isOpen: Bool { !isCompleted && !isRemoved }

    public func value(_ field: SyncField) -> FieldValue {
        switch field {
        case .day: return .string(day)
        case .text: return .string(text)
        case .details: return details.map(FieldValue.string) ?? .null
        }
    }

    public mutating func set(_ field: SyncField, _ value: FieldValue) {
        switch field {
        case .day: day = value.stringValue ?? ""
        case .text: text = value.stringValue ?? ""
        case .details: details = value.stringValue
        }
    }
}

/// Отправленный запрос, исход которого неизвестен (ответ потерян, приложение закрылось).
/// Его повторяют дословно: сервер признаёт повтор по совпадению с changes.
public struct SentRequest: Codable, Equatable, Sendable {
    public var base: [SyncField: FieldValue]
    public var changes: [SyncField: FieldValue]
}

public enum PendingStatus: String, Codable, Sendable {
    /// Ждёт отправки.
    case queued
    /// Сервер изменил то же поле. Нужен выбор по каждому полю из conflictFields.
    case conflict
    /// Задачи на сервере больше нет (404). Нужно явное решение.
    case gone
    /// Сервер отклонил правку (400 и подобные). Нужно явное решение.
    case rejected
}

/// Неотправленная правка одной задачи. base — значения сервера, на которые опирается правка.
public struct PendingEdit: Codable, Equatable, Identifiable, Sendable {
    public var taskId: String
    public var base: [SyncField: FieldValue]
    public var changes: [SyncField: FieldValue]
    public var inflight: SentRequest?
    public var status: PendingStatus
    public var conflictFields: [SyncField]
    /// Версия задачи на сервере на момент конфликта.
    public var serverTask: SyncTask?
    public var message: String?
    public var editedAt: Date
    public var attempts: Int

    public var id: String { taskId }

    public init(taskId: String) {
        self.taskId = SyncNormalize.id(taskId)
        base = [:]
        changes = [:]
        inflight = nil
        status = .queued
        conflictFields = []
        serverTask = nil
        message = nil
        editedAt = Date()
        attempts = 0
    }

    /// Нужен ли этот элемент очереди: есть правка или неподтверждённый запрос.
    public var isEmpty: Bool { changes.isEmpty && inflight == nil }

    public var needsDecision: Bool { status != .queued }
}

/// Строка места хаоса. Действия с ней выполняются только при связи с сервером.
public struct ChaosItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var urgent: Bool
    public var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, text, urgent
        case createdAt = "created_at"
    }

    public init(id: String, text: String, urgent: Bool = false, createdAt: String? = nil) {
        self.id = SyncNormalize.id(id)
        self.text = text
        self.urgent = urgent
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = SyncNormalize.id(try c.decode(String.self, forKey: .id))
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

/// Локальная копия для одного сервера.
public struct ServerState: Codable, Equatable, Sendable {
    public var server: String
    public var tasks: [SyncTask]
    public var pending: [PendingEdit]
    public var chaos: [ChaosItem]
    public var lastPull: Date?

    public init(server: String) {
        self.server = server
        tasks = []
        pending = []
        chaos = []
        lastPull = nil
    }

    enum CodingKeys: String, CodingKey { case server, tasks, pending, chaos, lastPull }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decode(String.self, forKey: .server)
        tasks = try c.decodeIfPresent([SyncTask].self, forKey: .tasks) ?? []
        pending = try c.decodeIfPresent([PendingEdit].self, forKey: .pending) ?? []
        chaos = try c.decodeIfPresent([ChaosItem].self, forKey: .chaos) ?? []
        lastPull = try c.decodeIfPresent(Date.self, forKey: .lastPull)
    }
}

public struct SyncSettings: Codable, Equatable, Sendable {
    public var server: String?
    public var offline: Bool
    public init(server: String? = nil, offline: Bool = false) {
        self.server = server
        self.offline = offline
    }
}

/// Нормализация как на сервере: UUID в нижнем регистре, текст обрезается, пустые подробности = null.
public enum SyncNormalize {
    public static func id(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isUUID(_ raw: String) -> Bool {
        UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    public static func isDayKey(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: Int(parts[0]), month: Int(parts[1]), day: Int(parts[2]))
        guard let date = cal.date(from: comps) else { return false }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return back.year == comps.year && back.month == comps.month && back.day == comps.day
    }

    /// Приводит значение к виду, в котором его хранит сервер. Ошибка — текст для человека.
    public static func value(_ field: SyncField, _ raw: FieldValue) throws -> FieldValue {
        switch field {
        case .day:
            let s = (raw.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return .string("") }
            guard isDayKey(s) else { throw SyncError.invalidValue("Рабочий день: нужна дата ГГГГ-ММ-ДД.") }
            return .string(s)
        case .text:
            let s = (raw.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { throw SyncError.invalidValue("Название не может быть пустым.") }
            return .string(s)
        case .details:
            guard let s = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return .null }
            return .string(s)
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    /// Адрес сервера без пути: схема, хост, порт. Обычный http — только для loopback.
    public static func server(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = comps.host, !host.isEmpty else {
            throw SyncError.invalidValue("Адрес сервера не подходит. Пример: http://127.0.0.1:3100")
        }
        let lower = host.lowercased()
        if scheme == "http" && !isLoopback(lower) {
            throw SyncError.invalidValue("Без шифрования можно подключаться только к этому Mac (127.0.0.1, localhost). Для другого сервера нужен https://.")
        }
        comps.scheme = scheme
        comps.host = lower
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        guard let out = comps.string else { throw SyncError.invalidValue("Адрес сервера не подходит.") }
        return out
    }
}

public enum SyncError: Error, Equatable, LocalizedError {
    case invalidValue(String)
    case unknownTask(String)
    case noServer
    case offlineManual
    case network(String)
    case unauthorized(String)
    case http(Int, String, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let m): return m
        case .unknownTask(let id): return "Задача \(id) не найдена в локальной копии."
        case .noServer: return "Сервер не выбран."
        case .offlineManual: return "Включён офлайн. Правки остаются на Mac."
        case .network(let m): return "Нет связи с сервером: \(m)"
        case .unauthorized(let m): return m
        case .http(let status, _, let m): return "Сервер ответил \(status): \(m)"
        case .badResponse(let m): return "Непонятный ответ сервера: \(m)"
        }
    }
}

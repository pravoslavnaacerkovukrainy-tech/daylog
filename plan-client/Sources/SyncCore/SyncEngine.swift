import Foundation

/// Состояние связи для строки статуса.
public enum ConnectionState: Equatable, Sendable {
    case idle
    case syncing
    case online
    case offlineManual
    case unreachable(String)
    case needsLogin(String)
    case serverError(String)
    case noServer
}

public enum ResolveChoice: String, Sendable {
    /// «Моя версия»: правка повторяется с базой, равной текущему значению сервера.
    case mine
    /// «Версия сервера»: локальная правка этого поля убирается.
    case server
}

public struct FlushReport: Equatable, Sendable {
    public var applied: [String] = []
    public var conflicts: [String] = []
    public var gone: [String] = []
    public var rejected: [String] = []
    public var stopped: String?
    public init() {}
}

/// Ядро клиента: локальная копия задач, очередь правок, отправка и разбор ответов.
///
/// Правило: правка сначала записывается на диск, потом уходит в сеть. Элемент очереди
/// удаляется только после подтверждения сервера или явного решения человека.
@MainActor
public final class SyncEngine {
    public let dataDir: URL
    private let transport: HTTPTransport
    private let fm = FileManager.default

    public private(set) var settings: SyncSettings
    public private(set) var state: ServerState?
    public private(set) var connection: ConnectionState = .idle
    private var api: SyncAPI?
    private var flushing = false

    /// Вызывается после каждого изменения состояния (для интерфейса).
    public var onChange: (() -> Void)?

    public init(dataDir: URL, transport: HTTPTransport) throws {
        self.dataDir = dataDir
        self.transport = transport
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        settings = (try? Self.read(SyncSettings.self, from: dataDir.appendingPathComponent("settings.json"))) ?? SyncSettings()
        if let server = settings.server {
            state = try loadState(server)
            api = SyncAPI(server: server, transport: transport)
        }
        connection = settings.server == nil ? .noServer : (settings.offline ? .offlineManual : .idle)
    }

    // MARK: Файлы

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(value).write(to: url, options: [.atomic])
    }

    /// Каталог данных одного сервера: имя читается и не содержит разделителей пути.
    public static func folderName(for server: String) -> String {
        let safe = server.replacingOccurrences(of: "://", with: "_")
            .map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }
            .joined()
        return safe
    }

    private func stateURL(_ server: String) -> URL {
        dataDir.appendingPathComponent("servers", isDirectory: true)
            .appendingPathComponent(Self.folderName(for: server), isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private func loadState(_ server: String) throws -> ServerState {
        let url = stateURL(server)
        guard fm.fileExists(atPath: url.path) else { return ServerState(server: server) }
        return try Self.read(ServerState.self, from: url)
    }

    private func save() throws {
        if let state { try write(state, to: stateURL(state.server)) }
        try write(settings, to: dataDir.appendingPathComponent("settings.json"))
    }

    private func changed() { onChange?() }

    private func setConnection(_ c: ConnectionState) {
        connection = c
        changed()
    }

    // MARK: Сервер, вход, офлайн

    public var server: String? { settings.server }
    public var isLoggedIn: Bool { api?.isLoggedIn ?? false }

    /// Переключает сервер. Очередь прежнего сервера остаётся в его каталоге и не уходит на новый.
    public func setServer(_ raw: String) throws {
        let server = try SyncNormalize.server(raw)
        if server == settings.server { return }
        try save()
        settings.server = server
        state = try loadState(server)
        api = SyncAPI(server: server, transport: transport)
        try save()
        connection = settings.offline ? .offlineManual : .idle
        changed()
    }

    public func setOffline(_ offline: Bool) throws {
        settings.offline = offline
        try save()
        connection = offline ? .offlineManual : (settings.server == nil ? .noServer : .idle)
        changed()
    }

    public var isOffline: Bool { settings.offline }

    public func login(password: String) async throws {
        guard let api else { throw SyncError.noServer }
        if settings.offline { throw SyncError.offlineManual }
        do {
            try await api.login(password: password)
            setConnection(.online)
        } catch SyncError.network(let m) {
            setConnection(.unreachable(m))
            throw SyncError.network(m)
        } catch SyncError.unauthorized(let m) {
            setConnection(.needsLogin(m))
            throw SyncError.unauthorized(m)
        }
    }

    public func logout() {
        api?.forgetSession()
        setConnection(settings.server == nil ? .noServer : .needsLogin("Вход не выполнен."))
    }

    /// Неотправленные правки других серверов: путь к каталогу и число правок.
    public func otherServersWithPending() -> [(server: String, count: Int)] {
        let root = dataDir.appendingPathComponent("servers", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, Int)] = []
        for dir in dirs {
            guard let s = try? Self.read(ServerState.self, from: dir.appendingPathComponent("state.json")),
                  s.server != settings.server else { continue }
            let n = s.pending.filter { !$0.isEmpty }.count
            if n > 0 { out.append((s.server, n)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: Чтение локальной копии

    public var pending: [PendingEdit] { state?.pending ?? [] }

    public func pendingEdit(_ id: String) -> PendingEdit? {
        let id = SyncNormalize.id(id)
        return state?.pending.first { $0.taskId == id }
    }

    public func serverTask(_ id: String) -> SyncTask? {
        let id = SyncNormalize.id(id)
        return state?.tasks.first { $0.id == id }
    }

    /// Задачи так, как их видит человек: сервер плюс неотправленные правки.
    public var tasks: [SyncTask] {
        guard let state else { return [] }
        var byId: [String: SyncTask] = [:]
        var order: [String] = []
        for t in state.tasks { byId[t.id] = t; order.append(t.id) }
        for p in state.pending {
            guard var t = byId[p.taskId] ?? p.serverTask else { continue }
            if byId[p.taskId] == nil { order.append(p.taskId) }
            for (f, v) in p.changes { t.set(f, v) }
            byId[p.taskId] = t
        }
        return order.compactMap { byId[$0] }
    }

    public func task(_ id: String) -> SyncTask? {
        let id = SyncNormalize.id(id)
        return tasks.first { $0.id == id }
    }

    public var queuedCount: Int { pending.filter { !$0.isEmpty && $0.status == .queued }.count }
    public var decisionCount: Int { pending.filter { $0.needsDecision }.count }

    // MARK: Локальная правка

    /// Записывает правку в локальную копию и на диск. Сеть не трогает.
    public func edit(_ taskId: String, _ field: SyncField, _ raw: FieldValue) throws {
        guard var state else { throw SyncError.noServer }
        let id = SyncNormalize.id(taskId)
        let value = try SyncNormalize.value(field, raw)
        let index = state.pending.firstIndex { $0.taskId == id }
        var edit: PendingEdit
        if let index { edit = state.pending[index] } else {
            guard state.tasks.contains(where: { $0.id == id }) else { throw SyncError.unknownTask(id) }
            edit = PendingEdit(taskId: id)
        }
        if edit.changes[field] == nil && edit.base[field] == nil {
            guard let t = state.tasks.first(where: { $0.id == id }) ?? edit.serverTask else { throw SyncError.unknownTask(id) }
            edit.base[field] = t.value(field)
        }
        edit.changes[field] = value
        dropSettled(&edit, field)
        edit.editedAt = Date()
        if edit.status == .rejected { edit.status = .queued; edit.message = nil }
        if let index {
            if edit.isEmpty { state.pending.remove(at: index) } else { state.pending[index] = edit }
        } else if !edit.isEmpty {
            state.pending.append(edit)
        }
        self.state = state
        try save()
        changed()
    }

    /// Поле убирается из правки, если она совпала с базой и в сети нет запроса по этому полю.
    /// Пока исход отправленного запроса неизвестен, возврат к прежнему значению — тоже правка.
    private func dropSettled(_ edit: inout PendingEdit, _ field: SyncField) {
        guard let change = edit.changes[field], change == edit.base[field] else { return }
        if edit.inflight?.changes[field] != nil { return }
        edit.changes[field] = nil
        edit.base[field] = nil
        edit.conflictFields.removeAll { $0 == field }
        if edit.status == .conflict && edit.conflictFields.isEmpty { edit.status = .queued; edit.serverTask = nil }
    }

    /// Явное решение по полю в конфликте.
    public func resolve(_ taskId: String, _ field: SyncField, _ choice: ResolveChoice) throws {
        guard var state, let i = state.pending.firstIndex(where: { $0.taskId == SyncNormalize.id(taskId) }) else {
            throw SyncError.unknownTask(taskId)
        }
        var edit = state.pending[i]
        guard edit.status == .conflict, edit.conflictFields.contains(field), let server = edit.serverTask else {
            throw SyncError.invalidValue("По полю «\(field.title)» нет конфликта.")
        }
        switch choice {
        case .mine:
            edit.base[field] = server.value(field)
            edit.conflictFields.removeAll { $0 == field }
            dropSettled(&edit, field)
        case .server:
            edit.changes[field] = nil
            edit.base[field] = nil
        }
        edit.conflictFields.removeAll { $0 == field }
        if edit.conflictFields.isEmpty {
            edit.status = .queued
            edit.serverTask = nil
            edit.message = nil
        }
        if let idx = state.tasks.firstIndex(where: { $0.id == server.id }) { state.tasks[idx] = server }
        if edit.isEmpty { state.pending.remove(at: i) } else { state.pending[i] = edit }
        self.state = state
        try save()
        changed()
    }

    /// Явный отказ от правки задачи (в том числе удалённой или отклонённой сервером).
    public func discard(_ taskId: String) throws {
        guard var state else { throw SyncError.noServer }
        let id = SyncNormalize.id(taskId)
        guard let i = state.pending.firstIndex(where: { $0.taskId == id }) else { throw SyncError.unknownTask(id) }
        let edit = state.pending.remove(at: i)
        if edit.status == .conflict, let server = edit.serverTask,
           let idx = state.tasks.firstIndex(where: { $0.id == server.id }) {
            state.tasks[idx] = server
        }
        self.state = state
        try save()
        changed()
    }

    // MARK: Сеть

    private func requireOnline() throws -> SyncAPI {
        guard let api else { throw SyncError.noServer }
        if settings.offline { throw SyncError.offlineManual }
        guard api.isLoggedIn else { throw SyncError.unauthorized("Вход не выполнен.") }
        return api
    }

    private func note(_ error: Error) {
        switch error {
        case SyncError.offlineManual: setConnection(.offlineManual)
        case SyncError.network(let m): setConnection(.unreachable(m))
        case SyncError.unauthorized(let m): setConnection(.needsLogin(m))
        case SyncError.noServer: setConnection(.noServer)
        case let e as SyncError: setConnection(.serverError(e.localizedDescription))
        default: setConnection(.serverError(error.localizedDescription))
        }
    }

    /// Получает все задачи с сервера. Неотправленные правки при этом не меняются.
    public func pull() async throws {
        do {
            let api = try requireOnline()
            setConnection(.syncing)
            let list = try await api.fetchTasks()
            let chaos = try await api.fetchChaos()
            guard var state, state.server == api.server else { return }
            state.tasks = list
            state.chaos = chaos
            state.lastPull = Date()
            self.state = state
            try save()
            setConnection(.online)
        } catch {
            note(error)
            throw error
        }
    }

    /// Отправляет очередь по порядку. Останавливается на сбое связи, входа или сервера:
    /// правки остаются на диске до подтверждения или явного решения.
    @discardableResult
    public func flush() async -> FlushReport {
        var report = FlushReport()
        if flushing { report.stopped = "отправка уже идёт"; return report }
        let api: SyncAPI
        do { api = try requireOnline() } catch {
            note(error)
            report.stopped = error.localizedDescription
            return report
        }
        flushing = true
        defer { flushing = false }
        setConnection(.syncing)

        var guardCounter = 0
        while guardCounter < 1000 {
            guardCounter += 1
            guard let state, state.server == api.server,
                  let edit = state.pending.first(where: { $0.status == .queued && !$0.isEmpty }) else { break }
            let request = edit.inflight ?? SentRequest(base: edit.base, changes: edit.changes)
            if request.changes.isEmpty {
                // Нечего отправлять: правка уже совпадает с базой.
                mutate(edit.taskId) { _ in }
                continue
            }
            // Сначала на диск: если ответ потеряется или процесс закроется, запрос повторится дословно.
            mutate(edit.taskId) { $0.inflight = request; $0.attempts += 1 }
            do { try save() } catch { report.stopped = error.localizedDescription; break }

            let outcome: SyncOutcome
            do {
                outcome = try await api.sync(taskId: edit.taskId, request: request)
            } catch {
                note(error)
                report.stopped = error.localizedDescription
                try? save()
                return report
            }
            // Сервер переключили, пока шёл запрос: ответ относится к другой копии, разберём его при повторе.
            guard self.state?.server == api.server else {
                report.stopped = "сервер переключён во время отправки"
                return report
            }
            switch outcome {
            case .applied(let task):
                applied(task, request: request)
                report.applied.append(edit.taskId)
            case .conflict(let task, let fields):
                conflicted(edit.taskId, task: task, serverFields: fields)
                if pendingEdit(edit.taskId)?.status == .conflict { report.conflicts.append(edit.taskId) }
            case .gone(let message):
                mutate(edit.taskId) { $0.inflight = nil; $0.status = .gone; $0.message = message }
                report.gone.append(edit.taskId)
            case .rejected(_, let message):
                mutate(edit.taskId) { $0.inflight = nil; $0.status = .rejected; $0.message = message }
                report.rejected.append(edit.taskId)
            case .unauthorized(let message):
                try? save()
                setConnection(.needsLogin(message))
                report.stopped = message
                return report
            case .serverError(_, let message):
                try? save()
                setConnection(.serverError(message))
                report.stopped = message
                return report
            }
            try? save()
        }
        setConnection(.online)
        return report
    }

    /// Получить задачи, затем отправить очередь.
    @discardableResult
    public func syncNow() async -> FlushReport {
        let report = await flush()
        if report.stopped == nil { try? await pull() }
        return report
    }

    // MARK: Действия только при связи (существующие маршруты API, без очереди)

    public var chaos: [ChaosItem] { state?.chaos ?? [] }

    /// Можно ли сейчас выполнить действие, которому нужна сеть.
    public var canUseServer: Bool {
        guard let api, !settings.offline else { return false }
        return api.isLoggedIn
    }

    private func online<T>(_ body: (SyncAPI) async throws -> T) async throws -> T {
        do {
            let api = try requireOnline()
            let result = try await body(api)
            if connection != .syncing { setConnection(.online) }
            return result
        } catch {
            note(error)
            throw error
        }
    }

    /// «Записать»: POST /api/chaos.
    public func capture(_ raw: String, urgent: Bool = false) async throws -> ChaosItem {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SyncError.invalidValue("Запись пустая.") }
        let item = try await online { api in
            try SyncAPI.decode(ChaosItem.self, try await api.call("POST", "/api/chaos", json: ["text": text, "urgent": urgent])["chaos"])
        }
        state?.chaos.append(item)
        try save()
        changed()
        return item
    }

    /// Разобрать строку в задачу: POST /api/chaos/:id/to-task.
    public func chaosToTask(_ chaosId: String, text: String? = nil, day: String = "") async throws -> SyncTask {
        let id = SyncNormalize.id(chaosId)
        guard let item = chaos.first(where: { $0.id == id }) else { throw SyncError.unknownTask(id) }
        let title = try SyncNormalize.value(.text, .string(text ?? item.text))
        let dayValue = try SyncNormalize.value(.day, .string(day))
        let task = try await online { api in
            try SyncAPI.decode(SyncTask.self, try await api.call("POST", "/api/chaos/\(id)/to-task",
                                                                json: ["text": title.stringValue ?? "", "day": dayValue.stringValue ?? ""])["task"])
        }
        state?.chaos.removeAll { $0.id == id }
        storeServerTask(task)
        try save()
        changed()
        return task
    }

    /// Разобрать строку в заметку: POST /api/chaos/:id/to-note.
    public func chaosToNote(_ chaosId: String) async throws {
        let id = SyncNormalize.id(chaosId)
        _ = try await online { api in try await api.call("POST", "/api/chaos/\(id)/to-note", json: [:]) }
        state?.chaos.removeAll { $0.id == id }
        try save()
        changed()
    }

    /// Отметить выполнение или вернуть в работу: POST /api/tasks/:id/complete | reopen.
    public func setCompleted(_ taskId: String, _ done: Bool) async throws {
        let id = SyncNormalize.id(taskId)
        let task = try await online { api in
            try SyncAPI.decode(SyncTask.self, try await api.call("POST", "/api/tasks/\(id)/\(done ? "complete" : "reopen")", json: [:])["task"])
        }
        storeServerTask(task)
        try save()
        changed()
    }

    private func mutate(_ id: String, _ body: (inout PendingEdit) -> Void) {
        guard var state, let i = state.pending.firstIndex(where: { $0.taskId == id }) else { return }
        body(&state.pending[i])
        if state.pending[i].isEmpty { state.pending.remove(at: i) }
        self.state = state
        changed()
    }

    private func storeServerTask(_ task: SyncTask) {
        guard var state else { return }
        if let i = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[i] = task } else { state.tasks.append(task) }
        self.state = state
    }

    /// 200: отправленные поля теперь на сервере. Новая база для них — отправленные значения.
    private func applied(_ task: SyncTask, request: SentRequest) {
        storeServerTask(task)
        mutate(task.id) { edit in
            edit.inflight = nil
            edit.message = nil
            for (field, sent) in request.changes {
                guard edit.changes[field] != nil else { continue }
                edit.base[field] = sent
                if edit.changes[field] == sent {
                    edit.changes[field] = nil
                    edit.base[field] = nil
                }
            }
        }
    }

    /// 409: сервер ничего не применил. Конфликт считается по текущей правке и версии сервера.
    private func conflicted(_ id: String, task: SyncTask, serverFields: [SyncField]) {
        storeServerTask(task)
        mutate(id) { edit in
            edit.inflight = nil
            var conflicts: [SyncField] = []
            for field in SyncField.allCases {
                guard let mine = edit.changes[field] else { continue }
                let current = task.value(field)
                if current == mine {
                    // Сервер уже содержит это значение.
                    edit.changes[field] = nil
                    edit.base[field] = nil
                } else if current != edit.base[field] {
                    conflicts.append(field)
                }
            }
            if conflicts.isEmpty {
                // Сервер видит конфликт, который локально не воспроизводится: не повторяем вслепую.
                conflicts = serverFields.filter { edit.changes[$0] != nil }
            }
            if conflicts.isEmpty {
                // Совпадений с сервером хватило, правку можно отправить заново.
                edit.status = .queued
                edit.serverTask = nil
                edit.message = nil
            } else {
                edit.status = .conflict
                edit.conflictFields = conflicts
                edit.serverTask = task
                edit.message = "На сервере изменили: " + conflicts.map(\.title).joined(separator: ", ") + "."
            }
        }
    }
}

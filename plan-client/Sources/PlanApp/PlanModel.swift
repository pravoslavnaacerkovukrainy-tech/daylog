import Foundation
import Network
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case plan, all, chaos, outbox, connection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plan: return "План"
        case .all: return "Все задачи"
        case .chaos: return "Место хаоса"
        case .outbox: return "Отправка"
        case .connection: return "Подключение"
        }
    }
    var symbol: String {
        switch self {
        case .plan: return "calendar"
        case .all: return "list.bullet"
        case .chaos: return "tray"
        case .outbox: return "arrow.up.circle"
        case .connection: return "network"
        }
    }
}

/// Даты как на сервере: ключ дня ГГГГ-ММ-ДД в часовом поясе Mac.
enum Days {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "ru_RU")
        c.firstWeekday = 2
        return c
    }()

    static func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func add(_ n: Int, to key: String) -> String {
        guard let d = date(key), let r = calendar.date(byAdding: .day, value: n, to: d) else { return key }
        return Self.key(r)
    }

    static func week(of key: String) -> [String] {
        guard let d = date(key), let start = calendar.dateInterval(of: .weekOfYear, for: d)?.start else { return [key] }
        return (0..<7).map { Self.key(calendar.date(byAdding: .day, value: $0, to: start)!) }
    }

    static func format(_ key: String, _ template: String) -> String {
        guard let d = date(key) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }

    /// «пятница, 13 ноября»
    static func long(_ key: String) -> String {
        guard let d = date(key) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: d)
    }

    static func short(_ key: String) -> String {
        guard !key.isEmpty else { return "Без даты" }
        guard let d = date(key) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.dateFormat = "EE, d MMM"
        return f.string(from: d)
    }

    static var today: String { key(Date()) }
}

/// Настройки интерфейса нового приложения. Отдельно от данных синхронизации.
struct UISettings: Codable {
    var theme: ThemeChoice = .dark
}

@MainActor
final class PlanModel: ObservableObject {
    let engine: SyncEngine?
    let startupError: String?
    let dataDir: URL

    @Published var section: Section = .plan
    @Published var selectedTask: String?
    @Published var day: String = Days.today
    @Published var showCompleted = false
    @Published var showRemoved = false
    @Published var theme: ThemeChoice = .dark { didSet { saveUI() } }
    @Published var notice: String?
    @Published var busy = false
    @Published var captureOpen = false
    @Published var serverDraft: String = ""

    private var timer: Timer?
    private var monitor: NWPathMonitor?
    private var lastPull = Date.distantPast

    init() {
        let env = ProcessInfo.processInfo.environment
        var dir = env["CHAOS_PLAN_DATA_DIR"]
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data"), i + 1 < args.count { dir = args[i + 1] }
        let base = dir.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChaosDayPlanPilot", isDirectory: true)
        dataDir = base
        do {
            engine = try SyncEngine(dataDir: base, transport: URLSessionTransport())
            startupError = nil
        } catch {
            engine = nil
            startupError = "Не удалось открыть локальную копию в \(base.path): \(error.localizedDescription)"
        }
        if let data = try? Data(contentsOf: uiURL), let ui = try? JSONDecoder().decode(UISettings.self, from: data) {
            theme = ui.theme
        }
        serverDraft = engine?.server ?? env["CHAOS_PLAN_SERVER"] ?? "http://127.0.0.1:3000"
        engine?.onChange = { [weak self] in self?.objectWillChange.send() }
        // Для воспроизводимой приёмки и снимков: --section plan|all|chaos|outbox|connection,
        // --day ГГГГ-ММ-ДД, --select ID задачи.
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let s = arg("--section").flatMap(Section.init(rawValue:)) { section = s }
        if let d = arg("--day"), SyncNormalize.isDayKey(d) { day = d }
        if let id = arg("--select") { selectedTask = SyncNormalize.id(id) }
        start()
    }

    private var uiURL: URL { dataDir.appendingPathComponent("ui.json") }

    private func saveUI() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? enc.encode(UISettings(theme: theme)).write(to: uiURL, options: .atomic)
    }

    var palette: Palette { Palette.of(theme) }

    // MARK: Автоотправка

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.tick(force: true) }
        }
        m.start(queue: .main)
        monitor = m
    }

    /// Связь вернулась или прошло время: отправить очередь, иногда обновить задачи.
    func tick(force: Bool = false) async {
        guard let engine, engine.canUseServer, !busy else { return }
        if engine.queuedCount > 0 {
            await engine.flush()
        }
        if force || Date().timeIntervalSince(lastPull) > 60 {
            lastPull = Date()
            try? await engine.pull()
        }
    }

    func syncNow() async {
        guard let engine else { return }
        busy = true
        defer { busy = false }
        let r = await engine.flush()
        if r.stopped == nil {
            do { try await engine.pull(); lastPull = Date(); notice = nil } catch { notice = error.localizedDescription }
        } else {
            notice = r.stopped
        }
    }

    // MARK: Данные для экранов

    var tasks: [SyncTask] { engine?.tasks ?? [] }

    func tasks(on day: String) -> [SyncTask] {
        tasks.filter { $0.day == day && $0.isOpen }
    }

    func openCount(on day: String) -> Int { tasks(on: day).count }

    var visibleAll: [SyncTask] {
        tasks.filter { t in
            if t.isRemoved { return showRemoved }
            if t.isCompleted { return showCompleted }
            return true
        }
    }

    func pending(_ id: String) -> PendingEdit? { engine?.pendingEdit(id) }

    // MARK: Действия

    func edit(_ id: String, _ field: SyncField, _ value: FieldValue) {
        guard let engine else { return }
        do {
            try engine.edit(id, field, value)
            notice = nil
            Task { await tick() }
        } catch {
            notice = error.localizedDescription
        }
    }

    func resolve(_ id: String, _ field: SyncField, _ choice: ResolveChoice) {
        do {
            try engine?.resolve(id, field, choice)
            Task { await tick() }
        } catch { notice = error.localizedDescription }
    }

    func discard(_ id: String) {
        do { try engine?.discard(id) } catch { notice = error.localizedDescription }
    }

    func setOffline(_ on: Bool) {
        do { try engine?.setOffline(on) } catch { notice = error.localizedDescription }
        if !on { Task { await tick(force: true) } }
    }

    func connect(password: String) async -> Bool {
        guard let engine else { return false }
        busy = true
        defer { busy = false }
        do {
            try engine.setServer(serverDraft)
            serverDraft = engine.server ?? serverDraft
            try await engine.login(password: password)
            notice = nil
        } catch {
            notice = error.localizedDescription
            return false
        }
        busy = false
        await syncNow()
        return true
    }

    func logout() { engine?.logout() }

    func runOnline(_ action: @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do { try await action(); notice = nil } catch { notice = error.localizedDescription }
        }
    }
}

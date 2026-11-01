import Foundation

// MARK: - Model

public struct DiaryEntry: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var text: String
    /// «На чём остановился» — необязательный контекст.
    public var context: String?
    public var timestamp: Date
    public var createdAt: Date
    public var updatedAt: Date
    /// Если запись создана отметкой плана — ссылка на этот план.
    public var planID: UUID?

    public init(id: UUID = UUID(), text: String, context: String?, timestamp: Date,
                createdAt: Date, updatedAt: Date, planID: UUID? = nil) {
        self.id = id
        self.text = text
        self.context = context
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.planID = planID
    }
}

/// Пункт простого плана на день. Без сроков, приоритетов и напоминаний.
public struct DayPlan: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var text: String
    /// Календарный день в локальном календаре, «yyyy-MM-dd».
    public var day: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Когда отмечен выполненным (и когда создана запись дневника).
    public var completedAt: Date?
    /// Запись дневника, созданная отметкой (nil, если её удалили или план не выполнен).
    public var entryID: UUID?

    public var isCompleted: Bool { completedAt != nil }

    public init(id: UUID = UUID(), text: String, day: String, createdAt: Date, updatedAt: Date,
                completedAt: Date? = nil, entryID: UUID? = nil) {
        self.id = id
        self.text = text
        self.day = day
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.entryID = entryID
    }
}

/// Заметка вне времени: сумбурный набросок, оформленный в заголовок + текст.
/// Не привязана к дню. Живёт, пока не удалят.
public struct DiaryNote: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Закреплённые показываются выше остальных.
    public var pinned: Bool

    public init(id: UUID = UUID(), title: String, body: String,
                createdAt: Date, updatedAt: Date, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
    }
}

/// Ключ календарного дня без часовых поясов в файле: «2030-03-10».
public enum DiaryDay {
    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Версионированный документ: и файл хранилища, и файл экспорта JSON.
/// Версия 1 — только записи. Версия 2 — записи + планы и связи. Версия 3 — + заметки.
/// Файл без планов пишется как v1, с планами без заметок — v2 (его читает и прежняя сборка);
/// как только появляются заметки — v3.
public struct DiaryDocument: Codable {
    public static let formatName = "daylog"
    public static let currentVersion = 3

    public var format: String
    public var version: Int
    public var exportedAt: Date?
    public var entries: [DiaryEntry]
    public var plans: [DayPlan]
    public var notes: [DiaryNote]

    public init(entries: [DiaryEntry], plans: [DayPlan] = [], notes: [DiaryNote] = [], exportedAt: Date? = nil) {
        self.format = DiaryDocument.formatName
        self.exportedAt = exportedAt
        self.entries = entries
        self.plans = plans
        self.notes = notes
        let needsV2 = !plans.isEmpty || entries.contains { $0.planID != nil }
        let needsV3 = !notes.isEmpty
        self.version = needsV3 ? 3 : (needsV2 ? 2 : 1)
    }

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, entries, plans, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt)
        entries = try c.decode([DiaryEntry].self, forKey: .entries)
        plans = try c.decodeIfPresent([DayPlan].self, forKey: .plans) ?? []
        notes = try c.decodeIfPresent([DiaryNote].self, forKey: .notes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(exportedAt, forKey: .exportedAt)
        try c.encode(entries, forKey: .entries)
        if !plans.isEmpty { try c.encode(plans, forKey: .plans) }
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
    }
}

// MARK: - Errors

public enum DiaryError: Error, LocalizedError, Equatable {
    case emptyText
    case notFound
    case storeBlocked(String)
    case unreadable(String)
    case unsupportedFormat(String)
    case writeFailed(String)
    case planAlreadyCompleted
    case planIsCompleted
    case planNotCompleted

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Запись пустая — напишите хотя бы пару слов."
        case .notFound:
            return "Запись не найдена (возможно, уже удалена)."
        case .storeBlocked(let reason):
            return "Изменения отключены, чтобы не перезаписать файл данных: \(reason)"
        case .unreadable(let reason):
            return "Не удалось прочитать файл данных: \(reason)"
        case .unsupportedFormat(let reason):
            return "Файл данных в неподдерживаемом формате: \(reason)"
        case .writeFailed(let reason):
            return "Не удалось сохранить на диск, изменения не применены: \(reason)"
        case .planAlreadyCompleted:
            return "Этот пункт плана уже отмечен — запись в дневнике уже есть."
        case .planIsCompleted:
            return "Выполненный пункт нельзя изменить. Сначала верните его в план."
        case .planNotCompleted:
            return "Этот пункт плана ещё не отмечен выполненным."
        }
    }
}

// MARK: - JSON

public enum DiaryJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    public static func decode(_ data: Data) throws -> DiaryDocument {
        // Сначала только заголовок: будущая версия распознаётся как «неподдерживаемая», а не «повреждённая».
        let header: Header
        do {
            header = try decoder().decode(Header.self, from: data)
        } catch {
            throw DiaryError.unreadable("файл повреждён или это не JSON дневника (\(error.localizedDescription))")
        }
        guard header.format == DiaryDocument.formatName else {
            throw DiaryError.unsupportedFormat("неизвестный формат «\(header.format)»")
        }
        guard header.version >= 1, header.version <= DiaryDocument.currentVersion else {
            throw DiaryError.unsupportedFormat("версия \(header.version), приложение понимает версию до \(DiaryDocument.currentVersion)")
        }
        do {
            return try decoder().decode(DiaryDocument.self, from: data)
        } catch {
            throw DiaryError.unreadable("файл повреждён (\(error.localizedDescription))")
        }
    }
}

/// JSON хранит время с точностью до секунды; приводим даты заранее, чтобы после перезапуска всё совпадало.
public func diaryNormalized(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
}

// MARK: - Formatting (ru)

public enum DiaryFormat {
    static let ru = Locale(identifier: "ru_RU")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = format
        return f
    }

    private static let timeF = make("HH:mm")
    private static let dayF = make("EEEE, d MMMM yyyy")
    private static let shortF = make("d MMM yyyy")
    private static let fileF = make("yyyy-MM-dd")
    private static let stampF = make("d MMMM yyyy, HH:mm")
    private static let dayMonthF = make("d MMMM")
    private static let weekdayF = make("EEEE")
    private static let yearF = make("yyyy")

    public static func time(_ d: Date) -> String { timeF.string(from: d) }
    public static func day(_ d: Date) -> String { capitalizedFirst(dayF.string(from: d)) }
    public static func shortDate(_ d: Date) -> String { shortF.string(from: d) }
    public static func fileDate(_ d: Date) -> String { fileF.string(from: d) }
    public static func stamp(_ d: Date) -> String { stampF.string(from: d) }
    public static func dayMonth(_ d: Date) -> String { dayMonthF.string(from: d) }
    public static func weekday(_ d: Date) -> String { weekdayF.string(from: d) }
    public static func year(_ d: Date) -> String { yearF.string(from: d) }

    public static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased(with: ru) + s.dropFirst()
    }
}

// MARK: - Store

/// Итог «Вернуть в план».
public enum PlanReopenOutcome: Equatable {
    /// Запись не меняли после отметки — она убрана из дневника.
    case removedEntry(DiaryEntry)
    /// Запись меняли — она осталась в дневнике, связь с планом снята.
    case keptEntry(DiaryEntry)
    /// Связанной записи уже нет.
    case noEntry
}

/// Хранилище: один JSON-файл, атомарная запись.
/// Любое изменение (записи и планы вместе) сначала записывается на диск и только после успеха применяется в памяти.
/// Если существующий файл не читается — хранилище блокируется и файл не перезаписывается.
public final class DiaryStore {
    public static let fileName = "entries.json"
    public static let dataDirEnv = "DAYLOG_DATA_DIR"

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(DiaryStore.fileName) }
    public private(set) var entries: [DiaryEntry] = []
    public private(set) var plans: [DayPlan] = []
    public private(set) var notes: [DiaryNote] = []
    public private(set) var blockReason: String?
    public var isBlocked: Bool { blockReason != nil }

    private let fm = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[dataDirEnv], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Daylog", isDirectory: true)
    }

    // MARK: Load / persist

    public func load() throws {
        blockReason = nil
        guard fm.fileExists(atPath: fileURL.path) else {
            entries = []
            plans = []
            notes = []
            return
        }
        do {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw DiaryError.unreadable(error.localizedDescription)
            }
            let doc = try DiaryJSON.decode(data)
            entries = DiaryStore.sorted(doc.entries)
            plans = DiaryStore.sortedPlans(doc.plans)
            notes = DiaryStore.sortNotesCanonical(doc.notes)
        } catch {
            entries = []
            plans = []
            notes = []
            let diaryError = (error as? DiaryError) ?? DiaryError.unreadable(error.localizedDescription)
            blockReason = (diaryError.errorDescription ?? "ошибка чтения") + " Файл: \(fileURL.path)"
            throw diaryError
        }
    }

    /// Единственная точка записи: записи, планы и заметки пишутся одним атомарным файлом.
    private func persist(entries newEntries: [DiaryEntry], plans newPlans: [DayPlan], notes newNotes: [DiaryNote]) throws {
        if let reason = blockReason { throw DiaryError.storeBlocked(reason) }
        let sortedEntries = DiaryStore.sorted(newEntries)
        let sortedPlans = DiaryStore.sortedPlans(newPlans)
        let sortedNotes = DiaryStore.sortNotesCanonical(newNotes)
        do {
            let data = try DiaryJSON.encoder().encode(DiaryDocument(entries: sortedEntries, plans: sortedPlans, notes: sortedNotes))
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw DiaryError.writeFailed(error.localizedDescription)
        }
        entries = sortedEntries
        plans = sortedPlans
        notes = sortedNotes
    }

    /// Перегрузка для записей/планов: заметки не меняются.
    private func persist(entries newEntries: [DiaryEntry], plans newPlans: [DayPlan]) throws {
        try persist(entries: newEntries, plans: newPlans, notes: notes)
    }

    static func sorted(_ list: [DiaryEntry]) -> [DiaryEntry] {
        list.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    static func sortedPlans(_ list: [DayPlan]) -> [DayPlan] {
        list.sorted { a, b in
            if a.day != b.day { return a.day < b.day }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Каноничный порядок заметок в файле: по времени создания, добор по id.
    static func sortNotesCanonical(_ list: [DiaryNote]) -> [DiaryNote] {
        list.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    static func cleanText(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanContext(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: Entry mutations

    @discardableResult
    public func add(text: String, context: String? = nil, at timestamp: Date = Date(), now: Date = Date()) throws -> DiaryEntry {
        let t = DiaryStore.cleanText(text)
        guard !t.isEmpty else { throw DiaryError.emptyText }
        let n = diaryNormalized(now)
        let entry = DiaryEntry(text: t, context: DiaryStore.cleanContext(context),
                               timestamp: diaryNormalized(timestamp), createdAt: n, updatedAt: n)
        try persist(entries: entries + [entry], plans: plans)
        return entry
    }

    @discardableResult
    public func update(id: UUID, text: String, context: String?, timestamp: Date, now: Date = Date()) throws -> DiaryEntry {
        let t = DiaryStore.cleanText(text)
        guard !t.isEmpty else { throw DiaryError.emptyText }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        var copy = entries
        copy[idx].text = t
        copy[idx].context = DiaryStore.cleanContext(context)
        copy[idx].timestamp = diaryNormalized(timestamp)
        copy[idx].updatedAt = diaryNormalized(now)
        let updated = copy[idx]
        try persist(entries: copy, plans: plans)
        return updated
    }

    /// Удаляет запись. Если она была создана планом, план остаётся выполненным, но без ссылки на запись.
    @discardableResult
    public func delete(id: UUID) throws -> DiaryEntry {
        guard let entry = entries.first(where: { $0.id == id }) else { throw DiaryError.notFound }
        var newPlans = plans
        for i in newPlans.indices where newPlans[i].entryID == entry.id {
            newPlans[i].entryID = nil
        }
        try persist(entries: entries.filter { $0.id != id }, plans: newPlans)
        return entry
    }

    /// Возврат только что удалённой записи («Вернуть»). Восстанавливает и связь с выполненным планом.
    public func restore(_ entry: DiaryEntry) throws {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        var e = entry
        var newPlans = plans
        if let pid = e.planID {
            if let i = newPlans.firstIndex(where: { $0.id == pid }),
               newPlans[i].isCompleted, newPlans[i].entryID == nil {
                newPlans[i].entryID = e.id
            } else if !newPlans.contains(where: { $0.id == pid && $0.entryID == e.id }) {
                e.planID = nil
            }
        }
        try persist(entries: entries + [e], plans: newPlans)
    }

    // MARK: Entry queries

    /// Записи дня, по времени: от ранних к поздним.
    public func entriesOnDay(_ day: Date, calendar: Calendar = .current) -> [DiaryEntry] {
        entries.filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
    }

    /// Поиск по всем дням (текст и «На чём остановился»), без учёта регистра; сначала новые.
    public func search(_ query: String) -> [DiaryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let found = entries.filter { e in
            e.text.range(of: q, options: opts, locale: DiaryFormat.ru) != nil
                || (e.context?.range(of: q, options: opts, locale: DiaryFormat.ru) != nil)
        }
        return Array(found.reversed())
    }

    // MARK: Plans

    /// План дня: сначала открытые (в порядке добавления), затем выполненные (в порядке отметки).
    public func plansOnDay(_ day: Date, calendar: Calendar = .current) -> [DayPlan] {
        let key = DiaryDay.key(day, calendar: calendar)
        let list = plans.filter { $0.day == key }
        let open = list.filter { !$0.isCompleted }
        let done = list.filter { $0.isCompleted }.sorted {
            ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast)
        }
        return open + done
    }

    public func plan(id: UUID) -> DayPlan? {
        plans.first { $0.id == id }
    }

    public func linkedEntry(forPlan id: UUID) -> DiaryEntry? {
        guard let p = plan(id: id), let eid = p.entryID else { return nil }
        return entries.first { $0.id == eid }
    }

    @discardableResult
    public func addPlan(text: String, day: Date, calendar: Calendar = .current, now: Date = Date()) throws -> DayPlan {
        let t = DiaryStore.cleanText(text)
        guard !t.isEmpty else { throw DiaryError.emptyText }
        let n = diaryNormalized(now)
        let p = DayPlan(text: t, day: DiaryDay.key(day, calendar: calendar), createdAt: n, updatedAt: n)
        try persist(entries: entries, plans: plans + [p])
        return p
    }

    /// Изменить текст и/или перенести на другой день. Только для невыполненных пунктов.
    @discardableResult
    public func updatePlan(id: UUID, text: String, day: Date, calendar: Calendar = .current, now: Date = Date()) throws -> DayPlan {
        let t = DiaryStore.cleanText(text)
        guard !t.isEmpty else { throw DiaryError.emptyText }
        guard let i = plans.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        guard !plans[i].isCompleted else { throw DiaryError.planIsCompleted }
        var copy = plans
        copy[i].text = t
        copy[i].day = DiaryDay.key(day, calendar: calendar)
        copy[i].updatedAt = diaryNormalized(now)
        let updated = copy[i]
        try persist(entries: entries, plans: copy)
        return updated
    }

    /// Удалить пункт плана. Запись дневника, созданная им, остаётся (теряет только ссылку на план).
    @discardableResult
    public func deletePlan(id: UUID) throws -> DayPlan {
        guard let p = plans.first(where: { $0.id == id }) else { throw DiaryError.notFound }
        var newEntries = entries
        for i in newEntries.indices where newEntries[i].planID == id {
            newEntries[i].planID = nil
        }
        try persist(entries: newEntries, plans: plans.filter { $0.id != id })
        return p
    }

    /// Вернуть удалённый пункт плана («Вернуть»), восстановив связь с его записью, если она ещё есть.
    public func restorePlan(_ plan: DayPlan) throws {
        guard !plans.contains(where: { $0.id == plan.id }) else { return }
        var p = plan
        var newEntries = entries
        if let eid = p.entryID {
            if let i = newEntries.firstIndex(where: { $0.id == eid }), newEntries[i].planID == nil {
                newEntries[i].planID = p.id
            } else if !newEntries.contains(where: { $0.id == eid && $0.planID == p.id }) {
                p.entryID = nil
            }
        }
        try persist(entries: newEntries, plans: plans + [p])
    }

    /// Отметить выполненным: атомарно создаёт ровно одну запись дневника с текущим временем.
    @discardableResult
    public func completePlan(id: UUID, now: Date = Date()) throws -> (plan: DayPlan, entry: DiaryEntry) {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        guard !plans[i].isCompleted else { throw DiaryError.planAlreadyCompleted }
        let n = diaryNormalized(now)
        let entry = DiaryEntry(text: plans[i].text, context: nil, timestamp: n,
                               createdAt: n, updatedAt: n, planID: id)
        var copy = plans
        copy[i].completedAt = n
        copy[i].entryID = entry.id
        copy[i].updatedAt = n
        let plan = copy[i]
        try persist(entries: entries + [entry], plans: copy)
        return (plan, entry)
    }

    /// Запись, созданная отметкой, с тех пор не менялась (её можно убрать при «Вернуть в план»).
    public func linkedEntryIsUnchanged(forPlan id: UUID) -> Bool {
        guard let p = plan(id: id), let e = linkedEntry(forPlan: id) else { return false }
        return e.planID == p.id
            && e.text == p.text
            && e.context == nil
            && e.timestamp == p.completedAt
            && e.updatedAt == e.createdAt
    }

    /// «Вернуть в план»: снимает отметку. Неизменённая запись убирается, изменённая — остаётся без связи.
    @discardableResult
    public func reopenPlan(id: UUID, now: Date = Date()) throws -> PlanReopenOutcome {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        guard plans[i].isCompleted else { throw DiaryError.planNotCompleted }
        let linked = linkedEntry(forPlan: id)
        let unchanged = linkedEntryIsUnchanged(forPlan: id)
        var newPlans = plans
        newPlans[i].completedAt = nil
        newPlans[i].entryID = nil
        newPlans[i].updatedAt = diaryNormalized(now)
        var newEntries = entries
        let outcome: PlanReopenOutcome
        if let e = linked {
            if unchanged {
                newEntries.removeAll { $0.id == e.id }
                outcome = .removedEntry(e)
            } else {
                if let j = newEntries.firstIndex(where: { $0.id == e.id }) { newEntries[j].planID = nil }
                outcome = .keptEntry(e)
            }
        } else {
            outcome = .noEntry
        }
        try persist(entries: newEntries, plans: newPlans)
        return outcome
    }

    // MARK: Notes

    static func cleanTitle(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Порядок для интерфейса: закреплённые сверху, внутри групп — по updatedAt вниз.
    public func sortedNotes() -> [DiaryNote] {
        notes.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    @discardableResult
    public func addNote(title: String, body: String, now: Date = Date()) throws -> DiaryNote {
        let b = DiaryStore.cleanText(body)
        guard !b.isEmpty else { throw DiaryError.emptyText }
        let n = diaryNormalized(now)
        let note = DiaryNote(title: DiaryStore.cleanTitle(title), body: b, createdAt: n, updatedAt: n)
        try persist(entries: entries, plans: plans, notes: notes + [note])
        return note
    }

    @discardableResult
    public func updateNote(id: UUID, title: String, body: String, now: Date = Date()) throws -> DiaryNote {
        let b = DiaryStore.cleanText(body)
        guard !b.isEmpty else { throw DiaryError.emptyText }
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        var copy = notes
        copy[idx].title = DiaryStore.cleanTitle(title)
        copy[idx].body = b
        copy[idx].updatedAt = diaryNormalized(now)
        let updated = copy[idx]
        try persist(entries: entries, plans: plans, notes: copy)
        return updated
    }

    /// Закрепить/открепить. Не меняет updatedAt, чтобы закрепление не перетасовывало список по дате.
    @discardableResult
    public func setPinned(id: UUID, _ pinned: Bool) throws -> DiaryNote {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        var copy = notes
        copy[idx].pinned = pinned
        let updated = copy[idx]
        try persist(entries: entries, plans: plans, notes: copy)
        return updated
    }

    @discardableResult
    public func deleteNote(id: UUID) throws -> DiaryNote {
        guard let note = notes.first(where: { $0.id == id }) else { throw DiaryError.notFound }
        try persist(entries: entries, plans: plans, notes: notes.filter { $0.id != id })
        return note
    }

    /// Возврат только что удалённой заметки («Вернуть»).
    public func restoreNote(_ note: DiaryNote) throws {
        guard !notes.contains(where: { $0.id == note.id }) else { return }
        try persist(entries: entries, plans: plans, notes: notes + [note])
    }

    /// Поиск по заголовку и телу, без учёта регистра и диакритики; порядок — как в интерфейсе.
    public func searchNotes(_ query: String) -> [DiaryNote] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return sortedNotes().filter { n in
            n.title.range(of: q, options: opts, locale: DiaryFormat.ru) != nil
                || n.body.range(of: q, options: opts, locale: DiaryFormat.ru) != nil
        }
    }

    // MARK: Export

    public func exportJSON(now: Date = Date()) throws -> Data {
        if let reason = blockReason { throw DiaryError.storeBlocked(reason) }
        return try DiaryJSON.encoder().encode(DiaryDocument(entries: entries, plans: plans, exportedAt: diaryNormalized(now)))
    }

    public static func parseExport(_ data: Data) throws -> [DiaryEntry] {
        try DiaryJSON.decode(data).entries
    }

    public static func parseExportDocument(_ data: Data) throws -> DiaryDocument {
        try DiaryJSON.decode(data)
    }

    public func exportMarkdown(now: Date = Date(), calendar: Calendar = .current) throws -> String {
        if let reason = blockReason { throw DiaryError.storeBlocked(reason) }
        var out = "# Ход дня — экспорт\n\n"
        out += "Экспортировано: \(DiaryFormat.stamp(now)). Записей: \(entries.count). "
        if !plans.isEmpty { out += "Пунктов плана: \(plans.count). " }
        out += "Дни идут по порядку, внутри дня — по времени, от ранних к поздним.\n"
        let entryGroups = Dictionary(grouping: entries) { DiaryDay.key($0.timestamp, calendar: calendar) }
        let planGroups = Dictionary(grouping: plans) { $0.day }
        let keys = Set(entryGroups.keys).union(planGroups.keys).sorted()
        for key in keys {
            let dayDate = DiaryDay.date(key, calendar: calendar) ?? now
            out += "\n## \(DiaryFormat.day(dayDate))\n\n"
            let dayPlans = DiaryStore.sortedPlans(planGroups[key] ?? [])
            let dayEntries = DiaryStore.sorted(entryGroups[key] ?? [])
            if !dayPlans.isEmpty {
                out += "План:\n\n"
                for p in dayPlans {
                    if let done = p.completedAt {
                        let when = "\(DiaryFormat.dayMonth(done)) \(DiaryFormat.year(done)) в \(DiaryFormat.time(done))"
                        out += "- [x] \(p.text) (выполнено \(when))\n"
                    } else {
                        out += "- [ ] \(p.text)\n"
                    }
                }
                if !dayEntries.isEmpty { out += "\nЗаписи:\n\n" }
            }
            for e in dayEntries {
                let text = e.text.replacingOccurrences(of: "\n", with: "\n  ")
                out += "- **\(DiaryFormat.time(e.timestamp))** — \(text)\n"
                if let c = e.context {
                    out += "  - На чём остановился: \(c.replacingOccurrences(of: "\n", with: "\n    "))\n"
                }
            }
        }
        return out
    }
}

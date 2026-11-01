import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FocusTarget: Hashable {
    case add
    case search
    case plan
}

/// Последнее действие, которое можно отменить кнопкой в строке состояния.
enum UndoAction: Equatable {
    case restoreEntry(DiaryEntry)
    case restorePlan(DayPlan)
    case reopenPlan(UUID)

    var title: String {
        switch self {
        case .restoreEntry, .restorePlan: return "Вернуть"
        case .reopenPlan: return "Отменить отметку"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let store: DiaryStore

    @Published private(set) var entries: [DiaryEntry] = []
    @Published private(set) var plans: [DayPlan] = []
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @Published var searchText: String = ""
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var undo: UndoAction?
    /// Запись, которую стоит подсветить (только что создана отметкой плана).
    @Published var highlightedEntryID: UUID?
    @Published var showPlan: Bool = true
    @Published private(set) var focusRequest: FocusTarget?
    @Published private(set) var focusToken: Int = 0

    init(store: DiaryStore = DiaryStore(directory: DiaryStore.defaultDirectory())) {
        self.store = store
        do {
            try store.load()
        } catch {
            errorMessage = nil // причина показывается отдельной плашкой блокировки
        }
        refresh()
    }

    private func refresh() {
        entries = store.entries
        plans = store.plans
    }

    var isBlocked: Bool { store.isBlocked }
    var blockReason: String? { store.blockReason }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var dayEntries: [DiaryEntry] { _ = entries; return store.entriesOnDay(selectedDay) }
    var dayPlans: [DayPlan] { _ = plans; return store.plansOnDay(selectedDay) }
    var searchResults: [DiaryEntry] { _ = entries; return store.search(searchText) }
    var isTodaySelected: Bool { Calendar.current.isDateInToday(selectedDay) }

    /// Второй уровень заголовка дня: «сегодня, воскресенье» / «вторник, 2025».
    var daySubtitle: String {
        let cal = Calendar.current
        var parts: [String] = []
        if cal.isDateInToday(selectedDay) { parts.append("сегодня") }
        else if cal.isDateInYesterday(selectedDay) { parts.append("вчера") }
        else if cal.isDateInTomorrow(selectedDay) { parts.append("завтра") }
        parts.append(DiaryFormat.weekday(selectedDay))
        if !cal.isDate(selectedDay, equalTo: Date(), toGranularity: .year) {
            parts.append(DiaryFormat.year(selectedDay))
        }
        return DiaryFormat.capitalizedFirst(parts.joined(separator: ", "))
    }

    func linkedEntry(for plan: DayPlan) -> DiaryEntry? {
        _ = entries
        return store.linkedEntry(forPlan: plan.id)
    }

    func reopenWillRemoveEntry(_ plan: DayPlan) -> Bool {
        store.linkedEntryIsUnchanged(forPlan: plan.id)
    }

    // MARK: Navigation (всегда выходит из режима поиска)

    func go(to date: Date) {
        selectedDay = Calendar.current.startOfDay(for: date)
        searchText = ""
    }

    func goToday() { go(to: Date()) }

    func goPrev() {
        go(to: Calendar.current.date(byAdding: .day, value: -1, to: selectedDay) ?? selectedDay)
    }

    func goNext() {
        go(to: Calendar.current.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay)
    }

    func requestFocus(_ target: FocusTarget) {
        if target == .plan { showPlan = true }
        focusRequest = target
        focusToken += 1
    }

    /// Меню «Причесать черновик». Само поле ввода живёт в окне и слушает этот счётчик.
    @Published private(set) var polishRequestToken = 0
    enum KeySheetIntent: Equatable { case settings, polish }
    @Published var keySheetIntent: KeySheetIntent?

    func requestPolish() { polishRequestToken += 1 }

    func showDraftStatus(_ message: String) {
        statusMessage = message
        errorMessage = nil
    }

    func showError(_ message: String) {
        errorMessage = message
        statusMessage = nil
    }

    // MARK: Entry mutations

    @discardableResult
    func add(text: String, context: String?, timestamp: Date) -> Bool {
        do {
            let e = try store.add(text: text, context: context, at: timestamp)
            refresh()
            undo = nil
            highlightedEntryID = nil
            go(to: e.timestamp)
            saved("Записано в дневник: \(DiaryFormat.shortDate(e.timestamp)), \(DiaryFormat.time(e.timestamp))")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    @discardableResult
    func update(id: UUID, text: String, context: String?, timestamp: Date) -> Bool {
        do {
            let e = try store.update(id: id, text: text, context: context, timestamp: timestamp)
            refresh()
            undo = nil
            if !isSearching { selectedDay = Calendar.current.startOfDay(for: e.timestamp) }
            saved("Изменения сохранены")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func delete(_ entry: DiaryEntry) {
        do {
            let removed = try store.delete(id: entry.id)
            refresh()
            undo = .restoreEntry(removed)
            saved("Запись удалена")
        } catch {
            fail(error)
        }
    }

    // MARK: Plan mutations

    @discardableResult
    func addPlan(text: String) -> Bool {
        do {
            let p = try store.addPlan(text: text, day: selectedDay)
            refresh()
            undo = nil
            saved("Добавлено в план: «\(p.text)»")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    @discardableResult
    func updatePlan(id: UUID, text: String, day: Date) -> Bool {
        do {
            let p = try store.updatePlan(id: id, text: text, day: day)
            refresh()
            undo = nil
            if p.day != DiaryDay.key(selectedDay), let d = DiaryDay.date(p.day) {
                saved("План перенесён на \(DiaryFormat.dayMonth(d))")
            } else {
                saved("План изменён")
            }
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func movePlanToNextDay(_ plan: DayPlan) {
        guard let d = DiaryDay.date(plan.day),
              let next = Calendar.current.date(byAdding: .day, value: 1, to: d) else { return }
        updatePlan(id: plan.id, text: plan.text, day: next)
    }

    func deletePlan(_ plan: DayPlan) {
        do {
            let removed = try store.deletePlan(id: plan.id)
            refresh()
            undo = .restorePlan(removed)
            saved(removed.isCompleted ? "Пункт плана удалён, запись в дневнике осталась" : "Пункт плана удалён")
        } catch {
            fail(error)
        }
    }

    /// Отметить выполненным: одна атомарная операция «план + запись».
    func completePlan(_ plan: DayPlan) {
        do {
            let result = try store.completePlan(id: plan.id)
            refresh()
            undo = .reopenPlan(result.plan.id)
            highlightedEntryID = result.entry.id
            if !isSearching, !Calendar.current.isDate(selectedDay, inSameDayAs: result.entry.timestamp) {
                // Запись создаётся с текущим временем — показываем день, где она появилась.
                selectedDay = Calendar.current.startOfDay(for: result.entry.timestamp)
            }
            saved("Выполнено и записано в дневник в \(DiaryFormat.time(result.entry.timestamp))")
        } catch {
            fail(error)
        }
    }

    func reopenPlan(_ plan: DayPlan) {
        reopenPlan(id: plan.id)
    }

    private func reopenPlan(id: UUID) {
        do {
            let outcome = try store.reopenPlan(id: id)
            refresh()
            undo = nil
            highlightedEntryID = nil
            switch outcome {
            case .removedEntry:
                saved("Пункт возвращён в план, его запись убрана из дневника")
            case .keptEntry:
                saved("Пункт возвращён в план; изменённая запись осталась в дневнике")
            case .noEntry:
                saved("Пункт возвращён в план")
            }
        } catch {
            fail(error)
        }
    }

    func performUndo() {
        guard let action = undo else { return }
        do {
            switch action {
            case .restoreEntry(let e):
                try store.restore(e)
                refresh()
                undo = nil
                saved("Запись возвращена")
            case .restorePlan(let p):
                try store.restorePlan(p)
                refresh()
                undo = nil
                saved("Пункт плана возвращён")
            case .reopenPlan(let id):
                reopenPlan(id: id)
            }
        } catch {
            fail(error)
        }
    }

    private func saved(_ message: String) {
        statusMessage = "\(message). Сохранено в \(DiaryFormat.time(Date()))."
        errorMessage = nil
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = nil
    }

    // MARK: Export

    func exportJSON() {
        do {
            let data = try store.exportJSON()
            guard let url = askSaveURL(name: "daylog-\(DiaryFormat.fileDate(Date())).json", type: .json) else { return }
            try data.write(to: url, options: .atomic)
            saved("Экспорт JSON: \(url.lastPathComponent)")
        } catch {
            fail(error)
        }
    }

    func exportMarkdown() {
        do {
            let text = try store.exportMarkdown()
            let mdType = UTType(filenameExtension: "md") ?? .plainText
            guard let url = askSaveURL(name: "daylog-\(DiaryFormat.fileDate(Date())).md", type: mdType) else { return }
            try Data(text.utf8).write(to: url, options: .atomic)
            saved("Экспорт Markdown: \(url.lastPathComponent)")
        } catch {
            fail(error)
        }
    }

    private func askSaveURL(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Экспорт дневника"
        panel.prompt = "Сохранить"
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func revealDataFile() {
        let fm = FileManager.default
        if fm.fileExists(atPath: store.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
        } else if fm.fileExists(atPath: store.directory.path) {
            NSWorkspace.shared.open(store.directory)
        } else {
            errorMessage = "Файла данных ещё нет — он появится после первой записи: \(store.fileURL.path)"
        }
    }
}

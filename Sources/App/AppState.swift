import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FocusTarget: Hashable {
    case add
    case search
    case plan
}

/// Какое пространство показано в окне: день (записи + план), заметочник или чат.
enum AppMode: Hashable {
    case organizer
    case day
    case notes
    case ask
}

/// Последнее действие, которое можно отменить кнопкой в строке состояния.
enum UndoAction: Equatable {
    case restoreEntry(DiaryEntry)
    case restorePlan(DayPlan)
    case reopenPlan(UUID)
    case restoreNote(DiaryNote)

    var title: String {
        switch self {
        case .restoreEntry, .restorePlan, .restoreNote: return "Вернуть"
        case .reopenPlan: return "Отменить отметку"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let store: DiaryStore

    @Published private(set) var entries: [DiaryEntry] = []
    @Published private(set) var plans: [DayPlan] = []
    @Published private(set) var notes: [DiaryNote] = []
    @Published private(set) var projects: [DiaryProject] = []
    @Published var organizerCaptureText = ""
    @Published var mode: AppMode = .organizer
    @Published var chatMessages: [ChatMessage] = []
    @Published private(set) var chatBusy: Bool = false
    private var chatTask: Task<Void, Never>?
    /// Одноразовый итог текущего дня (приложение не сохраняет; живёт, пока открыт sheet).
    @Published private(set) var daySummary: String?
    @Published private(set) var summaryBusy: Bool = false
    private var summaryTask: Task<Void, Never>?
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @Published var searchText: String = ""
    @Published var noteSearchText: String = ""
    @Published var selectedNoteID: UUID?
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
        notes = store.notes
        projects = store.projects
    }

    @discardableResult
    func changeOrganizer(_ message: String, _ change: () throws -> Void) -> Bool {
        do {
            try change()
            refresh()
            undo = nil
            saved(message)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    var isBlocked: Bool { store.isBlocked }
    var blockReason: String? { store.blockReason }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var dayEntries: [DiaryEntry] { _ = entries; return store.entriesOnDay(selectedDay) }
    var dayPlans: [DayPlan] { _ = plans; return store.plansOnDay(selectedDay) }
    var searchResults: [DiaryEntry] { _ = entries; return store.search(searchText) }
    var sortedNotes: [DiaryNote] { _ = notes; return store.sortedNotes() }
    var noteSearchResults: [DiaryNote] { _ = notes; return store.searchNotes(noteSearchText) }
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
        clearDaySummary()
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

    // MARK: Note mutations

    @discardableResult
    func addNote(title: String, body: String) -> Bool {
        do {
            _ = try store.addNote(title: title, body: body)
            refresh()
            undo = nil
            saved("Заметка сохранена")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    @discardableResult
    func updateNote(id: UUID, title: String, body: String) -> Bool {
        do {
            _ = try store.updateNote(id: id, title: title, body: body)
            refresh()
            undo = nil
            saved("Изменения сохранены")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func deleteNote(_ note: DiaryNote) {
        do {
            let removed = try store.deleteNote(id: note.id)
            refresh()
            undo = .restoreNote(removed)
            saved("Заметка удалена")
        } catch {
            fail(error)
        }
    }

    func setNotePinned(_ note: DiaryNote, _ pinned: Bool) {
        do {
            _ = try store.setPinned(id: note.id, pinned)
            refresh()
            undo = nil
            saved(pinned ? "Заметка закреплена" : "Заметка откреплена")
        } catch {
            fail(error)
        }
    }

    /// «Оформить» в редакторе заметки: набросок → заголовок и тело через xAI.
    /// Заметку всегда можно сохранить и без сети — ошибка ИИ не блокирует редактирование.
    func polishNote(draft: String) async -> (title: String, body: String)? {
        guard let key = XAIKeyStore.load() else {
            showError(DraftPolishError.noKey.localizedDescription)
            return nil
        }
        do {
            return try await NotePolishClient().polish(draft: draft, apiKey: key)
        } catch {
            showError(error.localizedDescription)
            return nil
        }
    }

    // MARK: Notes chat

    func sendChat(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard !chatBusy else { return }
        chatMessages.append(ChatMessage(role: .user, text: q))
        let history = Array(chatMessages.dropLast())
        // Снимок заметок: по нему и уходит запрос, и разрешаются номера источников,
        // чтобы правка/удаление заметок во время запроса не сбивала ссылки.
        let notesSnapshot = store.notes
        chatBusy = true
        chatTask = Task { @MainActor in
            guard let key = XAIKeyStore.load() else {
                showError(DraftPolishError.noKey.localizedDescription)
                chatBusy = false
                return
            }
            do {
                let (answer, nums) = try await NotesChatClient().ask(
                    notes: notesSnapshot, history: history, question: q, apiKey: key
                )
                // Задачу могли отменить (clearChat) уже после ответа — не пишем в очищенную ленту.
                if Task.isCancelled { return }
                let valid = NotesChat.resolveSources(nums, noteCount: notesSnapshot.count)
                let ids = valid.map { notesSnapshot[$0 - 1].id }
                chatMessages.append(ChatMessage(role: .assistant, text: answer, sourceNoteIDs: ids))
            } catch is CancellationError {
                return // отмена — молча; chatBusy сбрасывает clearChat
            } catch let e as DraftPolishError {
                if Task.isCancelled { return }
                if case .contextTooLarge = e {
                    chatMessages.append(ChatMessage(role: .assistant, text: "⚠️ " + e.localizedDescription))
                } else {
                    showError(e.localizedDescription)
                }
            } catch {
                if Task.isCancelled { return }
                showError(error.localizedDescription)
            }
            chatBusy = false
        }
    }

    func clearChat() {
        chatTask?.cancel()
        chatBusy = false
        chatMessages = []
    }

    // MARK: Итог дня

    /// Спокойный итог прожитого дня по его записям, через xAI. По явному действию.
    /// Отправляются только записи выбранного дня; план и другие дни — нет. Ответ приложение не сохраняет.
    func summarizeDay() {
        guard !summaryBusy else { return }
        // Снимок записей дня: по нему и уходит запрос, правки во время запроса не влияют.
        let snapshot = dayEntries
        guard !snapshot.isEmpty else {
            showDraftStatus("За этот день записей нет — нечего подытоживать.")
            return
        }
        summaryBusy = true
        summaryTask = Task { @MainActor in
            guard let key = XAIKeyStore.load() else {
                showError(DraftPolishError.noKey.localizedDescription)
                summaryBusy = false
                return
            }
            do {
                let text = try await DaySummaryClient().summarize(entries: snapshot, apiKey: key)
                if Task.isCancelled { return }
                daySummary = text
            } catch is CancellationError {
                // Отмена — молча и БЕЗ сброса summaryBusy: его снимает тот, кто отменил
                // (clearDaySummary), либо им уже владеет новый запущенный запрос.
                return
            } catch {
                if Task.isCancelled { return }
                showError(error.localizedDescription)
            }
            summaryBusy = false
        }
    }

    func clearDaySummary() {
        summaryTask?.cancel()
        summaryBusy = false
        daySummary = nil
    }

    func openSource(_ id: UUID) {
        mode = .notes
        selectedNoteID = id
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
            case .restoreNote(let n):
                try store.restoreNote(n)
                refresh()
                undo = nil
                saved("Заметка возвращена")
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

    func exportMarkdownFolder() {
        let panel = NSOpenPanel()
        panel.title = "Экспорт в папку Markdown"
        panel.message = "В выбранной папке будет создана новая папка с дневником, планами, заметками и JSON-архивом. Экспортируются только сохранённые данные; черновики не включены."
        panel.prompt = "Выбрать папку"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let result = try store.exportMarkdownFolder(parentDirectory: directory)
            NSWorkspace.shared.activateFileViewerSelecting([result.folderURL])
            saved("Экспорт Markdown в папку: \(result.folderURL.lastPathComponent)")
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

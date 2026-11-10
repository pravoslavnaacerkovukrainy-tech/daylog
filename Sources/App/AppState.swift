import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FocusTarget: Hashable {
    case add
    case search
}

/// Рабочее пространство: задачи, дневник, заметки или чат.
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

/// Сетевые операции ИИ. Вызываются только после явного согласия в интерфейсе.
/// В тестах подменяются шпионами: без ключа, без сети, без настоящих записей.
struct AIServices {
    var polishNote: (_ draft: String) async throws -> (title: String, body: String)
    var summarizeDay: (_ entries: [DiaryEntry]) async throws -> String
    var askNotes: (_ notes: [DiaryNote], _ history: [ChatMessage], _ question: String) async throws -> (answer: String, sources: [Int])

    static let live = AIServices(
        polishNote: { draft in
            guard let key = QwenKeyStore.resolve() else { throw DraftPolishError.noKey }
            return try await NotePolishClient().polish(draft: draft, apiKey: key)
        },
        summarizeDay: { entries in
            guard let key = QwenKeyStore.resolve() else { throw DraftPolishError.noKey }
            return try await DaySummaryClient().summarize(entries: entries, apiKey: key)
        },
        askNotes: { notes, history, question in
            guard let key = QwenKeyStore.resolve() else { throw DraftPolishError.noKey }
            return try await NotesChatClient().ask(notes: notes, history: history, question: question, apiKey: key)
        }
    )
}

/// Что именно уйдёт в QwenCloud по «Оформить» у заметки. Отправляется только после «Отправить».
struct NotePolishPreflight: Identifiable, Equatable {
    let id = UUID()
    let draft: String
}

@MainActor
final class AppState: ObservableObject {
    let store: DiaryStore
    private let ai: AIServices

    @Published private(set) var entries: [DiaryEntry] = []
    @Published private(set) var plans: [DayPlan] = []
    @Published private(set) var notes: [DiaryNote] = []
    @Published private(set) var projects: [DiaryProject] = []
    @Published private(set) var chaos: [ChaosItem] = []
    private var breakdownDrafts: [UUID: TaskBreakdownDraft] = [:]

    func breakdownDraft(for task: DayPlan) -> TaskBreakdownDraft {
        // sheet хранит исходный item, после сохранения нужен свежий снимок из состояния.
        let current = plans.first { $0.id == task.id } ?? task
        // Вызывается из sheet body: существующий ObservableObject здесь не меняется.
        if let draft = breakdownDrafts[task.id] { return draft }
        let draft = TaskBreakdownDraft(parent: current)
        breakdownDrafts[task.id] = draft
        return draft
    }

    @Published var organizerCaptureText = ""
    /// Команда «Записать в место хаоса»: раздел дел открывается на месте хаоса с фокусом в поле.
    @Published var chaosCaptureRequested = false
    /// Счётчик для уже открытого раздела: повторная команда снова ставит фокус.
    @Published private(set) var chaosCaptureToken = 0
    /// Раздел «Дел», который человек выбрал в этом профиле. nil, пока выбора не было.
    @Published private(set) var savedOrganizerSection: String?
    @Published var mode: AppMode = .organizer
    @Published var taskCreationRequested = false
    @Published var chatMessages: [ChatMessage] = []
    @Published private(set) var chatBusy: Bool = false
    private var chatTask: Task<Void, Never>?
    /// Одноразовый итог текущего дня (приложение не сохраняет; живёт, пока открыт sheet).
    @Published private(set) var daySummary: String?
    @Published private(set) var summaryBusy: Bool = false
    /// Записи дня, показанные перед отправкой итога. Сеть только после confirmDaySummary().
    @Published private(set) var summaryPreflight: [DiaryEntry]?
    private var summaryTask: Task<Void, Never>?
    /// Показанный набросок заметки перед «Оформить». Сеть только после confirmNotePolish().
    @Published private(set) var notePolishPreflight: NotePolishPreflight?
    /// Явное согласие передавать выбранные заметки в QwenCloud. Живёт до выхода из приложения.
    @Published private(set) var chatConsentGiven = false
    /// Заметки, которые человек оставил отмеченными для чата. Новый набор начинает новую беседу.
    @Published var chatSelectedNoteIDs: Set<UUID> = [] {
        didSet {
            if oldValue != chatSelectedNoteIDs { clearChat() }
        }
    }
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @Published var searchText: String = ""
    @Published var noteSearchText: String = ""
    @Published var selectedNoteID: UUID?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var undo: UndoAction?
    /// Запись, которую стоит подсветить после выполнения задачи.
    @Published var highlightedEntryID: UUID?
    @Published private(set) var focusRequest: FocusTarget?
    @Published private(set) var focusToken: Int = 0

    init(store: DiaryStore = DiaryStore(directory: DiaryStore.defaultDirectory()), ai: AIServices = .live) {
        self.store = store
        self.ai = ai
        do {
            try store.load()
        } catch {
            errorMessage = nil // причина показывается отдельной плашкой блокировки
        }
        savedOrganizerSection = Self.readUIState(at: uiStateURL)?.organizerSection
        refresh()
    }

    // MARK: Раздел «Дел» этого профиля

    static let uiStateFileName = "ui-state.json"
    private var uiStateURL: URL { store.directory.appendingPathComponent(Self.uiStateFileName) }

    private struct UIState: Codable { var organizerSection: String? }

    private static func readUIState(at url: URL) -> UIState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UIState.self, from: data)
    }

    /// Запоминает раздел, выбранный человеком. Хранится рядом с данными профиля, отдельно от дневника.
    func rememberOrganizerSection(_ raw: String) {
        guard savedOrganizerSection != raw else { return }
        savedOrganizerSection = raw
        guard !isBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(UIState(organizerSection: raw))
            try data.write(to: uiStateURL, options: .atomic)
        } catch {
            // Раздел не критичен: дневник и задачи от этого не зависят.
        }
    }

    /// Открыть «Дела → Место хаоса» и поставить фокус в поле. Черновик не трогается, запись не создаётся.
    func requestChaosCapture() {
        mode = .organizer
        chaosCaptureRequested = true
        chaosCaptureToken += 1
    }

    private func refresh() {
        entries = store.entries
        plans = store.plans
        notes = store.notes
        projects = store.projects
        chaos = store.chaos
        // Обновление происходит после мутации хранилища, вне вычисления SwiftUI body.
        for (id, draft) in breakdownDrafts {
            if let current = plans.first(where: { $0.id == id }) { draft.reopen(parent: current) }
        }
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

    /// `.add` открывает дневник и ставит фокус в поле записи. `.search` ищет в текущем разделе
    /// и режим не меняет; в «Спросить» поля поиска нет, запрос игнорируется.
    func requestFocus(_ target: FocusTarget) {
        switch target {
        case .add: mode = .day
        case .search: if mode == .ask { return }
        }
        focusRequest = target
        focusToken += 1
    }

    func requestNewTask() {
        mode = .organizer
        guard !isBlocked else { return }
        taskCreationRequested = true
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

    func deletePlan(_ plan: DayPlan) {
        do {
            let removed = try store.deletePlan(id: plan.id)
            refresh()
            undo = .restorePlan(removed)
            saved(removed.isCompleted ? "Задача удалена, запись в дневнике осталась" : "Задача удалена")
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
                saved("Задача возвращена в работу, её запись убрана из дневника")
            case .keptEntry:
                saved("Задача возвращена в работу; изменённая запись осталась в дневнике")
            case .noEntry:
                saved("Задача возвращена в работу")
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

    /// «Оформить» в редакторе заметки, шаг 1: только показать, что уйдёт в QwenCloud. Сети нет.
    func beginNotePolish(draft: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBlocked else { return }
        notePolishPreflight = NotePolishPreflight(draft: draft)
    }

    func cancelNotePolish() {
        notePolishPreflight = nil
    }

    /// Шаг 2, после «Отправить»: уходит ровно показанный текст. Заметку сохраняет только человек.
    /// Ошибка ИИ не трогает заметку: результат nil, исходный текст остаётся в редакторе.
    func confirmNotePolish() async -> (title: String, body: String)? {
        guard let preflight = notePolishPreflight else { return nil }
        notePolishPreflight = nil
        do {
            return try await ai.polishNote(preflight.draft)
        } catch is CancellationError {
            return nil
        } catch {
            showError(error.localizedDescription)
            return nil
        }
    }

    // MARK: Notes chat

    /// Заметки, которые уйдут с вопросом: только отмеченные и только после согласия.
    var chatNotesToSend: [DiaryNote] {
        _ = notes
        guard chatConsentGiven else { return [] }
        return store.sortedNotes().filter { chatSelectedNoteIDs.contains($0.id) }
    }

    /// Объём контекста заметок в знаках, как он уйдёт в запрос.
    var chatContextCharacters: Int { NotesChat.numberedNotes(chatNotesToSend).count }

    /// Согласие на передачу. Само ничего не отправляет: вопрос уходит отдельным «Спросить».
    func giveChatConsent(selected: Set<UUID>) {
        let existing = Set(store.notes.map(\.id))
        chatSelectedNoteIDs = selected.intersection(existing)
        chatConsentGiven = true
    }

    /// Отменить передачу: идущий запрос прерывается, беседа очищается, новые запросы ждут согласия.
    func revokeChatConsent() {
        chatConsentGiven = false
        chatSelectedNoteIDs = []
        clearChat()
    }

    func setChatNote(_ id: UUID, selected: Bool) {
        if selected { chatSelectedNoteIDs.insert(id) } else { chatSelectedNoteIDs.remove(id) }
    }

    var canSendChat: Bool { chatConsentGiven && !chatNotesToSend.isEmpty && !chatBusy && !isBlocked }

    @discardableResult
    func sendChat(_ question: String) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        guard !chatBusy, !isBlocked else { return false }
        // Без явного согласия и выбранных заметок контекст не собирается и не отправляется.
        guard chatConsentGiven else { return false }
        // Снимок выбранных заметок: по нему и уходит запрос, и разрешаются номера источников,
        // чтобы правка/удаление заметок во время запроса не сбивала ссылки.
        let notesSnapshot = chatNotesToSend
        guard !notesSnapshot.isEmpty else { return false }
        chatMessages.append(ChatMessage(role: .user, text: q))
        let history = Array(chatMessages.dropLast())
        chatBusy = true
        let ask = ai.askNotes
        chatTask = Task { @MainActor in
            do {
                let (answer, nums) = try await ask(notesSnapshot, history, q)
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
        return true
    }

    /// Прервать идущий запрос, не очищая беседу.
    func cancelChatRequest() {
        chatTask?.cancel()
        chatTask = nil
        chatBusy = false
    }

    func clearChat() {
        chatTask?.cancel()
        chatBusy = false
        chatMessages = []
    }

    // MARK: Итог дня

    /// Спокойный итог прожитого дня, шаг 1: показать записи и получателя. Сети нет.
    /// Отправляются только записи выбранного дня; план и другие дни — нет. Ответ приложение не сохраняет.
    func summarizeDay() {
        guard !summaryBusy, !isBlocked else { return }
        // Снимок записей дня: ровно он показывается и уходит после «Отправить».
        let snapshot = dayEntries
        guard !snapshot.isEmpty else {
            showDraftStatus("За этот день записей нет - нечего подытоживать.")
            return
        }
        daySummary = nil
        summaryPreflight = snapshot
    }

    /// Шаг 2, после «Отправить»: уходит показанный снимок, а не текущее состояние дня.
    func confirmDaySummary() {
        guard !summaryBusy, let snapshot = summaryPreflight else { return }
        summaryPreflight = nil
        summaryBusy = true
        let summarize = ai.summarizeDay
        summaryTask = Task { @MainActor in
            do {
                let text = try await summarize(snapshot)
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
        summaryPreflight = nil
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

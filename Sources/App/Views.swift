import SwiftUI
import AppKit

// MARK: - Controls (токены темы в Theme.swift)

/// Флажок с заметной рамкой: системный на macOS 27 почти сливается с фоном.
struct QuietCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Theme.accent : Theme.quiet)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "включено" : "выключено")
    }
}

/// Полоса режимов: тот же сегментированный переключатель, но сегменты одной ширины.
/// SwiftUI `Picker` не даёт задать распределение сегментов, поэтому здесь NSSegmentedControl.
struct ModeStrip: NSViewRepresentable {
    @Binding var mode: AppMode
    let items: [(title: String, mode: AppMode)]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: items.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("Режим")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = items.firstIndex { $0.mode == mode } ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? natural.width, height: natural.height)
    }

    final class Coordinator: NSObject {
        var parent: ModeStrip
        init(_ parent: ModeStrip) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.items.indices.contains(index) else { return }
            parent.mode = parent.items[index].mode
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focus: FocusTarget?
    @Environment(\.openWindow) private var openWindow

    @State private var draftText = ""
    @State private var draftContext = ""
    @State private var showContext = false
    @State private var showDayPicker = false
    @State private var customTime = false
    @State private var draftTime = Date()
    @State private var editing: DiaryEntry?
    @State private var pendingDelete: DiaryEntry?

    @State private var previousDraft: (original: String, improved: String)?
    @State private var polishBusy = false
    @State private var polishTask: Task<Void, Never>?
    @State private var keyField = ""
    @State private var keyError: String?

    private var draftIsBlank: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Group {
            switch state.mode {
            case .organizer:
                VStack(spacing: 0) {
                    OrganizerView(state: state)
                    statusArea.padding(.horizontal, 24).padding(.bottom, 10)
                }
            case .day:
                mainColumn
                    .frame(minWidth: 440, maxWidth: .infinity)
            case .notes:
                VStack(spacing: 0) {
                    NotesView()
                    statusArea
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                }
                .background(Theme.canvas)
            case .ask:
                VStack(spacing: 0) {
                    AskView()
                    statusArea
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                }
                .background(Theme.canvas)
            }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .toolbar { toolbarContent }
        .onAppear {
            let open = openWindow
            AppDelegate.openMainWindow = {
                NSApp.activate(ignoringOtherApps: true)
                open(id: "main")
            }
            DispatchQueue.main.async { focus = .add }
        }
        .onChange(of: state.focusToken) { _, _ in
            // Режим меняет только запрос на запись (AppState.requestFocus). Поиск остаётся в своём разделе:
            // «Дела» и «Заметки» ловят тот же счётчик у себя.
            if state.mode == .day { focus = state.focusRequest }
        }
        .onChange(of: customTime) { _, on in
            if on { draftTime = defaultCustomTime() }
        }
        .onChange(of: state.polishRequestToken) { _, _ in
            beginPolish()
        }
        .onChange(of: state.mode) { _, mode in
            if mode != .day { cancelPolish() }
        }
        .sheet(isPresented: Binding(get: { state.keySheetIntent != nil }, set: { if !$0 { closeKeySheet() } })) {
            APIKeySheet(
                key: $keyField,
                error: keyError,
                hasSavedKey: GroqKeyStore.load() != nil,
                onCancel: closeKeySheet,
                onSave: saveKey,
                onDelete: deleteKey
            )
        }
        .sheet(isPresented: Binding(get: { state.summaryPreflight != nil || state.daySummary != nil || state.summaryBusy },
                                    set: { if !$0 { state.clearDaySummary() } })) {
            if let entries = state.summaryPreflight {
                AIPreflightSheet(
                    title: "Итог дня за \(DiaryFormat.shortDate(state.selectedDay))",
                    explanation: "В Groq уйдут только записи этого дня, показанные ниже. План, задачи, заметки и другие дни не отправляются. Итог не записывается в дневник. Условия обработки данных определяет Groq.",
                    payload: DaySummary.buildDayText(entries),
                    onCancel: state.clearDaySummary,
                    onSend: state.confirmDaySummary)
            } else {
                DaySummarySheet(summary: state.daySummary, busy: state.summaryBusy,
                                day: state.selectedDay, onClose: state.clearDaySummary)
            }
        }
    }

    // MARK: Toolbar

    /// Режимы вынесены из тулбара: там при узком окне они уходили в меню переполнения.
    private var modeBar: some View {
        VStack(spacing: 0) {
            ModeStrip(mode: $state.mode, items: [
                ("Дела", .organizer),
                ("Дневник", .day),
                ("Заметки", .notes),
                ("Спросить", .ask),
            ])
            .frame(width: 350)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                FocusTimerButton(timer: state.focusTimer).padding(.trailing, 24)
            }
            Divider()
        }
        .background(Theme.pane)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if state.mode == .day {
            ToolbarItemGroup(placement: .navigation) {
                Button { state.goPrev() } label: {
                    Label("Предыдущий день", systemImage: "chevron.left")
                }
                .help("Предыдущий день (⌘[)")
                Button { state.goNext() } label: {
                    Label("Следующий день", systemImage: "chevron.right")
                }
                .help("Следующий день (⌘])")
                Button("Сегодня") { state.goToday() }
                    .help("Перейти к сегодняшнему дню (⌘T)")
                Button(DiaryFormat.shortDate(state.selectedDay)) { showDayPicker.toggle() }
                    .help("Выбрать день")
                    .popover(isPresented: $showDayPicker, arrowEdge: .bottom) {
                        DatePicker("День", selection: Binding(get: { state.selectedDay }, set: { state.go(to: $0) }),
                                   displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.graphical)
                            .padding(12)
                    }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { state.summarizeDay() } label: {
                    Label("Итог дня", systemImage: "doc.plaintext")
                }
                .help("Спокойный итог дня через Groq. Перед отправкой покажу записи (⌥⌘I)")
                .disabled(state.dayEntries.isEmpty || state.summaryBusy || state.isBlocked || state.isSearching)
            }
        }
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            dayHeader
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)
            composer
                .padding(.horizontal, 24)
            statusArea
                .padding(.horizontal, 24)
                .padding(.top, 10)
            feed
        }
        .background(Theme.canvas)
        .sheet(item: $editing) { entry in
            EntryEditor(state: state, entry: entry)
        }
        .confirmationDialog("Удалить запись?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button("Удалить", role: .destructive) {
                state.delete(entry)
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(deleteMessage(for: entry))
        }
    }

    private func deleteMessage(for entry: DiaryEntry) -> String {
        var s = "«\(entry.text)» (\(DiaryFormat.shortDate(entry.timestamp)), \(DiaryFormat.time(entry.timestamp))). Сразу после удаления запись можно вернуть."
        if entry.planID != nil { s += " Задача останется отмеченной выполненной." }
        return s
    }

    private var dayHeader: some View {
        // Широко: заголовок слева, поиск справа. Узко: поиск под заголовком на всю ширину.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                dayTitle
                Spacer(minLength: 16)
                searchField
                    .frame(width: 230)
            }
            VStack(alignment: .leading, spacing: 10) {
                dayTitle
                searchField
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var dayTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.isSearching ? "Поиск" : DiaryFormat.dayMonth(state.selectedDay))
                .font(Theme.display)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(state.isSearching ? "По всем дням, сначала новые" : state.daySubtitle)
                .font(Theme.text)
                .foregroundStyle(Theme.quiet)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.quiet)
            TextField("Поиск по всем дням", text: $state.searchText)
                .textFieldStyle(.plain)
                .focused($focus, equals: .search)
                .onExitCommand { state.searchText = ""; focus = .add }
                .accessibilityLabel("Поиск по всем дням")
            if state.isSearching {
                Button { state.searchText = ""; focus = .add } label: {
                    Image(systemName: "xmark.circle.fill").compactHitArea(24)
                }
                .padding(.vertical, -5)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.quiet)
                .help("Сбросить поиск (Esc)")
                .accessibilityLabel("Сбросить поиск")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(focus == .search ? Theme.accent : Theme.rail, lineWidth: focus == .search ? 1.5 : 1))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Что сделано или произошло?", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(Theme.input)
                    .foregroundStyle(Theme.ink)
                    .focused($focus, equals: .add)
                    .onSubmit(submit)
                    .accessibilityLabel("Новая запись в дневник")
                if polishBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Groq улучшает текст")
                    Button("Остановить", action: cancelPolish)
                } else {
                    Button("Улучшить текст", systemImage: "sparkles", action: beginPolish)
                        .disabled(draftIsBlank || state.isBlocked)
                        .fixedSize()
                        .help("Улучшить формулировку через Groq (⌥⌘↩)")
                }
            }
            if let previousDraft, draftText == previousDraft.improved, !polishBusy {
                Button("Вернуть исходный текст") {
                    draftText = previousDraft.original
                    self.previousDraft = nil
                    focus = .add
                }
                .buttonStyle(.borderless)
            }
            if showContext {
                TextField("На чём остановился — чтобы потом продолжить", text: $draftContext, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel("На чём остановился")
            }
            // Широко — одна строка; узко — выбор времени отдельной строкой. Кнопка «Записать» видна всегда.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    timeToggle
                    if customTime { timePicker }
                    contextToggle
                    Spacer(minLength: 8)
                    submitButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        timeToggle
                        contextToggle
                        Spacer(minLength: 8)
                        submitButton
                    }
                    if customTime { timePicker }
                }
            }
            .font(Theme.text)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focus == .add ? Theme.accent : Theme.rail, lineWidth: focus == .add ? 1.5 : 1))
        .disabled(state.isBlocked)
    }

    private var timeToggle: some View {
        Toggle("Другое время", isOn: $customTime)
            .toggleStyle(QuietCheckboxStyle())
            .fixedSize()
            .help("Без отметки время записи ставится автоматически")
    }

    private var contextToggle: some View {
        Toggle("На чём остановился", isOn: $showContext)
            .toggleStyle(QuietCheckboxStyle())
            .fixedSize()
    }

    private var timePicker: some View {
        DatePicker("Дата и время записи", selection: $draftTime)
            .labelsHidden()
            .datePickerStyle(.field)
            .fixedSize()
    }

    private var submitButton: some View {
        Button("Записать", action: submit)
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(draftIsBlank || state.isBlocked)
            .fixedSize()
            .help("Записать в дневник (Enter или ⌘↩)")
    }

    private func defaultCustomTime() -> Date {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: state.selectedDay)
        let t = cal.dateComponents([.hour, .minute], from: now)
        comps.hour = t.hour
        comps.minute = t.minute
        return cal.date(from: comps) ?? now
    }

    private func submit() {
        guard !draftIsBlank, !state.isBlocked, !polishBusy else { return }
        let ts = customTime ? draftTime : Date()
        if state.add(text: draftText, context: showContext ? draftContext : nil, timestamp: ts) {
            draftText = ""
            previousDraft = nil
            draftContext = ""
            showContext = false
            customTime = false
            focus = .add
        }
    }

    private func beginPolish() {
        let original = draftText
        let text = DraftPolish.normalizeInput(original)
        guard state.mode == .day, !text.isEmpty, !state.isBlocked, !polishBusy else { return }
        guard let key = GroqKeyStore.resolve() else {
            keyField = ""
            keyError = nil
            state.keySheetIntent = .polish
            return
        }
        polishBusy = true
        polishTask = Task {
            defer {
                if !Task.isCancelled {
                    polishTask = nil
                    polishBusy = false
                }
            }
            do {
                let result = try await DraftPolishClient().polish(draft: text, apiKey: key)
                try Task.checkCancellation()
                guard draftText == original else {
                    state.showDraftStatus("Черновик изменился. Нажмите «Улучшить текст» ещё раз.")
                    return
                }
                if result != original {
                    let before = previousDraft.flatMap { $0.improved == original ? $0.original : nil } ?? original
                    previousDraft = (before, result)
                }
                draftText = result
                state.showDraftStatus("Формулировка обновлена.")
                focus = .add
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                state.showError(error.localizedDescription)
            }
        }
    }

    private func cancelPolish() {
        polishTask?.cancel()
        polishTask = nil
        polishBusy = false
    }

    private func closeKeySheet() {
        state.keySheetIntent = nil
        keyField = ""
        keyError = nil
    }

    private func saveKey() {
        do {
            try GroqKeyStore.save(keyField)
            let editingDraft = state.keySheetIntent == .polish
            closeKeySheet()
            if editingDraft {
                state.showDraftStatus("Ключ сохранён. Нажмите «Улучшить текст».")
            }
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try GroqKeyStore.delete()
            keyField = ""
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    // MARK: Status / errors

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = state.blockReason {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Файл данных не прочитан. Изменения отключены, чтобы его не перезаписать.")
                            .fontWeight(.semibold)
                        Text(reason).font(Theme.text).foregroundStyle(Theme.quiet).textSelection(.enabled)
                        Text("Переместите или восстановите файл и перезапустите приложение.")
                            .font(Theme.text).foregroundStyle(Theme.quiet)
                    }
                    Spacer()
                    Button("Показать в Finder") { state.revealDataFile() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
            }
            if let err = state.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(err).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("Скрыть") { state.errorMessage = nil }.buttonStyle(.borderless)
                }
                .font(Theme.text)
            } else if let status = state.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
                    Text(status).foregroundStyle(Theme.quiet)
                    if let u = state.undo {
                        Button(u.title) { state.performUndo() }
                            .buttonStyle(.link)
                    }
                    Spacer()
                }
                .font(Theme.text)
            }
        }
    }

    // MARK: Feed (ось времени)

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if state.isSearching {
                    let results = state.searchResults
                    caption("Найдено: \(results.count)")
                    if results.isEmpty {
                        emptyText("Ничего не найдено. Поиск идёт по тексту записей и по «На чём остановился».")
                    }
                    ForEach(results) { entry in
                        EntryRow(entry: entry, showDate: true,
                                 highlighted: entry.id == state.highlightedEntryID,
                                 onEdit: { editing = entry },
                                 onDelete: { pendingDelete = entry },
                                 onOpenDay: { state.go(to: entry.timestamp) })
                            .id("search-\(entry.id.uuidString)")
                    }
                } else {
                    let list = state.dayEntries
                    caption("По времени, сначала ранние")
                    if list.isEmpty {
                        emptyText(state.isTodaySelected
                                  ? "Пока пусто. Запишите, что уже сделано или произошло, — время поставится само."
                                  : "За этот день записей нет.")
                    }
                    ForEach(list) { entry in
                        EntryRow(entry: entry, showDate: false,
                                 highlighted: entry.id == state.highlightedEntryID,
                                 onEdit: { editing = entry },
                                 onDelete: { pendingDelete = entry },
                                 onOpenDay: nil)
                            .id("day-\(entry.id.uuidString)")
                    }
                }
            }
            // Отдельная идентичность поддерева для режима поиска и для ленты дня:
            // при переключении строки создаются заново, а не переиспользуются (дата, «К дню», порядок).
            .id(state.isSearching ? "feed-search" : "feed-day")
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s)
            .font(Theme.caption)
            .foregroundStyle(Theme.quiet)
            .padding(.leading, 6)
            .padding(.bottom, 6)
    }

    private func emptyText(_ s: String) -> some View {
        Text(s)
            .foregroundStyle(Theme.quiet)
            .padding(.leading, 6)
            .padding(.vertical, 16)
    }

}

// MARK: - Notes

extension Notification.Name {
    /// Отдельный сигнал нужен и при повторном вызове команды с уже пустым выбором.
    static let daylogNewNote = Notification.Name("Daylog.newNote")
}

struct NotesView: View {
    @EnvironmentObject var state: AppState
    @State private var newNoteToken = UUID()
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !state.noteSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var notes: [DiaryNote] {
        isSearching ? state.noteSearchResults : state.sortedNotes
    }

    private var selectedNote: DiaryNote? {
        state.sortedNotes.first { $0.id == state.selectedNoteID }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Заметки")
                    .font(Theme.groupTitle)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                searchField
                Button(action: newNote) {
                    Label("Новая заметка", systemImage: "plus")
                }
                .disabled(state.isBlocked)
                if notes.isEmpty {
                    Text(isSearching ? "Ничего не найдено." : "Идеи и мысли можно записать здесь — без привязки ко дню.")
                        .font(Theme.text)
                        .foregroundStyle(Theme.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                } else {
                    List(selection: $state.selectedNoteID) {
                        ForEach(notes) { note in
                            NoteRow(note: note)
                                .tag(note.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .padding(16)
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340, maxHeight: .infinity, alignment: .top)
            .background(Theme.pane)

            NoteEditor(state: state, note: selectedNote)
                .id(state.selectedNoteID?.uuidString ?? newNoteToken.uuidString)
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: state.focusToken) { _, _ in
            if state.focusRequest == .search { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .daylogNewNote)) { notification in
            guard let source = notification.object as? AppState, source === state else { return }
            newNote()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.quiet)
            TextField("Поиск по заметкам", text: $state.noteSearchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { state.noteSearchText = "" }
                .accessibilityLabel("Поиск по заметкам")
            if isSearching {
                Button { state.noteSearchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").compactHitArea(24)
                }
                .padding(.vertical, -5)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.quiet)
                .accessibilityLabel("Сбросить поиск")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(searchFocused ? Theme.accent : Theme.rail, lineWidth: searchFocused ? 1.5 : 1))
    }

    private func newNote() {
        state.selectedNoteID = nil
        state.noteSearchText = ""
        newNoteToken = UUID()
    }
}

struct NoteRow: View {
    let note: DiaryNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Без заголовка" : note.title)
                    .font(Theme.textStrong)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Закреплена")
                }
            }
            Text(note.body.components(separatedBy: .newlines).first ?? "")
                .font(Theme.text)
                .foregroundStyle(Theme.quiet)
                .lineLimit(1)
            Text(DiaryFormat.shortDate(note.updatedAt))
                .font(Theme.caption)
                .foregroundStyle(Theme.quiet)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct NoteEditor: View {
    @ObservedObject var state: AppState
    let note: DiaryNote?
    @State private var title: String
    @State private var text: String
    @State private var beforePolish: (title: String, body: String)?
    @State private var polishBusy = false
    @State private var polishTask: Task<Void, Never>?
    @State private var confirmDelete = false
    /// Заметка, в которую пишет этот редактор: id исходной или созданной первым сохранением/автосохранением.
    /// Не nil → повторный addNote невозможен (нет дублей).
    @State private var persistedID: UUID?
    /// Последнее записанное в хранилище состояние черновика. Автосохранение срабатывает, если
    /// title/text от него отличаются - любая правка после «Сохранить», включая отмену оформления.
    @State private var savedTitle: String
    @State private var savedText: String
    /// Режим только для показа: переключение ничего не сохраняет и не трогает черновик.
    @State private var mode: Mode = .editor
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, body }
    private enum Mode: Hashable { case editor, preview }

    init(state: AppState, note: DiaryNote?) {
        self.state = state
        self.note = note
        _title = State(initialValue: note?.title ?? "")
        _text = State(initialValue: note?.body ?? "")
        _persistedID = State(initialValue: note?.id)
        _savedTitle = State(initialValue: note?.title ?? "")
        _savedText = State(initialValue: note?.body ?? "")
    }


    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var polishDraft: String {
        [title, text].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Заголовок", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.display)
                .foregroundStyle(Theme.ink)
                .focused($focus, equals: .title)
                .accessibilityLabel("Заголовок заметки")
                .disabled(polishBusy || state.isBlocked)

            HStack(alignment: .center, spacing: 8) {
                Text("Текст заметки (Markdown)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.quiet)
                    .lineLimit(1)
                    .help(Text(verbatim: "Поддерживается Markdown: # заголовки, **жирный**, *курсив*, списки, - [ ] задачи, > цитаты, ``` код, ссылки."))
                Spacer(minLength: 8)
                Picker("Режим заметки", selection: $mode) {
                    Text("Редактор").tag(Mode.editor)
                    Text("Просмотр").tag(Mode.preview)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Режим заметки")
                .help("Редактор — исходный текст. Просмотр — оформленный вид без сохранения.")
            }
            // TextEditor не убирается из иерархии в режиме просмотра: так сохраняются текст,
            // выделение и прокрутка, и не срабатывает onDisappear/автосохранение.
            ZStack {
                TextEditor(text: $text)
                    .font(Theme.text)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(focus == .body ? Theme.accent : Theme.rail, lineWidth: focus == .body ? 1.5 : 1))
                    .focused($focus, equals: .body)
                    .accessibilityLabel("Текст заметки")
                    .disabled(polishBusy || state.isBlocked || mode != .editor)
                    .opacity(mode == .editor ? 1 : 0)
                    .allowsHitTesting(mode == .editor)
                    .accessibilityHidden(mode != .editor)
                if mode == .preview {
                    NoteMarkdownView(source: text)
                }
            }
            .onChange(of: mode) { _, newMode in
                if newMode == .preview {
                    if focus == .body { focus = nil }
                } else if !polishBusy && !state.isBlocked {
                    focus = .body
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { polishControls }
                VStack(alignment: .leading, spacing: 8) { polishControls }
            }
            HStack(spacing: 12) {
                if let note {
                    Button("Спросить") { state.askAboutNote(note.id) }
                        .help("Использовать эту заметку в чате")
                    Button(note.pinned ? "Открепить" : "Закрепить") {
                        state.setNotePinned(note, !note.pinned)
                    }
                    Button("Удалить", role: .destructive) { confirmDelete = true }
                }
                Spacer(minLength: 0)
                Button("Сохранить", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(isBlank)
            }
            .disabled(polishBusy || state.isBlocked)
        }
        .padding(24)
        .background(Theme.canvas)
        .onAppear { focus = .title }
        .onDisappear { polishTask?.cancel(); state.cancelNotePolish(); persistIfNeeded() }
        .sheet(item: Binding(get: { state.notePolishPreflight }, set: { if $0 == nil { state.cancelNotePolish() } })) { preflight in
            AIPreflightSheet(
                title: "Оформить заметку",
                explanation: "В Groq уйдут только заголовок и текст этого наброска, показанные ниже. Дневник, план и другие заметки не отправляются. Результат появится в редакторе и запишется только после «Сохранить». Условия обработки данных определяет Groq.",
                payload: preflight.draft,
                onCancel: state.cancelNotePolish,
                onSend: sendPolish)
        }
        .confirmationDialog("Удалить заметку?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive, action: delete)
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Сразу после удаления заметку можно вернуть.")
        }
    }

    @ViewBuilder
    private var polishControls: some View {
        HStack(spacing: 8) {
            Button("Оформить…", action: beginPolish)
                .disabled(polishDraft.isEmpty || polishBusy || state.isBlocked)
                .help("Сначала покажу, что уйдёт в Groq. Отправка только после «Отправить».")
                .accessibilityHint("Откроет проверку текста перед отправкой в Groq")
            if polishBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Оформляю заметку")
            }
        }
        if beforePolish != nil {
            Button("Отменить оформление") {
                guard let previous = beforePolish else { return }
                title = previous.title
                text = previous.body
                beforePolish = nil
            }
            .disabled(polishBusy || state.isBlocked)
        }
    }

    /// Шаг 1: только показать набросок и получателя. Сети нет.
    private func beginPolish() {
        guard !polishBusy, !state.isBlocked, !polishDraft.isEmpty else { return }
        state.beginNotePolish(draft: polishDraft)
    }

    /// Шаг 2, после «Отправить»: уходит показанный текст, заметка не сохраняется сама.
    private func sendPolish() {
        guard !polishBusy, state.notePolishPreflight != nil else { return }
        let previous = (title: title, body: text)
        polishBusy = true
        polishTask = Task {
            let result = await state.confirmNotePolish()
            guard !Task.isCancelled else {
                // Поздний результат отбрасываем, но не оставляем кнопки навсегда занятыми.
                polishBusy = false
                polishTask = nil
                return
            }
            polishBusy = false
            polishTask = nil
            if let result {
                if beforePolish == nil { beforePolish = previous }
                title = result.title
                text = result.body
                focus = .body
                state.showDraftStatus("Заметка оформлена. Нажмите «Сохранить», чтобы записать изменения.")
            }
        }
    }

    private func save() {
        guard !isBlank, !polishBusy, !state.isBlocked else { return }
        let wasNew = persistedID == nil
        guard write(title: title, body: text) else { return }
        beforePolish = nil
        if wasNew, let id = persistedID { state.selectedNoteID = id }
    }

    /// Пишет текущий черновик: update, если заметка уже есть (исходная или созданная этим редактором),
    /// иначе add ровно один раз. При успехе запоминает записанное состояние как базу.
    @discardableResult
    private func write(title draftTitle: String, body draftText: String) -> Bool {
        let ok: Bool
        if let id = persistedID {
            ok = state.updateNote(id: id, title: draftTitle, body: draftText)
        } else {
            let previousIDs = Set(state.sortedNotes.map(\.id))
            ok = state.addNote(title: draftTitle, body: draftText)
            if ok { persistedID = state.sortedNotes.first { !previousIDs.contains($0.id) }?.id }
        }
        if ok {
            savedTitle = draftTitle
            savedText = draftText
        }
        return ok
    }

    /// Автосохранение при уходе из редактора (смена заметки/раздела), чтобы правки не терялись,
    /// в том числе сделанные после явного «Сохранить». Без изменений относительно базы — ничего не пишем.
    /// Переключение «Редактор/Просмотр» сюда не ведёт: редактор не исчезает.
    private func persistIfNeeded() {
        // До явного сохранения предложенного текста сохраняем только исходные ручные правки.
        let draft = beforePolish ?? (title: title, body: text)
        guard !state.isBlocked, draft.title != savedTitle || draft.body != savedText,
              !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        write(title: draft.title, body: draft.body)
    }

    private func delete() {
        guard let note, !polishBusy, !state.isBlocked else { return }
        state.deleteNote(note)
        if !state.sortedNotes.contains(where: { $0.id == note.id }) {
            state.selectedNoteID = nil
        }
    }
}

// MARK: - Notes chat

extension Notification.Name {
    static let daylogAskFocus = Notification.Name("Daylog.askFocus")
}

struct AskView: View {
    @EnvironmentObject var state: AppState
    @State private var showNoteList = false
    @State private var noteSearch = ""
    @State private var answerToSave: ChatMessage?
    @FocusState private var inputFocused: Bool

    private var canSubmit: Bool {
        state.canSendChat && !state.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Спросить").font(Theme.groupTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Новый чат", systemImage: "square.and.pencil") {
                    state.clearChat()
                    inputFocused = true
                }
                .disabled(state.chatMessages.isEmpty && !state.chatBusy && state.chatDraft.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            transcript
            Divider()
            composer
        }
        .onReceive(NotificationCenter.default.publisher(for: .daylogAskFocus)) { notification in
            guard let source = notification.object as? AppState, source === state else { return }
            inputFocused = true
        }
        .sheet(isPresented: Binding(get: { state.chatPreflight != nil }, set: { if !$0 { state.cancelChatPreflight() } })) {
            if let preview = state.chatPreflight {
                AIPreflightSheet(
                    title: "Перед отправкой",
                    explanation: preview.searchWeb
                        ? "Groq получит этот текст и сможет использовать его для поиска в интернете."
                        : "Groq получит показанные фрагменты, последние реплики и новый вопрос.",
                    payload: preview.payload,
                    onCancel: state.cancelChatPreflight,
                    onSend: { if state.confirmChat() { inputFocused = true } })
            }
        }
        .sheet(item: $answerToSave) { message in
            ChatNoteSheet(answer: message.text) { title, body in
                state.addNote(title: title, body: body)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if state.chatMessages.isEmpty && !state.chatBusy {
                        VStack(spacing: 8) {
                            Text("О чём поговорим?").font(Theme.groupTitle).foregroundStyle(Theme.ink)
                            Text("Спросите о своих заметках, продолжите мысль или включите «Интернет» для поиска свежих сведений.")
                                .font(Theme.text)
                                .foregroundStyle(Theme.quiet)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 440)
                        .padding(.top, 64)
                    }
                    ForEach(state.chatMessages) { message in
                        ChatBubble(message: message) { answerToSave = message }
                    }
                    if let pending = state.chatPendingQuestion {
                        ChatBubble(message: pending) {}
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(state.chatSearchWeb ? "Ищу в интернете и готовлю ответ…" : "Готовлю ответ…")
                                .font(Theme.caption).foregroundStyle(Theme.quiet)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: state.chatMessages.count) { _, _ in
                withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: state.chatPendingQuestion?.id) { _, _ in
                withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onAppear {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
                inputFocused = true
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("Заметки", selection: $state.chatNoteScope) {
                    ForEach(ChatNoteScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .fixedSize()
                .help("Выберите, какие заметки использовать для следующего вопроса")
                if state.chatNoteScope == .selected {
                    Button("Выбрано \(state.chatSelectedNoteIDs.count)") { showNoteList.toggle() }
                        .popover(isPresented: $showNoteList) { noteChecklist }
                }
                Toggle("Интернет", isOn: $state.chatSearchWeb)
                    .toggleStyle(QuietCheckboxStyle())
                    .help("Искать свежие сведения через Groq")
                Spacer()
                Button("Предпросмотр") { state.prepareChat(state.chatDraft) }
                    .disabled(!canSubmit)
                    .help("Посмотреть заметки и реплики, которые получит Groq")
            }
            .disabled(state.chatBusy || state.isBlocked)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Напишите сообщение", text: $state.chatDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(Theme.input)
                    .foregroundStyle(Theme.ink)
                    .focused($inputFocused)
                    .disabled(state.chatBusy || state.isBlocked)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(inputFocused ? Theme.accent : Theme.rail, lineWidth: inputFocused ? 1.5 : 1))
                if state.chatBusy {
                    Button("Остановить") {
                        state.cancelChatRequest()
                        inputFocused = true
                    }
                } else {
                    Button("Отправить", systemImage: "arrow.up", action: submit)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(!canSubmit)
                        .help("Отправить вопрос в Groq (⌘↩)")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.pane)
    }

    private func submit() {
        if state.sendChat() { inputFocused = true }
    }

    private var noteChecklist: some View {
        let query = noteSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = query.isEmpty ? state.sortedNotes : state.store.searchNotes(query)
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Найти заметку", text: $noteSearch)
                .textFieldStyle(.roundedBorder)
            if notes.isEmpty {
                Text("Заметок не найдено").foregroundStyle(Theme.quiet)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(notes) { note in
                            Toggle(note.title.isEmpty ? "Без заголовка" : note.title, isOn: Binding(
                                get: { state.chatSelectedNoteIDs.contains(note.id) },
                                set: { selected in
                                    if selected { state.chatSelectedNoteIDs.insert(note.id) }
                                    else { state.chatSelectedNoteIDs.remove(note.id) }
                                }))
                            .toggleStyle(QuietCheckboxStyle())
                            .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Button("Снять отметки") { state.chatSelectedNoteIDs = [] }
                    .disabled(state.chatSelectedNoteIDs.isEmpty)
                Spacer()
                Button("Готово") { showNoteList = false }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct ChatBubble: View {
    @EnvironmentObject var state: AppState
    let message: ChatMessage
    let onSave: () -> Void

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .foregroundStyle(message.role == .user ? Theme.canvas : Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if message.role == .assistant {
                    sources
                    Button("Сохранить в заметки…", systemImage: "note.text.badge.plus", action: onSave)
                        .font(Theme.caption)
                        .buttonStyle(.borderless)
                        .disabled(state.isBlocked)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(message.role == .user ? Theme.accent : Theme.field))
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sources: some View {
        let notes = message.sourceNoteIDs.compactMap { id in state.notes.first { $0.id == id } }
        if !notes.isEmpty {
            Text("Из заметок").font(Theme.caption).foregroundStyle(Theme.quiet)
            ForEach(notes) { note in
                Button { state.openSource(note.id) } label: {
                    Label(note.title.isEmpty ? "Без заголовка" : note.title, systemImage: "note.text")
                        .lineLimit(1)
                }
                .font(Theme.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
        }
        if !message.webSources.isEmpty {
            Text("Из интернета").font(Theme.caption).foregroundStyle(Theme.quiet)
            ForEach(message.webSources) { source in
                Link(destination: source.url) {
                    Label(source.title, systemImage: "arrow.up.right").lineLimit(1)
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.accent)
                .help(source.url.absoluteString)
            }
        } else if message.searchedWeb {
            Text("Groq не вернул ссылки на веб-источники.")
                .font(Theme.caption).foregroundStyle(Theme.quiet)
        }
    }
}

private struct ChatNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText: String
    let save: (String, String) -> Bool

    init(answer: String, save: @escaping (String, String) -> Bool) {
        _bodyText = State(initialValue: answer)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сохранить ответ в заметки").font(Theme.groupTitle)
            TextField("Заголовок", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText)
                .font(Theme.text)
                .frame(minHeight: 180)
                .accessibilityLabel("Текст новой заметки")
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { if save(title, bodyText) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Entry row

struct EntryRow: View {
    let entry: DiaryEntry
    let showDate: Bool
    let highlighted: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenDay: (() -> Void)?
    @State private var hovering = false

    private var timeWidth: CGFloat { showDate ? 92 : 52 }
    private let markerWidth: CGFloat = 28
    private let inset: CGFloat = 6

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(DiaryFormat.time(entry.timestamp))
                    .font(Theme.timeFont)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("в \(DiaryFormat.time(entry.timestamp))")
                if showDate {
                    Text(DiaryFormat.shortDate(entry.timestamp))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.quiet)
                }
            }
            .frame(width: timeWidth, alignment: .trailing)

            marker
                .frame(width: markerWidth)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(Theme.fact)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let c = entry.context {
                    Text("На чём остановился: \(c)")
                        .font(Theme.fact)
                        .foregroundStyle(Theme.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let open = onOpenDay {
                    Button("К дню", action: open).help("Открыть этот день")
                }
                Button(action: onEdit) { Image(systemName: "pencil").compactHitArea() }
                    .help("Изменить")
                    .accessibilityLabel("Изменить запись")
                Button(action: onDelete) { Image(systemName: "trash").compactHitArea() }
                    .help("Удалить…")
                    .accessibilityLabel("Удалить запись")
            }
            .padding(.vertical, -6)
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.quiet)
            // 0.8: не ниже 3:1 (WCAG 1.4.11) на холсте в обеих темах.
            .opacity(hovering ? 1 : 0.8)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, inset)
        // Непрерывная ось: отрезок линии в каждой строке, строки стоят вплотную.
        .background(alignment: .leading) {
            Rectangle()
                .fill(Theme.rail)
                .frame(width: 1)
                .padding(.leading, inset + timeWidth + markerWidth / 2 - 0.5)
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(highlighted ? Theme.accent.opacity(0.10) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Изменить…", action: onEdit)
            if let open = onOpenDay { Button("Открыть день", action: open) }
            Divider()
            Button("Удалить…", role: .destructive, action: onDelete)
        }
    }

    private var marker: some View {
        Group {
            if entry.planID != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
            }
        }
        .foregroundStyle(Theme.accent)
        .padding(3)
        .background(Circle().fill(Theme.canvas))
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
        .help(entry.planID != nil ? "Из задачи" : "")
        .accessibilityLabel("Из задачи")
        .accessibilityHidden(entry.planID == nil)
    }
}

// MARK: - Editor sheets

struct EntryEditor: View {
    @ObservedObject var state: AppState
    let entry: DiaryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var context: String
    @State private var timestamp: Date
    @State private var error: String?

    init(state: AppState, entry: DiaryEntry) {
        self.state = state
        self.entry = entry
        _text = State(initialValue: entry.text)
        _context = State(initialValue: entry.context ?? "")
        _timestamp = State(initialValue: entry.timestamp)
    }

    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Изменить запись").font(Theme.textStrong)
            Form {
                TextField("Что сделано:", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                DatePicker("Дата и время:", selection: $timestamp)
                TextField("На чём остановился:", text: $context, axis: .vertical)
                    .lineLimit(1...6)
            }
            if entry.planID != nil {
                Text("Запись создана выполнением задачи. Изменения останутся в дневнике, даже если вернуть задачу в работу.")
                    .font(Theme.text)
                    .foregroundStyle(Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(Theme.text)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBlank)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func save() {
        if state.update(id: entry.id, text: text, context: context, timestamp: timestamp) {
            dismiss()
        } else {
            error = state.errorMessage
        }
    }
}

/// Проверка перед отправкой в ИИ: фактический текст, получатель, «Отправить» и «Отмена».
/// До «Отправить» запросов нет; «Отмена» ничего не меняет.
struct AIPreflightSheet: View {
    let title: String
    let explanation: String
    let payload: String
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Theme.title)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Получатель: Groq")
                .font(Theme.textStrong)
                .foregroundStyle(Theme.ink)
            Text(explanation)
                .font(Theme.text)
                .foregroundStyle(Theme.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Text("Будет отправлено (\(payload.count) знаков):")
                .font(Theme.caption)
                .foregroundStyle(Theme.quiet)
            ScrollView {
                Text(payload)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 80, maxHeight: 280)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rail))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Текст для отправки")
            .accessibilityValue(payload)
            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Отправить", action: onSend)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Отправить показанный текст в Groq")
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct DaySummarySheet: View {
    let summary: String?
    let busy: Bool
    let day: Date
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Итог за \(DiaryFormat.shortDate(day))")
                .font(Theme.title)
                .foregroundStyle(Theme.ink)
            if busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Подвожу итог дня…").foregroundStyle(Theme.quiet)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .accessibilityLabel("Подвожу итог дня")
            } else if let summary {
                Text(summary)
                    .font(Theme.text)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rail))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Итог не записывается в дневник. Условия обработки данных определяет Groq.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if let summary, !busy {
                    Button("Скопировать") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                }
                Button("Закрыть", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(busy)
    }
}

private struct APIKeySheet: View {
    @Binding var key: String
    let error: String?
    let hasSavedKey: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ключ Groq")
                .font(Theme.title)
                .foregroundStyle(Theme.ink)
            Text("Ключ хранится в Связке ключей этого Mac и не записывается в файл дневника. Если в Связке ключей его нет, приложение берёт GROQ_API_KEY из окружения запуска.")
                .font(Theme.text)
                .foregroundStyle(Theme.quiet)
                .fixedSize(horizontal: false, vertical: true)
            if hasSavedKey {
                Text("Ключ уже сохранён. Новый заменит его.")
                    .font(Theme.text)
                    .foregroundStyle(Theme.quiet)
            }
            SecureField("Ключ Groq", text: $key)
                .textFieldStyle(.roundedBorder)
            Text("Для бесплатного использования возьмите ключ из аккаунта Groq на тарифе Free. Модель: GPT-OSS 20B. Квоту и оплату определяет тариф вашего аккаунта.")
                .font(Theme.caption)
                .foregroundStyle(Theme.quiet)
            Link("Создать ключ в Groq Console", destination: URL(string: "https://console.groq.com/keys")!)
            if let error {
                Text(error).font(Theme.text).foregroundStyle(.red)
            }
            HStack {
                if hasSavedKey {
                    Button("Удалить ключ", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

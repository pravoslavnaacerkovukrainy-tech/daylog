import SwiftUI
import AppKit

// MARK: - Theme (токены — см. DESIGN.md)

enum Theme {
    /// Лист ленты дня.
    static let canvas = Color(nsColor: .textBackgroundColor)
    /// Панель плана и хром.
    static let pane = Color(nsColor: .windowBackgroundColor)
    static let ink = dynamic(0x263747, dark: .labelColor)
    static let quiet = dynamic(0x657586, dark: .secondaryLabelColor)
    static let accent = dynamic(0x2F6690, dark: NSColor(srgbRed: 0.525, green: 0.714, blue: 0.878, alpha: 1))
    static let rail = dynamic(0xDCE5EC, dark: .separatorColor)
    static let field = dynamic(0xF5F8FA, dark: .controlBackgroundColor)

    static func dynamic(_ hex: UInt32, dark: NSColor) -> Color {
        let light = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                            green: CGFloat((hex >> 8) & 0xFF) / 255,
                            blue: CGFloat(hex & 0xFF) / 255,
                            alpha: 1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Время — главный визуальный ориентир: SF Rounded, полужирный, цифры одной ширины.
    static let timeFont = Font.system(.body, design: .rounded).weight(.semibold).monospacedDigit()
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focus: FocusTarget?
    @Environment(\.openWindow) private var openWindow

    @State private var draftText = ""
    @State private var draftContext = ""
    @State private var showContext = false
    @State private var customTime = false
    @State private var draftTime = Date()
    @State private var editing: DiaryEntry?
    @State private var pendingDelete: DiaryEntry?

    @State private var planDraft = ""
    @State private var editingPlan: DayPlan?
    @State private var pendingPlanDelete: DayPlan?
    @State private var pendingReopen: DayPlan?
    @State private var polishPreview: String?
    @State private var polishBusy = false
    @State private var polishTask: Task<Void, Never>?
    @State private var keyField = ""
    @State private var keyError: String?

    private var draftIsBlank: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if state.mode == .day {
                HStack(spacing: 0) {
                    mainColumn
                        .frame(minWidth: 440, maxWidth: .infinity)
                    if state.showPlan {
                        Divider()
                        planPane
                            .frame(width: 280)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    NotesView()
                    statusArea
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }
                .background(Theme.canvas)
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
            state.mode = .day
            focus = state.focusRequest
        }
        .onChange(of: customTime) { _, on in
            if on { draftTime = defaultCustomTime() }
        }
        .onChange(of: state.polishRequestToken) { _, _ in
            beginPolish()
        }
        .sheet(isPresented: Binding(get: { polishPreview != nil }, set: { if !$0 { cancelPolish() } })) {
            if let text = polishPreview {
                PolishConfirmSheet(draft: text, busy: polishBusy, onCancel: cancelPolish, onSend: sendPolish)
            }
        }
        .sheet(isPresented: Binding(get: { state.keySheetIntent != nil }, set: { if !$0 { closeKeySheet() } })) {
            APIKeySheet(
                key: $keyField,
                error: keyError,
                hasSavedKey: XAIKeyStore.load() != nil,
                onCancel: closeKeySheet,
                onSave: saveKey,
                onDelete: deleteKey
            )
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Режим", selection: $state.mode) {
                Text("День").tag(AppMode.day)
                Text("Заметки").tag(AppMode.notes)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
        }
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
                DatePicker("День", selection: Binding(get: { state.selectedDay }, set: { state.go(to: $0) }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .help("Выбрать день")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { state.showPlan.toggle() } label: {
                    Label(state.showPlan ? String("Скрыть план") : String("Показать план"), systemImage: "sidebar.right")
                }
                .help("План на день (⌥⌘P)")
            }
        }
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            dayHeader
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 14)
            composer
                .padding(.horizontal, 28)
            statusArea
                .padding(.horizontal, 28)
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
        if entry.planID != nil { s += " Пункт плана останется отмеченным выполненным." }
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
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(state.isSearching ? "По всем дням, сначала новые" : state.daySubtitle)
                .font(.title3)
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
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.quiet)
                .help("Сбросить поиск (Esc)")
                .accessibilityLabel("Сбросить поиск")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(focus == .search ? Theme.accent : Theme.rail, lineWidth: focus == .search ? 1.5 : 1))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Что сделано или произошло?", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(Theme.ink)
                    .focused($focus, equals: .add)
                    .onSubmit(submit)
                    .accessibilityLabel("Новая запись в дневник")
                if !draftIsBlank || polishBusy {
                    Button(polishBusy ? "Причёсываю…" : "Причесать", action: beginPolish)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                        .disabled(draftIsBlank || state.isBlocked || polishBusy)
                        .fixedSize()
                        .help("Сделать одну короткую фразу. В дневник не записывает (⌥⌘↩)")
                        .accessibilityLabel("Причесать черновик")
                }
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
            .font(.callout)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focus == .add ? Theme.accent : Theme.rail, lineWidth: focus == .add ? 1.5 : 1))
        .disabled(state.isBlocked)
    }

    private var timeToggle: some View {
        Toggle("Другое время", isOn: $customTime)
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("Без отметки время записи ставится автоматически")
    }

    private var contextToggle: some View {
        Toggle("На чём остановился", isOn: $showContext)
            .toggleStyle(.checkbox)
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
            draftContext = ""
            showContext = false
            customTime = false
            focus = .add
        }
    }

    private func beginPolish() {
        let text = DraftPolish.normalizeInput(draftText)
        guard !text.isEmpty, !state.isBlocked, !polishBusy else { return }
        if XAIKeyStore.resolve() == nil {
            keyField = ""
            keyError = nil
            state.keySheetIntent = .polish
            return
        }
        polishPreview = text
    }

    private func sendPolish() {
        guard let text = polishPreview, !polishBusy else { return }
        guard let key = XAIKeyStore.resolve() else {
            polishPreview = nil
            state.keySheetIntent = .polish
            return
        }
        polishBusy = true
        polishTask = Task {
            do {
                let result = try await DraftPolishClient().polish(draft: text, apiKey: key)
                guard !Task.isCancelled else { return }
                draftText = result
                polishPreview = nil
                polishBusy = false
                state.showDraftStatus("Черновик причёсан. В дневник попадёт после «Записать».")
                focus = .add
            } catch is CancellationError {
                polishBusy = false
            } catch {
                guard !Task.isCancelled else { return }
                polishBusy = false
                polishPreview = nil
                state.showError(error.localizedDescription)
            }
        }
    }

    private func cancelPolish() {
        polishTask?.cancel()
        polishTask = nil
        polishBusy = false
        polishPreview = nil
    }

    private func closeKeySheet() {
        state.keySheetIntent = nil
        keyField = ""
        keyError = nil
    }

    private func saveKey() {
        do {
            try XAIKeyStore.save(keyField)
            let continuePolish = state.keySheetIntent == .polish
            closeKeySheet()
            if continuePolish {
                DispatchQueue.main.async { beginPolish() }
            }
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try XAIKeyStore.delete()
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
                        Text(reason).font(.callout).foregroundStyle(Theme.quiet).textSelection(.enabled)
                        Text("Переместите или восстановите файл и перезапустите приложение.")
                            .font(.callout).foregroundStyle(Theme.quiet)
                    }
                    Spacer()
                    Button("Показать в Finder") { state.revealDataFile() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
            }
            if let err = state.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(err).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("Скрыть") { state.errorMessage = nil }.buttonStyle(.borderless)
                }
                .font(.callout)
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
                .font(.callout)
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
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s)
            .font(.caption)
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

    // MARK: Plan pane

    private var planPane: some View {
        let list = state.dayPlans
        let open = list.filter { !$0.isCompleted }
        let done = list.filter { $0.isCompleted }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("План на день")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(DiaryFormat.capitalizedFirst(DiaryFormat.dayMonth(state.selectedDay)))
                    .font(.callout)
                    .foregroundStyle(Theme.quiet)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 6) {
                Image(systemName: "plus").foregroundStyle(Theme.quiet)
                TextField("Добавить в план", text: $planDraft)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .plan)
                    .onSubmit(submitPlan)
                    .accessibilityLabel("Новый пункт плана")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focus == .plan ? Theme.accent : Theme.rail, lineWidth: focus == .plan ? 1.5 : 1))
            .disabled(state.isBlocked)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if list.isEmpty {
                        Text("Пара дел на этот день — без сроков и напоминаний. Отмеченное сразу попадёт в дневник.")
                            .font(.callout)
                            .foregroundStyle(Theme.quiet)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(open) { plan in
                        planRow(plan)
                            .id("plan-open-\(plan.id.uuidString)")
                    }
                    if !done.isEmpty {
                        Text("Сделано")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.quiet)
                            .padding(.top, open.isEmpty ? 0 : 12)
                            .padding(.bottom, 2)
                        ForEach(done) { plan in
                            planRow(plan)
                                .id("plan-done-\(plan.id.uuidString)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("Вернуть пункт в план?",
                                isPresented: Binding(get: { pendingReopen != nil },
                                                     set: { if !$0 { pendingReopen = nil } }),
                                presenting: pendingReopen) { plan in
                Button(reopenButtonTitle(plan)) {
                    state.reopenPlan(plan)
                    pendingReopen = nil
                }
                Button("Отмена", role: .cancel) { pendingReopen = nil }
            } message: { plan in
                Text(reopenMessage(plan))
            }

            if !open.isEmpty {
                Text("Отметка добавляет запись в дневник с текущим временем.")
                    .font(.caption)
                    .foregroundStyle(Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.pane)
        .sheet(item: $editingPlan) { plan in
            PlanEditor(state: state, plan: plan)
        }
        .confirmationDialog("Удалить пункт плана?",
                            isPresented: Binding(get: { pendingPlanDelete != nil },
                                                 set: { if !$0 { pendingPlanDelete = nil } }),
                            presenting: pendingPlanDelete) { plan in
            Button("Удалить", role: .destructive) {
                state.deletePlan(plan)
                pendingPlanDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingPlanDelete = nil }
        } message: { plan in
            Text(planDeleteMessage(plan))
        }
    }

    private func reopenButtonTitle(_ plan: DayPlan) -> String {
        state.reopenWillRemoveEntry(plan) ? "Вернуть и убрать запись" : "Вернуть в план"
    }

    private func reopenMessage(_ plan: DayPlan) -> String {
        if state.reopenWillRemoveEntry(plan) {
            return "Запись «\(plan.text)», созданная отметкой, будет убрана из дневника."
        }
        return "Запись в дневнике меняли или удалили — её не тронем, снимется только отметка."
    }

    private func planDeleteMessage(_ plan: DayPlan) -> String {
        if plan.isCompleted {
            return "«\(plan.text)». Запись в дневнике останется. Сразу после удаления пункт можно вернуть."
        }
        return "«\(plan.text)». Сразу после удаления пункт можно вернуть."
    }

    private func planRow(_ plan: DayPlan) -> some View {
        let linked = state.linkedEntry(for: plan)
        var showEntry: (() -> Void)? = nil
        if let entry = linked {
            showEntry = {
                state.go(to: entry.timestamp)
                state.highlightedEntryID = entry.id
            }
        }
        return PlanRow(
            plan: plan,
            entryTime: linked.map { DiaryFormat.time($0.timestamp) },
            onToggle: {
                if plan.isCompleted { pendingReopen = plan } else { state.completePlan(plan) }
            },
            onEdit: { editingPlan = plan },
            onMoveNext: { state.movePlanToNextDay(plan) },
            onDelete: { pendingPlanDelete = plan },
            onShowEntry: showEntry
        )
    }

    private func submitPlan() {
        let t = planDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !state.isBlocked else { return }
        if state.addPlan(text: t) {
            planDraft = ""
            focus = .plan
        }
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
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                searchField
                Button(action: newNote) {
                    Label("Новая заметка", systemImage: "plus")
                }
                .disabled(state.isBlocked)
                if notes.isEmpty {
                    Text(isSearching ? "Ничего не найдено." : "Идеи и мысли можно записать здесь — без привязки ко дню.")
                        .font(.callout)
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
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.quiet)
                .accessibilityLabel("Сбросить поиск")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Закреплена")
                }
            }
            Text(note.body.components(separatedBy: .newlines).first ?? "")
                .font(.callout)
                .foregroundStyle(Theme.quiet)
                .lineLimit(1)
            Text(DiaryFormat.shortDate(note.updatedAt))
                .font(.caption)
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
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, body }

    init(state: AppState, note: DiaryNote?) {
        self.state = state
        self.note = note
        _title = State(initialValue: note?.title ?? "")
        _text = State(initialValue: note?.body ?? "")
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
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.ink)
                .focused($focus, equals: .title)
                .accessibilityLabel("Заголовок заметки")
                .disabled(polishBusy || state.isBlocked)

            Text("Текст заметки")
                .font(.caption)
                .foregroundStyle(Theme.quiet)
            TextEditor(text: $text)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focus == .body ? Theme.accent : Theme.rail, lineWidth: focus == .body ? 1.5 : 1))
                .focused($focus, equals: .body)
                .accessibilityLabel("Текст заметки")
                .disabled(polishBusy || state.isBlocked)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { polishControls }
                VStack(alignment: .leading, spacing: 8) { polishControls }
            }
            HStack(spacing: 12) {
                if let note {
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
        .onDisappear { polishTask?.cancel() }
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
            Button("Оформить", action: beginPolish)
                .disabled(polishDraft.isEmpty || polishBusy || state.isBlocked)
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

    private func beginPolish() {
        guard !polishBusy, !state.isBlocked, !polishDraft.isEmpty else { return }
        let previous = (title: title, body: text)
        let draft = polishDraft
        polishBusy = true
        polishTask = Task {
            let result = await state.polishNote(draft: draft)
            guard !Task.isCancelled else { return }
            polishBusy = false
            polishTask = nil
            if let result {
                beforePolish = previous
                title = result.title
                text = result.body
                focus = .body
                state.showDraftStatus("Заметка оформлена. Нажмите «Сохранить», чтобы записать изменения.")
            }
        }
    }

    private func save() {
        guard !isBlank, !polishBusy, !state.isBlocked else { return }
        if let note {
            _ = state.updateNote(id: note.id, title: title, body: text)
        } else {
            let previousIDs = Set(state.sortedNotes.map(\.id))
            if state.addNote(title: title, body: text) {
                state.selectedNoteID = state.sortedNotes.first { !previousIDs.contains($0.id) }?.id
            }
        }
    }

    private func delete() {
        guard let note, !polishBusy, !state.isBlocked else { return }
        state.deleteNote(note)
        if !state.sortedNotes.contains(where: { $0.id == note.id }) {
            state.selectedNoteID = nil
        }
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
                        .font(.caption)
                        .foregroundStyle(Theme.quiet)
                }
            }
            .frame(width: timeWidth, alignment: .trailing)

            marker
                .frame(width: markerWidth)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let c = entry.context {
                    Text("На чём остановился: \(c)")
                        .font(.callout)
                        .foregroundStyle(Theme.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.planID != nil {
                    Text("Из плана")
                        .font(.caption)
                        .foregroundStyle(Theme.quiet)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if let open = onOpenDay {
                    Button("К дню", action: open).help("Открыть этот день")
                }
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("Изменить")
                    .accessibilityLabel("Изменить запись")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .help("Удалить…")
                    .accessibilityLabel("Удалить запись")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.quiet)
            .opacity(hovering ? 1 : 0.35)
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
        .accessibilityHidden(true)
    }
}

// MARK: - Plan row

struct PlanRow: View {
    let plan: DayPlan
    let entryTime: String?
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onMoveNext: () -> Void
    let onDelete: () -> Void
    let onShowEntry: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: plan.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(plan.isCompleted ? Theme.accent : Theme.quiet)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            .help(toggleHelp)
            .accessibilityLabel(toggleAccessibilityLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(plan.text)
                    .foregroundStyle(plan.isCompleted ? Theme.quiet : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if plan.isCompleted {
                    if let t = entryTime, let show = onShowEntry {
                        Button("Записано в дневник в \(t)", action: show)
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Показать запись в ленте")
                    } else if let doneAt = plan.completedAt {
                        Text("Выполнено в \(DiaryFormat.time(doneAt)), запись удалена")
                            .font(.caption)
                            .foregroundStyle(Theme.quiet)
                    }
                }
            }
            Spacer(minLength: 4)
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.35)
            .accessibilityLabel("Действия с пунктом плана")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !plan.isCompleted { onEdit() } }
        .contextMenu { menuItems }
    }

    private var toggleHelp: String {
        plan.isCompleted ? "Вернуть в план…" : "Отметить выполненным — запись появится в дневнике"
    }

    private var toggleAccessibilityLabel: String {
        plan.isCompleted ? "Вернуть в план: \(plan.text)" : "Отметить выполненным: \(plan.text)"
    }

    @ViewBuilder
    private var menuItems: some View {
        if plan.isCompleted {
            Button("Вернуть в план…", action: onToggle)
        } else {
            Button("Отметить выполненным", action: onToggle)
            Button("Изменить…", action: onEdit)
            Button("Перенести на следующий день", action: onMoveNext)
        }
        Divider()
        Button("Удалить…", role: .destructive, action: onDelete)
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
            Text("Изменить запись").font(.headline)
            Form {
                TextField("Что сделано:", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                DatePicker("Дата и время:", selection: $timestamp)
                TextField("На чём остановился:", text: $context, axis: .vertical)
                    .lineLimit(1...6)
            }
            if entry.planID != nil {
                Text("Запись создана отметкой плана. Изменения останутся в дневнике, даже если вернуть пункт в план.")
                    .font(.callout)
                    .foregroundStyle(Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
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
        .padding(20)
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

struct PlanEditor: View {
    @ObservedObject var state: AppState
    let plan: DayPlan
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var day: Date
    @State private var error: String?

    init(state: AppState, plan: DayPlan) {
        self.state = state
        self.plan = plan
        _text = State(initialValue: plan.text)
        _day = State(initialValue: DiaryDay.date(plan.day) ?? Date())
    }

    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Изменить пункт плана").font(.headline)
            Form {
                TextField("Что сделать:", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                DatePicker("День:", selection: $day, displayedComponents: .date)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
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
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        if state.updatePlan(id: plan.id, text: text, day: day) {
            dismiss()
        } else {
            error = state.errorMessage
        }
    }
}

private struct PolishConfirmSheet: View {
    let draft: String
    let busy: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Причесать черновик")
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
            Text("В xAI уйдёт только этот текст. Записи дневника и план не отправляются. На сервере xAI запрос не сохраняется. В дневник ничего не попадёт, пока вы не нажмёте «Записать».")
                .font(.callout)
                .foregroundStyle(Theme.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Text(draft)
                .font(.title3)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.rail))
            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(busy ? "Отправляю…" : "Отправить", action: onSend)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
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
            Text("Ключ xAI")
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
            Text("Ключ хранится в Связке ключей этого Mac и не записывается в файл дневника. Если в Связке ключей его нет, приложение берёт XAI_API_KEY из окружения запуска.")
                .font(.callout)
                .foregroundStyle(Theme.quiet)
                .fixedSize(horizontal: false, vertical: true)
            if hasSavedKey {
                Text("Ключ уже сохранён. Новый заменит его.")
                    .font(.callout)
                    .foregroundStyle(Theme.quiet)
            }
            SecureField("Ключ xAI", text: $key)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
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
        .padding(20)
        .frame(width: 460)
    }
}

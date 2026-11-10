import SwiftUI

private enum OrganizerSection: String, CaseIterable, Identifiable {
    case today = "Сегодня", inbox = "Место хаоса", projects = "Проекты"
    case waiting = "Ожидаю", review = "Обзор", all = "Все задачи"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .inbox: return "tray"
        case .projects: return "folder"
        case .waiting: return "hourglass"
        case .review: return "arrow.triangle.2.circlepath"
        case .all: return "checklist"
        }
    }
}

private enum OrganizerArea: String, CaseIterable, Identifiable {
    case all = "Все", work = "Работа", personal = "Личное"
    var id: String { rawValue }
    func includes(_ area: TaskArea) -> Bool {
        self == .all || (self == .work && area == .work) || (self == .personal && area == .personal)
    }
    var defaultArea: TaskArea { self == .work ? .work : .personal }
}

private extension View {
    /// Цвет `signal` только у включённой отметки; без неё вид остаётся системным.
    @ViewBuilder func signalForeground(_ on: Bool) -> some View {
        if on { foregroundStyle(Theme.signal) } else { self }
    }
}

private struct TaskSheet: Identifiable {
    let id = UUID()
    var task: DayPlan?
    var projectID: UUID?
    var area: TaskArea
    var status: TaskStatus
    var plannedDay: Date?
    /// Строка места хаоса: уходит из корзины только вместе с успешным сохранением задачи.
    var chaosItem: ChaosItem?
    var atRisk: Bool = false
}

private struct ProjectSheet: Identifiable {
    let id = UUID()
    var project: DiaryProject?
    var area: TaskArea
}

struct OrganizerView: View {
    @ObservedObject var state: AppState
    /// Новый профиль открывает место хаоса; выбранный человеком раздел восстанавливается.
    @State private var section: OrganizerSection?
    @FocusState private var captureFocused: Bool
    @State private var scope: OrganizerArea = .all
    @State private var query = ""
    @State private var taskSheet: TaskSheet?
    @State private var projectSheet: ProjectSheet?
    @State private var removingTask: DayPlan?
    @State private var selectedProjectID: UUID?
    @State private var showCompleted = false
    @State private var showArchived = false
    @State private var showRemoved = false
    @State private var breakdownTask: DayPlan?
    @State private var completing: DayPlan?
    @State private var deleting: DayPlan?
    @State private var reopening: DayPlan?
    @State private var deletingProject: DiaryProject?
    @State private var now = Date()

    init(state: AppState) {
        self.state = state
        let saved = state.savedOrganizerSection.flatMap(OrganizerSection.init(rawValue:))
        _section = State(initialValue: saved ?? .inbox)
    }

    private var current: OrganizerSection { section ?? .inbox }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleProjects: [DiaryProject] {
        state.projects.filter { scope.includes($0.area) && ($0.archived == showArchived) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    private var selectedProject: DiaryProject? { state.projects.first { $0.id == selectedProjectID } }
    private var matchingTasks: [DayPlan] {
        _ = state.plans
        return sectionTasks.filter { scope.includes($0.taskArea) }
    }
    /// Задачи текущего раздела. «Обзор» строится из групп пересмотра, а не из этого списка.
    private var sectionTasks: [DayPlan] {
        switch current {
        case .inbox: return state.store.openTasks.filter { $0.taskStatus == .inbox }
        case .waiting: return state.store.waitingTasks()
        case .today: return state.store.tasksForToday(now: now)
        case .review: return []
        case .projects, .all:
            return state.store.visibleTasks(showCompleted: showCompleted, showRemoved: showRemoved)
                .filter { current == .all || $0.projectID == selectedProjectID }
        }
    }
    private var tasks: [DayPlan] { matchingTasks.sorted(by: taskOrder) }
    /// Один поиск по делам: задачи, проекты и строки места хаоса вместе.
    private var found: OrganizerSearchResults {
        _ = state.plans; _ = state.projects; _ = state.chaos
        let results = state.store.searchOrganizer(query, includeCompleted: showCompleted, includeRemoved: showRemoved)
        return OrganizerSearchResults(tasks: results.tasks.filter { scope.includes($0.taskArea) },
                                      projects: results.projects.filter { scope.includes($0.area) },
                                      chaos: results.chaos)
    }
    /// Порядок пересмотра задаёт хранилище; здесь остаётся только фильтр по сфере.
    private var reviewGroups: [ReviewGroup] {
        _ = state.plans; _ = state.projects
        return state.store.reviewGroups(now: now).compactMap { group in
            let items = group.items.filter { item in
                switch item {
                case .task(let task): return scope.includes(task.taskArea)
                case .project(let project): return scope.includes(project.area)
                }
            }
            return items.isEmpty ? nil : ReviewGroup(title: group.title, items: items)
        }
    }

    var body: some View {
        HSplitView {
            List(selection: $section) {
                ForEach(OrganizerSection.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, idealWidth: 185, maxWidth: 220)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                content
            }
            .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: section) { _, value in
            if value != .projects { selectedProjectID = nil }
            query = ""
            // Черновик поля и строки хаоса живут в AppState и при смене раздела не очищаются.
            if let value { state.rememberOrganizerSection(value.rawValue) }
        }
        .onChange(of: scope) { _, value in
            if let project = selectedProject, !value.includes(project.area) { selectedProjectID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = Date() }
        .onAppear {
            handleTaskCreationRequest()
            if state.chaosCaptureRequested { handleChaosCaptureRequest() }
            else if current == .inbox { focusCapture() }
        }
        .onChange(of: state.taskCreationRequested) { _, requested in
            if requested { handleTaskCreationRequest() }
        }
        .onChange(of: state.chaosCaptureToken) { _, _ in handleChaosCaptureRequest() }
        .sheet(item: $taskSheet) { sheet in
            OrganizerTaskEditor(state: state, task: sheet.task, projectID: sheet.projectID,
                                area: sheet.area, status: sheet.status, plannedDay: sheet.plannedDay,
                                chaosItem: sheet.chaosItem, atRisk: sheet.atRisk)
        }
        .sheet(item: $removingTask) { task in
            OrganizerTaskRemoval(state: state, task: task)
        }
        .sheet(item: $breakdownTask) { task in
            TaskBreakdownView(state: state, draft: state.breakdownDraft(for: task))
        }
        .confirmationDialog("Подтвердить результат задачи?", isPresented: Binding(get: { completing != nil }, set: { if !$0 { completing = nil } })) {
            Button("Результат достигнут, выполнить задачу") { if let task = completing { state.completePlan(task) }; completing = nil }
        } message: { Text("Отметки шагов сохранятся. Только это действие завершит исходную задачу и создаст запись дневника.") }
        .sheet(item: $projectSheet) { sheet in
            OrganizerProjectEditor(state: state, project: sheet.project, area: sheet.area) { id in
                scope = .all
                section = .projects
                selectedProjectID = id
            }
        }
        .confirmationDialog("Удалить задачу?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Удалить", role: .destructive) { if let task = deleting { state.deletePlan(task) }; deleting = nil }
        } message: { Text("Связанная запись останется в дневнике. Задачу с шагами удалить нельзя: сначала явно удалите шаги и сохраните список. Сразу после удаления задачу можно вернуть.") }
        .confirmationDialog("Вернуть задачу?", isPresented: Binding(get: { reopening != nil }, set: { if !$0 { reopening = nil } })) {
            Button("Вернуть в задачи") { if let task = reopening { state.reopenPlan(task) }; reopening = nil }
        } message: { Text("Неизменённая запись о выполнении будет убрана из дневника. Отредактированная запись сохранится.") }
        .confirmationDialog("Удалить проект?", isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } })) {
            Button("Удалить проект", role: .destructive) {
                if let project = deletingProject,
                   state.changeOrganizer("Проект удалён", { try state.store.deleteProject(id: project.id) }) {
                    selectedProjectID = nil
                }
                deletingProject = nil
            }
        } message: { Text("Задачи сохранятся в общем списке. Связь с проектом будет снята.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isSearching ? "Поиск" : current.rawValue).font(.title2.weight(.semibold))
                Spacer()
                Picker("Сфера", selection: $scope) {
                    ForEach(OrganizerArea.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 225)
            }
            HStack {
                TextField("Найти задачу, проект или строку", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Поиск по делам")
                if current == .projects {
                    Button { projectSheet = ProjectSheet(area: scope.defaultArea) } label: {
                        Label("Новый проект", systemImage: "folder.badge.plus")
                    }.disabled(state.isBlocked)
                } else {
                    Button { newTask() } label: { Label("Новая задача", systemImage: "plus") }
                        .disabled(state.isBlocked)
                }
            }
        }.padding(20)
    }

    @ViewBuilder private var content: some View {
        if isSearching {
            searchResults
        } else if current == .projects {
            if let project = selectedProject { projectDetail(project) } else { projectList }
        } else {
            taskList
        }
    }

    /// Один запрос ищет задачи, проекты и строки места хаоса вместе и показывает их группами.
    private var searchResults: some View {
        let results = found
        return VStack(spacing: 0) {
            visibilityToggles
            List {
                if !results.projects.isEmpty {
                    Section("Проекты") { ForEach(results.projects) { projectRow($0) } }
                }
                if !results.tasks.isEmpty {
                    Section("Задачи") { ForEach(results.tasks) { taskRow($0) } }
                }
                if !results.chaos.isEmpty {
                    Section("Место хаоса") { ForEach(results.chaos) { chaosRow($0) } }
                }
            }.listStyle(.inset)
                .overlay {
                    if results.isEmpty {
                        emptyNote("Ничего не найдено",
                                  "Поиск охватывает открытые задачи, неархивные проекты и строки места хаоса. Выполненные и снятые задачи видны только с включёнными переключателями выше.") {
                            EmptyView()
                        }
                    }
                }
        }
    }

    /// Показ выполненных и снятых — явное решение человека.
    private var visibilityToggles: some View {
        HStack(spacing: 16) {
            Toggle("Показывать выполненные", isOn: $showCompleted).toggleStyle(QuietCheckboxStyle())
            Toggle("Показывать снятые", isOn: $showRemoved).toggleStyle(QuietCheckboxStyle())
            Spacer()
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            if current == .inbox {
                HStack {
                    TextField("Задача, заметка или идея", text: $state.organizerCaptureText).onSubmit(capture)
                        .textFieldStyle(.roundedBorder)
                        .focused($captureFocused)
                        .accessibilityLabel("Быстрая запись в место хаоса")
                    Button("Записать", action: capture)
                        .disabled(state.organizerCaptureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBlocked)
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            if current == .today, !urgentChaos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Не может ждать").font(.headline).foregroundStyle(Theme.signal)
                    ForEach(urgentChaos) { chaosRow($0) }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            if current == .all { visibilityToggles }
            List {
                if current == .inbox {
                    ForEach(sortedChaos) { chaosRow($0) }
                }
                if current == .review {
                    ForEach(reviewGroups) { group in
                        Section {
                            ForEach(group.items) { item in
                                switch item {
                                case .task(let task): taskRow(task)
                                case .project(let project): reviewProjectRow(project)
                                }
                            }
                        } header: {
                            Text(group.title).signalForeground(group.title == "Под угрозой")
                        }
                    }
                } else if !tasks.isEmpty {
                    Section("Задачи") { ForEach(tasks) { taskRow($0) } }
                }
                if current == .today, !suggestions.isEmpty {
                    Section("Можно выбрать на сегодня") {
                        ForEach(Array(suggestions.prefix(5))) { task in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.text)
                                    Text(task.taskArea.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("На сегодня") { scheduleToday(task) }.disabled(state.isBlocked)
                            }.padding(.vertical, 5).accessibilityElement(children: .contain)
                        }
                    }
                }
            }.listStyle(.inset)
                .overlay {
                    if current == .today {
                        if tasks.isEmpty && urgentChaos.isEmpty && suggestions.isEmpty { emptyState }
                    } else if current == .review {
                        if reviewGroups.isEmpty { emptyState }
                    } else if tasks.isEmpty && sortedChaos.isEmpty {
                        emptyState
                    }
                }
        }
    }

    /// Проект в списке пересмотра: открывает его карточку.
    private func reviewProjectRow(_ project: DiaryProject) -> some View {
        Button {
            section = .projects
            selectedProjectID = project.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title).foregroundStyle(.primary)
                Text(project.nextActionID == nil ? "Определите следующий шаг" : "Наступила дата пересмотра")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var emptyState: some View {
        emptyNote(emptyTitle, emptyDetail) {
            if current == .today {
                Button("Открыть место хаоса") { section = .inbox; focusCapture() }
            }
        }
    }

    /// Пустой раздел говорит текстом слева, как пустой день в дневнике: без крупной иконки по центру.
    private func emptyNote<Action: View>(_ title: String, _ detail: String,
                                         @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            Text(detail).foregroundStyle(Theme.quiet)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            action().padding(.top, 6)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyTitle: String {
        switch current {
        case .today: return "Выберите, чем заняться сегодня"
        case .inbox: return "Сюда можно сбросить всё, что ещё не решено"
        case .waiting: return "Ожиданий пока нет"
        case .review: return "Пересмотр пока не требуется"
        default: return "Здесь появятся задачи"
        }
    }
    private var emptyDetail: String {
        switch current {
        case .inbox: return "Одна строка. Задачей, заметкой или снятием она станет позже, когда вы сами это решите."
        case .waiting: return "Укажите в задаче, чей ответ или какое событие нужно, и когда к ней вернуться."
        case .review: return "Список строится по порядку: обещания со сроком, обещания без срока, дела под угрозой, сегодняшние дела и следующие шаги проектов, ожидания, затем наступившие даты пересмотра и проекты без следующего шага."
        default: return "Добавьте задачу или запланируйте действие из общего списка."
        }
    }

    /// Что можно выбрать на сегодня: открытые дела без назначенного дня.
    private var suggestions: [DayPlan] {
        _ = state.plans
        return state.store.openTasks.filter { $0.day.isEmpty && $0.taskStatus == .ready && scope.includes($0.taskArea) }
            .sorted(by: taskOrder)
    }

    private func taskRow(_ task: DayPlan) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if task.isCompleted { reopening = task } else if !task.taskSteps.isEmpty { completing = task } else { state.completePlan(task) }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : (task.isRemoved ? "xmark.circle" : "circle"))
                    .font(.system(size: 20)).foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                    .compactHitArea()
            }.buttonStyle(.plain).padding(.top, -2).disabled(state.isBlocked || task.isRemoved)
                .accessibilityLabel(task.isCompleted ? "Вернуть задачу: \(task.text)" : "Выполнить задачу: \(task.text)")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.text).strikethrough(task.isCompleted).foregroundStyle(task.isCompleted || task.isRemoved ? .secondary : .primary)
                        .onTapGesture { if task.isOpen { edit(task) } }
                    Spacer(minLength: 8)
                    if task.isOpen {
                        Button { edit(task) } label: { Image(systemName: "ellipsis").compactHitArea() }
                            .buttonStyle(.borderless).accessibilityLabel("Изменить задачу: \(task.text)")
                            .help("Изменить задачу")
                    }
                }
                HStack(spacing: 10) {
                    Text(task.taskArea.title)
                    if let project = state.projects.first(where: { $0.id == task.projectID }) {
                        Label(project.title, systemImage: project.nextActionID == task.id ? "arrow.right.circle.fill" : "folder")
                    }
                    if task.taskStatus != .ready && !task.isCompleted { Text(task.taskStatus.title) }
                }.font(.caption).foregroundStyle(.secondary)
                if task.isOpen, let promised = task.promisedTo {
                    Label("Кому обещано · \(promised)", systemImage: "person.2").font(.callout).foregroundStyle(.secondary)
                }
                if task.isOpen, task.isAtRisk {
                    Label("Обещание под угрозой", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.signal)
                }
                if let reason = task.removalReason {
                    Label("Причина снятия · \(reason)", systemImage: "xmark.circle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if task.taskStatus == .waiting, let who = task.organization?.waitingFor, !task.isCompleted {
                    Label(who, systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
                }
                if !task.taskSteps.isEmpty {
                    if let next = task.nextStep {
                        Label(task.isCompleted ? "Незавершённый шаг: \(next.text)" : "Следующий: \(next.text)", systemImage: "arrow.right.circle").font(.callout)
                    } else {
                        Text(task.isCompleted ? "Результат задачи подтверждён." : "Шаги выполнены. Подтвердите результат задачи.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Выполнено шагов: \(task.taskSteps.filter(\.isCompleted).count) из \(task.taskSteps.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { breakdownTask = task } label: {
                    Text(task.taskSteps.isEmpty ? "Разбить на шаги" : "Открыть шаги").frame(minHeight: 24).contentShape(Rectangle())
                }
                    .buttonStyle(.borderless).disabled(state.isBlocked)
                    .padding(.vertical, -4)
                if !task.day.isEmpty { Text("День работы · \(task.day)").font(.caption).foregroundStyle(.secondary) }
                if let deadline = task.organization?.deadline {
                    Label("Срок · \(DiaryFormat.shortDate(deadline))", systemImage: "flag")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let date = task.organization?.reviewDate, !task.isCompleted {
                    Label("Пересмотреть · \(DiaryFormat.shortDate(date))", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(isReviewDue(date) ? .medium : .regular))
                        .foregroundStyle(isReviewDue(date) ? Theme.ink : Color.secondary)
                }
            }.contentShape(Rectangle())
        }.padding(.vertical, 9).accessibilityElement(children: .contain)
            .contextMenu {
                Button(task.taskSteps.isEmpty ? "Разбить на шаги" : "Открыть шаги") { breakdownTask = task }
                if task.isOpen {
                    Button("Изменить") { edit(task) }
                    Button("Запланировать на сегодня") { scheduleToday(task) }
                    Button(task.isAtRisk ? "Снять отметку «Обещание под угрозой»" : "Обещание под угрозой") {
                        state.changeOrganizer(task.isAtRisk ? "Отметка снята" : "Отмечено: обещание под угрозой") {
                            _ = try state.store.setTaskAtRisk(id: task.id, !task.isAtRisk)
                        }
                    }
                    if let projectID = task.projectID, task.taskStatus == .ready {
                        Button("Сделать следующим шагом") {
                            state.changeOrganizer("Следующий шаг выбран") { try state.store.setNextAction(projectID: projectID, taskID: task.id) }
                        }
                    }
                    Button("Снять…", role: .destructive) { removingTask = task }
                }
                if task.isRemoved {
                    Button("Вернуть в работу") {
                        state.changeOrganizer("Задача возвращена в работу") {
                            _ = try state.store.returnTaskToWork(id: task.id)
                        }
                    }
                }
                if let entry = state.linkedEntry(for: task) {
                    Button("Открыть запись в дневнике") { state.go(to: entry.timestamp); state.mode = .day }
                }
                Button("Удалить…", role: .destructive) { deleting = task }
            }
    }

    private func projectRow(_ project: DiaryProject) -> some View {
        Button {
            section = .projects
            selectedProjectID = project.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(Color.accentColor)
                    Text(project.title).font(.headline)
                    Spacer()
                    Text(project.area.title).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                Text(project.outcome).foregroundStyle(.secondary)
                if let next = state.plans.first(where: { $0.id == project.nextActionID }) {
                    Label(next.text, systemImage: "arrow.right.circle").font(.callout)
                } else if !project.archived {
                    Text("Определите следующий шаг").font(.callout.weight(.medium)).foregroundStyle(Theme.ink)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Показывать завершённые проекты", isOn: $showArchived)
                .toggleStyle(QuietCheckboxStyle()).padding(.horizontal, 20).padding(.vertical, 12)
            List {
                ForEach(visibleProjects) { projectRow($0) }
            }.listStyle(.inset)
                .overlay {
                    if visibleProjects.isEmpty, state.projects.isEmpty {
                        emptyNote("Какой результат хотите получить?",
                                  "Создайте проект и выберите одно ближайшее действие.") {
                            Button("Создать проект") { projectSheet = ProjectSheet(area: scope.defaultArea) }.disabled(state.isBlocked)
                        }
                    } else if visibleProjects.isEmpty {
                        Text("Проекты не найдены")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
        }
    }

    private func projectDetail(_ project: DiaryProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { selectedProjectID = nil } label: { Label("Проекты", systemImage: "chevron.left") }.buttonStyle(.link)
                    Spacer()
                    Menu {
                        Button("Изменить проект") { projectSheet = ProjectSheet(project: project, area: project.area) }
                        Button(project.archived ? "Возобновить проект" : "Завершить проект") {
                            state.changeOrganizer(project.archived ? "Проект возобновлён" : "Проект завершён") {
                                try state.store.setProjectArchived(id: project.id, archived: !project.archived)
                            }
                        }
                        Button("Удалить проект…", role: .destructive) { deletingProject = project }
                    } label: { Image(systemName: "ellipsis.circle") }.disabled(state.isBlocked)
                }
                Text(project.title).font(.title.weight(.semibold))
                Text(project.outcome).font(.body).lineLimit(4).textSelection(.enabled)
                if !project.uncertainty.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Что нужно выяснить").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(project.uncertainty).lineLimit(4).textSelection(.enabled)
                    }
                }
                if let review = project.reviewDate {
                    Label("Пересмотреть \(DiaryFormat.shortDate(review))", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !project.archived {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor)
                        if let next = state.plans.first(where: { $0.id == project.nextActionID }) {
                            Text(next.text).fontWeight(.medium)
                        } else {
                            Text("Выберите следующий шаг").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Выбрать") {
                            ForEach(state.plans.filter { $0.projectID == project.id && !$0.isCompleted && $0.taskStatus == .ready }) { task in
                                Button(task.text) {
                                    state.changeOrganizer("Следующий шаг выбран") { try state.store.setNextAction(projectID: project.id, taskID: task.id) }
                                }
                            }
                            if project.nextActionID != nil {
                                Button("Снять отметку") { state.changeOrganizer("Отметка снята") { try state.store.setNextAction(projectID: project.id, taskID: nil) } }
                            }
                        }.disabled(state.isBlocked)
                    }.padding(12).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 16) {
                    Toggle("Выполненные", isOn: $showCompleted).toggleStyle(QuietCheckboxStyle())
                    Toggle("Снятые", isOn: $showRemoved).toggleStyle(QuietCheckboxStyle())
                    Spacer()
                    Button { newTask(project: project) } label: { Label("Добавить действие", systemImage: "plus") }
                        .disabled(project.archived || state.isBlocked)
                }
            }.padding(20)
            Divider()
            List { ForEach(tasks) { taskRow($0) } }.listStyle(.inset)
        }
    }

    private var sortedChaos: [ChaosItem] {
        _ = state.chaos
        return state.store.sortedChaos()
    }

    private var urgentChaos: [ChaosItem] { sortedChaos.filter(\.urgent) }

    private func chaosRow(_ item: ChaosItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(item.urgent ? "Может подождать" : "Не может ждать") {
                    state.changeOrganizer(item.urgent ? "Отметка снята" : "Отмечено: не может ждать") {
                        _ = try state.store.setChaosUrgent(id: item.id, !item.urgent)
                    }
                }
                .signalForeground(item.urgent)
                Menu("Это задача") {
                    Button("Личное") { decideTask(item, area: .personal) }
                    Button("Работа") { decideTask(item, area: .work) }
                }
                Button("Это заметка") {
                    state.changeOrganizer("Запись стала заметкой") {
                        _ = try state.store.makeNote(fromChaos: item.id)
                    }
                }
                Button("Снять", role: .destructive) {
                    state.changeOrganizer("Запись снята") {
                        _ = try state.store.deleteChaosItem(id: item.id)
                    }
                }
            }
            .font(.caption)
            .disabled(state.isBlocked)
        }
        .padding(.vertical, 4)
    }

    /// «Это задача» открывает обычный редактор: остальные поля человек заполняет по желанию,
    /// а строка уходит из корзины только вместе с успешно сохранённой задачей.
    private func decideTask(_ item: ChaosItem, area: TaskArea) {
        taskSheet = TaskSheet(area: area, status: .ready, chaosItem: item, atRisk: item.urgent)
    }

    private func newTask(project: DiaryProject? = nil) {
        let status: TaskStatus = current == .waiting ? .waiting : .ready
        taskSheet = TaskSheet(projectID: project?.id, area: project?.area ?? scope.defaultArea,
                              status: status, plannedDay: current == .today ? Date() : nil)
    }
    private func handleTaskCreationRequest() {
        guard state.taskCreationRequested else { return }
        state.taskCreationRequested = false
        guard !state.isBlocked, taskSheet == nil, projectSheet == nil else { return }
        newTask(project: selectedProject)
    }
    /// Команда «Записать в место хаоса»: только навигация и фокус, черновик остаётся как есть.
    private func handleChaosCaptureRequest() {
        state.chaosCaptureRequested = false
        query = ""
        if section != .inbox { section = .inbox }
        focusCapture()
    }
    private func focusCapture() {
        // Поле появляется после перестройки списка раздела, поэтому фокус ставится следующим проходом.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { captureFocused = true }
    }
    private func edit(_ task: DayPlan) {
        taskSheet = TaskSheet(task: task, projectID: task.projectID, area: task.taskArea, status: task.taskStatus)
    }
    private func capture() {
        guard !state.organizerCaptureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if state.changeOrganizer("Записано в место хаоса", {
            _ = try state.store.addChaosItem(text: state.organizerCaptureText)
        }) { state.organizerCaptureText = "" }
    }
    private func scheduleToday(_ task: DayPlan) {
        var metadata = task.organization ?? TaskOrganization()
        if metadata.status == .inbox { metadata.status = .ready }
        state.changeOrganizer("Задача запланирована на сегодня") {
            _ = try state.store.updateTask(id: task.id, text: task.text, plannedDay: Date(), organization: metadata)
        }
    }
    private func isReviewDue(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: now)
    }
    /// Открытые дела выше закрытых: снятая задача уходит вниз вместе с выполненной.
    private func taskOrder(_ first: DayPlan, _ second: DayPlan) -> Bool {
        if first.isOpen != second.isOpen { return first.isOpen }
        if first.createdAt != second.createdAt { return first.createdAt < second.createdAt }
        return first.id.uuidString < second.id.uuidString
    }
}

private struct OrganizerTaskEditor: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let task: DayPlan?
    /// Строка места хаоса, если редактор открыт решением «Это задача».
    let chaosItem: ChaosItem?
    @State private var text: String
    @State private var area: TaskArea
    @State private var projectID: UUID?
    @State private var status: TaskStatus
    @State private var waitingFor: String
    @State private var promisedTo: String
    @State private var atRisk: Bool
    @State private var details: String
    @State private var planned: Bool
    @State private var day: Date
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var hasReview: Bool
    @State private var review: Date
    @State private var saveError: String?
    @State private var showSteps = false
    /// «Дополнительно» свёрнуто по умолчанию; значения полей живут в @State и при сворачивании не теряются.
    @State private var showAdvanced: Bool
    /// Защита от второго нажатия «Сохранить» до закрытия листа.
    @State private var didSave = false

    init(state: AppState, task: DayPlan?, projectID: UUID?, area: TaskArea, status: TaskStatus,
         plannedDay: Date?, chaosItem: ChaosItem? = nil, atRisk: Bool = false) {
        self.state = state
        self.task = task
        self.chaosItem = chaosItem
        let metadata = task?.organization
        let date = task.flatMap { DiaryDay.date($0.day) } ?? plannedDay
        _text = State(initialValue: task?.text ?? (chaosItem?.text ?? ""))
        _area = State(initialValue: metadata?.area ?? area)
        _projectID = State(initialValue: task?.projectID ?? projectID)
        _status = State(initialValue: task?.taskStatus ?? status)
        _waitingFor = State(initialValue: metadata?.waitingFor ?? "")
        _promisedTo = State(initialValue: metadata?.promisedTo ?? "")
        _atRisk = State(initialValue: metadata?.atRisk ?? atRisk)
        _details = State(initialValue: metadata?.details ?? "")
        _planned = State(initialValue: date != nil)
        _day = State(initialValue: date ?? Date())
        _hasDeadline = State(initialValue: metadata?.deadline != nil)
        _deadline = State(initialValue: metadata?.deadline ?? Date())
        _hasReview = State(initialValue: metadata?.reviewDate != nil)
        _review = State(initialValue: metadata?.reviewDate ?? Date())
        _showAdvanced = State(initialValue: false)
    }

    /// Что уже задано в свёрнутом блоке: видно без разворачивания, в том числе у существующей задачи.
    private var advancedSummary: [String] {
        var parts: [String] = []
        if let project = state.projects.first(where: { $0.id == projectID }) { parts.append("Проект: \(project.title)") }
        if status != .ready { parts.append(status.title) }
        if !promisedTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Обещано: \(promisedTo)") }
        if atRisk { parts.append("Под угрозой") }
        if planned { parts.append("День: \(DiaryFormat.shortDate(day))") }
        if hasDeadline { parts.append("Срок: \(DiaryFormat.shortDate(deadline))") }
        if hasReview { parts.append("Пересмотр: \(DiaryFormat.shortDate(review))") }
        if !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Есть заметка") }
        return parts
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(task == nil ? "Новая задача" : "Изменить задачу").font(.title2.weight(.semibold)); Spacer() }.padding(20)
            Form {
                Section {
                    TextField("Действие", text: $text, axis: .vertical).lineLimit(1...4)
                    if chaosItem != nil {
                        Text("Строка уйдёт из места хаоса, когда вы сохраните задачу. Отмена и ошибка оставят её на месте.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Сфера", selection: $area) { ForEach(TaskArea.allCases) { Text($0.title).tag($0) } }
                        .disabled(projectID != nil)
                }
                Section {
                    Button { showAdvanced.toggle() } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold)).frame(width: 12)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Дополнительно").foregroundStyle(.primary)
                                Text(advancedSummary.isEmpty ? "Проект, состояние, обещание, даты, заметка. Необязательно."
                                     : advancedSummary.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }.frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Дополнительно")
                    .accessibilityValue(showAdvanced ? "развёрнуто" : "свёрнуто")
                    .accessibilityHint(advancedSummary.isEmpty ? "Необязательные поля задачи" : advancedSummary.joined(separator: ", "))
                }
                // Свёрнутый блок убран из иерархии целиком: фокус клавиатуры и VoiceOver в него не попадают.
                if showAdvanced { advancedSections }
            }.formStyle(.grouped)
            if let error = saveError { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding(.horizontal, 20) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBlocked || didSave)
            }.padding(20)
        }.frame(width: 540, height: showAdvanced ? 650 : 400)
            .sheet(isPresented: $showSteps) {
                if let task, let current = state.plans.first(where: { $0.id == task.id }) {
                    TaskBreakdownView(state: state, draft: state.breakdownDraft(for: current))
                }
            }
            .onChange(of: projectID) { _, id in
                if let project = state.projects.first(where: { $0.id == id }) { area = project.area }
            }
    }

    @ViewBuilder private var advancedSections: some View {
                Section {
                    Picker("Проект", selection: $projectID) {
                        Text("Без проекта").tag(nil as UUID?)
                        ForEach(state.projects.filter { !$0.archived }) { Text("\($0.title) · \($0.area.title)").tag(Optional($0.id)) }
                    }
                    Picker("Состояние", selection: $status) { ForEach(TaskStatus.selectableCases) { Text($0.title).tag($0) } }
                    if status == .waiting { TextField("Чего или чьего ответа жду", text: $waitingFor, axis: .vertical).lineLimit(1...3) }
                }
                Section("Обещание другому человеку") {
                    TextField("Кому обещано", text: $promisedTo)
                        .accessibilityLabel("Кому обещано")
                    Toggle("Обещание под угрозой", isOn: $atRisk).toggleStyle(QuietCheckboxStyle())
                    Text("Отметка не меняет статус и даты, не отправляет уведомлений и не меняет порядок остальных дел. Она показывает дело в «Сегодня» и в пересмотре, даже если день работы не выбран.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Когда вернуться к задаче") {
                    OrganizerDateField(title: "День работы", enabled: $planned, date: $day)
                    OrganizerDateField(title: "Срок результата", enabled: $hasDeadline, date: $deadline)
                    OrganizerDateField(title: "Дата пересмотра", enabled: $hasReview, date: $review)
                }
                if task != nil {
                    Section("Шаги задачи") {
                        Button("Разбить на шаги") { showSteps = true }
                        Text("Откроется сохранённая версия задачи. Сначала сохраните изменения названия и подробностей, если они нужны для разбиения.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Заметка к задаче") {
                    TextEditor(text: $details)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100, idealHeight: 120, maxHeight: 180)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .topLeading) {
                            if details.isEmpty {
                                Text("Подробности или что нужно выяснить")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("Заметка к задаче")
                }
    }

    private func save() {
        guard !didSave else { return }
        let metadata = TaskOrganization(area: area, projectID: projectID, status: status, waitingFor: waitingFor,
                                        promisedTo: promisedTo, atRisk: atRisk,
                                        reviewDate: hasReview ? review : nil, deadline: hasDeadline ? deadline : nil,
                                        details: details)
        let success = state.changeOrganizer(task == nil ? "Задача добавлена" : "Задача сохранена") {
            if let task {
                _ = try state.store.updateTask(id: task.id, text: text, plannedDay: planned ? day : nil, organization: metadata)
            } else if let chaosItem {
                _ = try state.store.makeTask(fromChaos: chaosItem.id, text: text,
                                             plannedDay: planned ? day : nil, organization: metadata)
            } else {
                _ = try state.store.addTask(text: text, plannedDay: planned ? day : nil, organization: metadata)
            }
        }
        if success { didSave = true; dismiss() } else { saveError = state.errorMessage }
    }
}

extension View {
    /// Область нажатия компактной кнопки 28×28 pt; иконка остаётся прежнего размера.
    func compactHitArea(_ side: CGFloat = 28) -> some View {
        frame(width: side, height: side).contentShape(Rectangle())
    }
}

/// «Снять…»: причина обязательна и сохраняется вместе с задачей.
private struct OrganizerTaskRemoval: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let task: DayPlan
    @State private var reason = ""
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Снять задачу").font(.title2.weight(.semibold)); Spacer() }.padding(20)
            Form {
                Section("Что снимаете") {
                    Text(task.text).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section("Причина") {
                    TextField("Почему дело больше не нужно", text: $reason, axis: .vertical)
                        .lineLimit(2...4).accessibilityLabel("Причина снятия")
                    Text("Без причины снятие не сохраняется. Снятие не считается выполнением, не создаёт запись в дневнике и сохраняет шаги задачи.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error = saveError { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding(.horizontal, 20) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Снять", role: .destructive, action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBlocked)
            }.padding(20)
        }.frame(width: 480, height: 340)
    }

    private func save() {
        if state.changeOrganizer("Задача снята", { _ = try state.store.setTaskRemoved(id: task.id, reason: reason) }) {
            dismiss()
        } else { saveError = state.errorMessage }
    }
}

private struct OrganizerProjectEditor: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let project: DiaryProject?
    let onSaved: (UUID) -> Void
    @State private var title: String
    @State private var outcome: String
    @State private var area: TaskArea
    @State private var uncertainty: String
    @State private var hasReview: Bool
    @State private var review: Date
    @State private var saveError: String?

    init(state: AppState, project: DiaryProject?, area: TaskArea, onSaved: @escaping (UUID) -> Void) {
        self.state = state; self.project = project; self.onSaved = onSaved
        _title = State(initialValue: project?.title ?? "")
        _outcome = State(initialValue: project?.outcome ?? "")
        _area = State(initialValue: project?.area ?? area)
        _uncertainty = State(initialValue: project?.uncertainty ?? "")
        _hasReview = State(initialValue: project?.reviewDate != nil)
        _review = State(initialValue: project?.reviewDate ?? Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(project == nil ? "Новый проект" : "Изменить проект").font(.title2.weight(.semibold)); Spacer() }.padding(20)
            Form {
                Section {
                    TextField("Название", text: $title)
                    Picker("Сфера", selection: $area) { ForEach(TaskArea.allCases) { Text($0.title).tag($0) } }
                    TextField("Какой результат хочу получить", text: $outcome, axis: .vertical).lineLimit(2...4)
                }
                Section("Работа с неопределённостью") {
                    TextField("Что нужно выяснить или проверить", text: $uncertainty, axis: .vertical).lineLimit(3...6)
                    OrganizerDateField(title: "Дата пересмотра", enabled: $hasReview, date: $review)
                }
            }.formStyle(.grouped)
            if let error = saveError { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding(.horizontal, 20) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBlocked)
            }.padding(20)
        }.frame(width: 540, height: 510)
    }

    private func save() {
        var id: UUID?
        let success = state.changeOrganizer("Проект сохранён") {
            id = try state.store.saveProject(id: project?.id, title: title, outcome: outcome, area: area,
                                             uncertainty: uncertainty, reviewDate: hasReview ? review : nil).id
        }
        if success, let id { dismiss(); onSaved(id) } else { saveError = state.errorMessage }
    }
}

private struct OrganizerDateField: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var date: Date
    var body: some View {
        HStack {
            Toggle(title, isOn: $enabled).toggleStyle(QuietCheckboxStyle())
            Spacer()
            if enabled { DatePicker(title, selection: $date, displayedComponents: .date).labelsHidden() }
        }
    }
}

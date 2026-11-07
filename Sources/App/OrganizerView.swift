import SwiftUI

private enum OrganizerSection: String, CaseIterable, Identifiable {
    case today = "Сегодня", inbox = "Входящие", projects = "Проекты"
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

private struct TaskSheet: Identifiable {
    let id = UUID()
    var task: DayPlan?
    var projectID: UUID?
    var area: TaskArea
    var status: TaskStatus
    var plannedDay: Date?
}

private struct ProjectSheet: Identifiable {
    let id = UUID()
    var project: DiaryProject?
    var area: TaskArea
}

struct OrganizerView: View {
    @ObservedObject var state: AppState
    @State private var section: OrganizerSection? = .today
    @State private var scope: OrganizerArea = .all
    @State private var query = ""
    @State private var taskSheet: TaskSheet?
    @State private var projectSheet: ProjectSheet?
    @State private var selectedProjectID: UUID?
    @State private var showCompleted = false
    @State private var showArchived = false
    @State private var breakdownTask: DayPlan?
    @State private var completing: DayPlan?
    @State private var deleting: DayPlan?
    @State private var reopening: DayPlan?
    @State private var deletingProject: DiaryProject?
    @State private var now = Date()

    private var current: OrganizerSection { section ?? .today }
    private var today: String { DiaryDay.key(now) }
    private var visibleProjects: [DiaryProject] {
        state.projects.filter { scope.includes($0.area) && ($0.archived == showArchived) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    private var matchingProjects: [DiaryProject] {
        visibleProjects.filter { query.isEmpty || ($0.title + " " + $0.outcome).localizedCaseInsensitiveContains(query) }
    }
    private var selectedProject: DiaryProject? { state.projects.first { $0.id == selectedProjectID } }
    private var matchingTasks: [DayPlan] {
        state.plans.filter { task in
            scope.includes(task.taskArea) && matchesQuery(task)
        }
    }
    private var tasks: [DayPlan] {
        matchingTasks.filter { task in
            switch current {
            case .inbox: return !task.isCompleted && task.taskStatus == .inbox
            case .waiting: return !task.isCompleted && task.taskStatus == .waiting
            case .review:
                return !task.isCompleted && isReviewDue(task.organization?.reviewDate)
            case .today:
                let scheduled = !task.day.isEmpty && task.day <= today
                let due = task.organization?.deadline.map { Calendar.current.startOfDay(for: $0) <= Calendar.current.startOfDay(for: now) } ?? false
                return !task.isCompleted && task.taskStatus != .paused && (scheduled || due)
            case .projects: return task.projectID == selectedProjectID && (showCompleted || !task.isCompleted)
            case .all: return showCompleted || !task.isCompleted
            }
        }.sorted(by: taskOrder)
    }
    private var reviewProjects: [DiaryProject] {
        state.projects.filter { project in
            scope.includes(project.area) && !project.archived && (project.nextActionID == nil || isReviewDue(project.reviewDate))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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
        }
        .onChange(of: scope) { _, value in
            if let project = selectedProject, !value.includes(project.area) { selectedProjectID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = Date() }
        .onAppear(perform: handleTaskCreationRequest)
        .onChange(of: state.taskCreationRequested) { _, requested in
            if requested { handleTaskCreationRequest() }
        }
        .sheet(item: $taskSheet) { sheet in
            OrganizerTaskEditor(state: state, task: sheet.task, projectID: sheet.projectID,
                                area: sheet.area, status: sheet.status, plannedDay: sheet.plannedDay)
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
                Text(current.rawValue).font(.title2.weight(.semibold))
                Spacer()
                Picker("Сфера", selection: $scope) {
                    ForEach(OrganizerArea.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 225)
            }
            HStack {
                TextField(current == .projects ? "Найти проект" : "Найти задачу", text: $query)
                    .textFieldStyle(.roundedBorder)
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
        if current == .projects {
            if let project = selectedProject { projectDetail(project) } else { projectList }
        } else {
            taskList
        }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            if current == .inbox {
                HStack {
                    TextField("Быстро записать мысль или задачу", text: $state.organizerCaptureText).onSubmit(capture)
                        .textFieldStyle(.roundedBorder)
                    Button("Добавить", action: capture)
                        .disabled(state.organizerCaptureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBlocked)
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            if current == .all {
                Toggle("Показывать выполненные", isOn: $showCompleted)
                    .toggleStyle(QuietCheckboxStyle()).padding(.horizontal, 20).padding(.vertical, 10)
            }
            List {
                if current == .review, !reviewProjects.isEmpty {
                    Section("Проекты для пересмотра") {
                        ForEach(reviewProjects) { project in
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
                    }
                }
                if !tasks.isEmpty {
                    Section(current == .review ? "Задачи для пересмотра" : "Задачи") {
                        ForEach(tasks) { taskRow($0) }
                    }
                }
                if current == .today {
                    let suggestions = matchingTasks.filter { !$0.isCompleted && $0.day.isEmpty && $0.taskStatus == .ready }.sorted(by: taskOrder)
                    if !suggestions.isEmpty {
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
                }
            }.listStyle(.inset)
                .overlay {
                    if tasks.isEmpty && current != .today && (current != .review || reviewProjects.isEmpty) {
                        emptyState
                    }
                    if current == .today && tasks.isEmpty && !matchingTasks.contains(where: { !$0.isCompleted && $0.day.isEmpty && $0.taskStatus == .ready }) {
                        emptyState
                    }
                }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: current.icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(query.isEmpty ? emptyTitle : "Задачи не найдены").font(.headline)
            Text(emptyDetail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if current == .today {
                Button("Открыть входящие") { section = .inbox }
            }
        }.padding(24)
    }

    private var emptyTitle: String {
        switch current {
        case .today: return "Выберите, чем заняться сегодня"
        case .inbox: return "Освободите голову"
        case .waiting: return "Ожиданий пока нет"
        case .review: return "Пересмотр пока не требуется"
        default: return "Здесь появятся задачи"
        }
    }
    private var emptyDetail: String {
        switch current {
        case .inbox: return "Запишите мысль одной строкой. Уточнить результат и выбрать проект можно позже."
        case .waiting: return "Укажите в задаче, чей ответ или какое событие нужно, и когда к ней вернуться."
        case .review: return "Здесь появятся задачи с наступившей датой пересмотра и проекты без следующего шага."
        default: return "Добавьте задачу или запланируйте действие из общего списка."
        }
    }

    private func taskRow(_ task: DayPlan) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if task.isCompleted { reopening = task } else if !task.taskSteps.isEmpty { completing = task } else { state.completePlan(task) }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
            }.buttonStyle(.plain).padding(.top, 2).disabled(state.isBlocked)
                .accessibilityLabel(task.isCompleted ? "Вернуть задачу: \(task.text)" : "Выполнить задачу: \(task.text)")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.text).strikethrough(task.isCompleted).foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .onTapGesture { if !task.isCompleted { edit(task) } }
                    Spacer(minLength: 8)
                    if !task.isCompleted {
                        Button { edit(task) } label: { Image(systemName: "ellipsis") }
                            .buttonStyle(.borderless).accessibilityLabel("Изменить задачу: \(task.text)")
                    }
                }
                HStack(spacing: 10) {
                    Text(task.taskArea.title)
                    if let project = state.projects.first(where: { $0.id == task.projectID }) {
                        Label(project.title, systemImage: project.nextActionID == task.id ? "arrow.right.circle.fill" : "folder")
                    }
                    if task.taskStatus != .ready && !task.isCompleted { Text(task.taskStatus.title) }
                }.font(.caption).foregroundStyle(.secondary)
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
                Button(task.taskSteps.isEmpty ? "Разбить на шаги" : "Открыть шаги") { breakdownTask = task }
                    .buttonStyle(.borderless).disabled(state.isBlocked)
                if !task.day.isEmpty { Text("День работы · \(task.day)").font(.caption).foregroundStyle(.secondary) }
                if let deadline = task.organization?.deadline {
                    Label("Срок · \(DiaryFormat.shortDate(deadline))", systemImage: "flag")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let date = task.organization?.reviewDate, !task.isCompleted {
                    Label("Пересмотреть · \(DiaryFormat.shortDate(date))", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(isReviewDue(date) ? Color.accentColor : Color.secondary)
                }
            }.contentShape(Rectangle())
        }.padding(.vertical, 9).accessibilityElement(children: .contain)
            .contextMenu {
                Button(task.taskSteps.isEmpty ? "Разбить на шаги" : "Открыть шаги") { breakdownTask = task }
                if !task.isCompleted {
                    Button("Изменить") { edit(task) }
                    Button("Запланировать на сегодня") { scheduleToday(task) }
                    if let projectID = task.projectID, task.taskStatus == .ready {
                        Button("Сделать следующим шагом") {
                            state.changeOrganizer("Следующий шаг выбран") { try state.store.setNextAction(projectID: projectID, taskID: task.id) }
                        }
                    }
                }
                if let entry = state.linkedEntry(for: task) {
                    Button("Открыть запись в дневнике") { state.go(to: entry.timestamp); state.mode = .day }
                }
                Button("Удалить…", role: .destructive) { deleting = task }
            }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Показывать завершённые проекты", isOn: $showArchived)
                .toggleStyle(QuietCheckboxStyle()).padding(.horizontal, 20).padding(.vertical, 12)
            List {
                ForEach(matchingProjects) { project in
                    Button { selectedProjectID = project.id } label: {
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
                                Text("Определите следующий шаг").font(.callout).foregroundStyle(Color.accentColor)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.listStyle(.inset)
                .overlay {
                    if matchingProjects.isEmpty, state.projects.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Какой результат хотите получить?").font(.headline)
                            Text("Создайте проект и выберите одно ближайшее действие.").foregroundStyle(.secondary)
                            Button("Создать проект") { projectSheet = ProjectSheet(area: scope.defaultArea) }.disabled(state.isBlocked)
                        }.padding()
                    } else if matchingProjects.isEmpty {
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
                HStack {
                    Toggle("Выполненные", isOn: $showCompleted).toggleStyle(QuietCheckboxStyle())
                    Spacer()
                    Button { newTask(project: project) } label: { Label("Добавить действие", systemImage: "plus") }
                        .disabled(project.archived || state.isBlocked)
                }
            }.padding(20)
            Divider()
            List { ForEach(tasks) { taskRow($0) } }.listStyle(.inset)
        }
    }

    private func newTask(project: DiaryProject? = nil) {
        let status: TaskStatus = current == .inbox ? .inbox : (current == .waiting ? .waiting : .ready)
        taskSheet = TaskSheet(projectID: project?.id, area: project?.area ?? scope.defaultArea,
                              status: status, plannedDay: current == .today ? Date() : nil)
    }
    private func handleTaskCreationRequest() {
        guard state.taskCreationRequested else { return }
        state.taskCreationRequested = false
        guard !state.isBlocked, taskSheet == nil, projectSheet == nil else { return }
        newTask(project: selectedProject)
    }
    private func edit(_ task: DayPlan) {
        taskSheet = TaskSheet(task: task, projectID: task.projectID, area: task.taskArea, status: task.taskStatus)
    }
    private func capture() {
        guard !state.organizerCaptureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if state.changeOrganizer("Добавлено во входящие", {
            _ = try state.store.addTask(text: state.organizerCaptureText, organization: TaskOrganization(area: scope.defaultArea, status: .inbox))
        }) { state.organizerCaptureText = "" }
    }
    private func scheduleToday(_ task: DayPlan) {
        var metadata = task.organization ?? TaskOrganization()
        if metadata.status == .inbox { metadata.status = .ready }
        state.changeOrganizer("Задача запланирована на сегодня") {
            _ = try state.store.updateTask(id: task.id, text: task.text, plannedDay: Date(), organization: metadata)
        }
    }
    private func matchesQuery(_ task: DayPlan) -> Bool {
        query.isEmpty || (task.text + " " + (task.organization?.details ?? "") + " " + (task.organization?.waitingFor ?? "")).localizedCaseInsensitiveContains(query)
    }
    private func isReviewDue(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: now)
    }
    private func taskOrder(_ first: DayPlan, _ second: DayPlan) -> Bool {
        if first.isCompleted != second.isCompleted { return !first.isCompleted }
        if first.createdAt != second.createdAt { return first.createdAt < second.createdAt }
        return first.id.uuidString < second.id.uuidString
    }
}

private struct OrganizerTaskEditor: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let task: DayPlan?
    @State private var text: String
    @State private var area: TaskArea
    @State private var projectID: UUID?
    @State private var status: TaskStatus
    @State private var waitingFor: String
    @State private var details: String
    @State private var planned: Bool
    @State private var day: Date
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var hasReview: Bool
    @State private var review: Date
    @State private var saveError: String?
    @State private var showSteps = false

    init(state: AppState, task: DayPlan?, projectID: UUID?, area: TaskArea, status: TaskStatus, plannedDay: Date?) {
        self.state = state
        self.task = task
        let metadata = task?.organization
        let date = task.flatMap { DiaryDay.date($0.day) } ?? plannedDay
        _text = State(initialValue: task?.text ?? "")
        _area = State(initialValue: metadata?.area ?? area)
        _projectID = State(initialValue: task?.projectID ?? projectID)
        _status = State(initialValue: task?.taskStatus ?? status)
        _waitingFor = State(initialValue: metadata?.waitingFor ?? "")
        _details = State(initialValue: metadata?.details ?? "")
        _planned = State(initialValue: date != nil)
        _day = State(initialValue: date ?? Date())
        _hasDeadline = State(initialValue: metadata?.deadline != nil)
        _deadline = State(initialValue: metadata?.deadline ?? Date())
        _hasReview = State(initialValue: metadata?.reviewDate != nil)
        _review = State(initialValue: metadata?.reviewDate ?? Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(task == nil ? "Новая задача" : "Изменить задачу").font(.title2.weight(.semibold)); Spacer() }.padding(20)
            Form {
                Section {
                    TextField("Действие", text: $text, axis: .vertical).lineLimit(1...4)
                    Picker("Сфера", selection: $area) { ForEach(TaskArea.allCases) { Text($0.title).tag($0) } }
                        .disabled(projectID != nil)
                    Picker("Проект", selection: $projectID) {
                        Text("Без проекта").tag(nil as UUID?)
                        ForEach(state.projects.filter { !$0.archived }) { Text("\($0.title) · \($0.area.title)").tag(Optional($0.id)) }
                    }
                    Picker("Состояние", selection: $status) { ForEach(TaskStatus.allCases) { Text($0.title).tag($0) } }
                    if status == .waiting { TextField("Чего или чьего ответа жду", text: $waitingFor, axis: .vertical).lineLimit(1...3) }
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
            }.formStyle(.grouped)
            if let error = saveError { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding(.horizontal, 20) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBlocked)
            }.padding(20)
        }.frame(width: 540, height: 650)
            .sheet(isPresented: $showSteps) {
                if let task, let current = state.plans.first(where: { $0.id == task.id }) {
                    TaskBreakdownView(state: state, draft: state.breakdownDraft(for: current))
                }
            }
            .onChange(of: projectID) { _, id in
                if let project = state.projects.first(where: { $0.id == id }) { area = project.area }
            }
    }

    private func save() {
        let metadata = TaskOrganization(area: area, projectID: projectID, status: status, waitingFor: waitingFor,
                                        reviewDate: hasReview ? review : nil, deadline: hasDeadline ? deadline : nil, details: details)
        let success = state.changeOrganizer(task == nil ? "Задача добавлена" : "Задача сохранена") {
            if let task {
                _ = try state.store.updateTask(id: task.id, text: text, plannedDay: planned ? day : nil, organization: metadata)
            } else {
                _ = try state.store.addTask(text: text, plannedDay: planned ? day : nil, organization: metadata)
            }
        }
        if success { dismiss() } else { saveError = state.errorMessage }
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

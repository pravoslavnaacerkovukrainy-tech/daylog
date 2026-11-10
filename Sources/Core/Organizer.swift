import Foundation

public enum TaskArea: String, Codable, CaseIterable, Identifiable {
    case work, personal
    public var id: String { rawValue }
    public var title: String { self == .work ? "Работа" : "Личное" }
}

public enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case inbox, ready, waiting, paused, removed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .inbox: return "Место хаоса"
        case .ready: return "Можно делать"
        case .waiting: return "Ожидаю"
        case .paused: return "Отложено"
        case .removed: return "Снято"
        }
    }

    /// «Снято» задаётся только командой «Снять…» с причиной, поэтому в редакторе его нет.
    public static var selectableCases: [TaskStatus] { allCases.filter { $0 != .removed } }
}

/// Дополнительные поля задачи. Отсутствие блока в старом плане означает обычную личную задачу.
public struct TaskOrganization: Codable, Equatable, Hashable {
    public var area: TaskArea
    public var projectID: UUID?
    public var status: TaskStatus
    public var waitingFor: String?
    /// Кому обещано. Свободная строка, а не контакт: адресной книги приложение не ведёт.
    public var promisedTo: String?
    /// Обещание под угрозой. Ставит и снимает только человек.
    public var atRisk: Bool
    /// Причина снятия. Непустая только вместе со статусом «Снято».
    public var removalReason: String?
    public var reviewDate: Date?
    public var deadline: Date?
    public var details: String?

    public init(area: TaskArea = .personal, projectID: UUID? = nil, status: TaskStatus = .ready,
                waitingFor: String? = nil, promisedTo: String? = nil, atRisk: Bool = false,
                removalReason: String? = nil, reviewDate: Date? = nil, deadline: Date? = nil,
                details: String? = nil) {
        self.area = area
        self.projectID = projectID
        self.status = status
        self.waitingFor = waitingFor
        self.promisedTo = promisedTo
        self.atRisk = atRisk
        self.removalReason = removalReason
        self.reviewDate = reviewDate
        self.deadline = deadline
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case area, projectID, status, waitingFor, promisedTo, atRisk, removalReason
        case reviewDate, deadline, details
    }

    /// Прежние файлы не знают `atRisk`; отсутствие ключа читается как «не под угрозой».
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        area = try c.decode(TaskArea.self, forKey: .area)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        status = try c.decode(TaskStatus.self, forKey: .status)
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
        promisedTo = try c.decodeIfPresent(String.self, forKey: .promisedTo)
        atRisk = try c.decodeIfPresent(Bool.self, forKey: .atRisk) ?? false
        removalReason = try c.decodeIfPresent(String.self, forKey: .removalReason)
        reviewDate = try c.decodeIfPresent(Date.self, forKey: .reviewDate)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        details = try c.decodeIfPresent(String.self, forKey: .details)
    }

    /// Ложная отметка и пустые строки не пишутся, чтобы файл без них не поднимал версию.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(area, forKey: .area)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(waitingFor, forKey: .waitingFor)
        try c.encodeIfPresent(promisedTo, forKey: .promisedTo)
        if atRisk { try c.encode(true, forKey: .atRisk) }
        try c.encodeIfPresent(removalReason, forKey: .removalReason)
        try c.encodeIfPresent(reviewDate, forKey: .reviewDate)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encodeIfPresent(details, forKey: .details)
    }
}

public extension DayPlan {
    var taskArea: TaskArea { organization?.area ?? .personal }
    var taskStatus: TaskStatus { organization?.status ?? .ready }
    var projectID: UUID? { organization?.projectID }
    var promisedTo: String? { organization?.promisedTo }
    var removalReason: String? { organization?.removalReason }
    var isAtRisk: Bool { organization?.atRisk ?? false }
    var isRemoved: Bool { taskStatus == .removed }
    /// Задача участвует в выборках: не выполнена и не снята.
    var isOpen: Bool { !isCompleted && !isRemoved }
}

public struct DiaryProject: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var outcome: String
    public var area: TaskArea
    public var uncertainty: String
    public var reviewDate: Date?
    public var nextActionID: UUID?
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, outcome: String, area: TaskArea,
                uncertainty: String = "", reviewDate: Date? = nil, nextActionID: UUID? = nil,
                archived: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.outcome = outcome
        self.area = area
        self.uncertainty = uncertainty
        self.reviewDate = reviewDate
        self.nextActionID = nextActionID
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Пункт списка пересмотра: задача или проект.
public enum ReviewItem: Equatable, Hashable, Identifiable {
    case task(DayPlan)
    case project(DiaryProject)

    public var id: String {
        switch self {
        case .task(let task): return "task:\(task.id.uuidString)"
        case .project(let project): return "project:\(project.id.uuidString)"
        }
    }
}

/// Одна группа пересмотра. Пустые группы в список не попадают.
public struct ReviewGroup: Equatable, Identifiable {
    public let title: String
    public let items: [ReviewItem]
    public var id: String { title }

    public init(title: String, items: [ReviewItem]) {
        self.title = title
        self.items = items
    }
}

/// Результат одного поиска по делам.
public struct OrganizerSearchResults: Equatable {
    public var tasks: [DayPlan]
    public var projects: [DiaryProject]
    public var chaos: [ChaosItem]
    public var isEmpty: Bool { tasks.isEmpty && projects.isEmpty && chaos.isEmpty }

    public init(tasks: [DayPlan] = [], projects: [DiaryProject] = [], chaos: [ChaosItem] = []) {
        self.tasks = tasks
        self.projects = projects
        self.chaos = chaos
    }
}

public extension DiaryStore {
    var hasOrganizerData: Bool { !projects.isEmpty || !chaos.isEmpty || plans.contains { $0.organization != nil || $0.steps != nil } }

    func organizerMarkdown(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "yyyy-MM-dd"
        func quoted(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        }
        var output = "## Органайзер\n\nВременная зона: \(calendar.timeZone.identifier)\n"
        for project in projects.sorted(by: { $0.createdAt < $1.createdAt }) {
            output += "\n### Проект\n\n" + quoted(project.title) + "\n\n"
            output += "Сфера: \(project.area.title). Состояние: \(project.archived ? "завершён" : "активен").\n\nРезультат:\n" + quoted(project.outcome) + "\n"
            if !project.uncertainty.isEmpty { output += "\nНужно выяснить:\n" + quoted(project.uncertainty) + "\n" }
            if let review = project.reviewDate { output += "\nПересмотреть: \(formatter.string(from: review)).\n" }
            if let next = plans.first(where: { $0.id == project.nextActionID }) { output += "\nСледующий шаг:\n" + quoted(next.text) + "\n" }
        }
        if !chaos.isEmpty {
            output += "\n### Место хаоса\n"
            for item in sortedChaos() {
                output += "\n" + quoted(item.text) + "\n"
                if item.urgent { output += "\nНе может ждать.\n" }
            }
        }
        output += "\n### Задачи\n"
        for task in Self.sortedPlans(plans) {
            output += "\n" + quoted(task.text) + "\n\n"
            output += "Сфера: \(task.taskArea.title). Состояние: \(task.isCompleted ? "выполнено" : task.taskStatus.title).\n"
            if !task.taskSteps.isEmpty {
                output += "\nШаги задачи (ID: \(task.id.uuidString)):\n"
                for (index, step) in task.taskSteps.enumerated() {
                    output += "\n\(index + 1). [\(step.isCompleted ? "x" : " ")] ID: \(step.id.uuidString)\n" + quoted(step.text) + "\n"
                }
            }
            if let project = projects.first(where: { $0.id == task.projectID }) { output += "\nПроект:\n" + quoted(project.title) + "\n" }
            if !task.day.isEmpty { output += "\nДень работы:\n" + quoted(task.day) + "\n" }
            if let deadline = task.organization?.deadline { output += "\nСрок результата: \(formatter.string(from: deadline)).\n" }
            if let review = task.organization?.reviewDate { output += "\nПересмотреть: \(formatter.string(from: review)).\n" }
            if let who = task.organization?.waitingFor { output += "\nОжидаю:\n" + quoted(who) + "\n" }
            if let promised = task.organization?.promisedTo { output += "\nКому обещано:\n" + quoted(promised) + "\n" }
            if task.isAtRisk { output += "\nОбещание под угрозой.\n" }
            if let reason = task.organization?.removalReason { output += "\nПричина снятия:\n" + quoted(reason) + "\n" }
            if let details = task.organization?.details { output += "\nПодробности:\n" + quoted(details) + "\n" }
        }
        return output
    }

    @discardableResult
    func addTask(text: String, plannedDay: Date? = nil, organization: TaskOrganization,
                 calendar: Calendar = .current, now: Date = Date()) throws -> DayPlan {
        let title = Self.cleanText(text)
        guard !title.isEmpty else { throw DiaryError.emptyText }
        let metadata = try checkedOrganization(organization, calendar: calendar)
        let stamp = diaryNormalized(now)
        var task = DayPlan(text: title, day: plannedDay.map { DiaryDay.key($0, calendar: calendar) } ?? "",
                           createdAt: stamp, updatedAt: stamp)
        task.organization = metadata
        try persist(entries: entries, plans: plans + [task], notes: notes, projects: projects)
        return task
    }

    @discardableResult
    func updateTask(id: UUID, text: String, plannedDay: Date?, organization: TaskOrganization,
                    calendar: Calendar = .current, now: Date = Date()) throws -> DayPlan {
        let title = Self.cleanText(text)
        guard !title.isEmpty else { throw DiaryError.emptyText }
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        guard !plans[index].isCompleted else { throw DiaryError.planIsCompleted }
        guard !plans[index].isRemoved else { throw DiaryError.taskIsRemoved }
        var copy = plans
        copy[index].text = title
        copy[index].day = plannedDay.map { DiaryDay.key($0, calendar: calendar) } ?? ""
        copy[index].organization = try checkedOrganization(organization, calendar: calendar)
        copy[index].updatedAt = diaryNormalized(now)
        try persist(entries: entries, plans: copy, notes: notes, projects: projects)
        return copy[index]
    }

    /// «Снять…»: причина обязательна. Снятие не считается выполнением и не пишет дневник.
    @discardableResult
    func setTaskRemoved(id: UUID, reason: String, now: Date = Date()) throws -> DayPlan {
        let text = Self.cleanText(reason)
        guard !text.isEmpty else { throw DiaryError.emptyRemovalReason }
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        guard !plans[index].isCompleted else { throw DiaryError.planIsCompleted }
        var copy = plans
        var metadata = copy[index].organization ?? TaskOrganization()
        metadata.status = .removed
        metadata.removalReason = text
        copy[index].organization = metadata
        copy[index].updatedAt = diaryNormalized(now)
        let updated = copy[index]
        try persist(entries: entries, plans: copy, notes: notes, projects: projects)
        return updated
    }

    /// «Вернуть в работу»: статус снова «Можно делать», прежняя причина стирается,
    /// чтобы старая причина не выглядела текущей. Шаги и остальные поля сохраняются.
    @discardableResult
    func returnTaskToWork(id: UUID, now: Date = Date()) throws -> DayPlan {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        guard plans[index].isRemoved else { throw DiaryError.taskIsNotRemoved }
        var copy = plans
        var metadata = copy[index].organization ?? TaskOrganization()
        metadata.status = .ready
        metadata.removalReason = nil
        copy[index].organization = metadata
        copy[index].updatedAt = diaryNormalized(now)
        let updated = copy[index]
        try persist(entries: entries, plans: copy, notes: notes, projects: projects)
        return updated
    }

    /// Отметка «Обещание под угрозой». Ставит и снимает только человек: статус, даты
    /// и порядок остальных дел не меняются, уведомлений нет.
    @discardableResult
    func setTaskAtRisk(id: UUID, _ atRisk: Bool, now: Date = Date()) throws -> DayPlan {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        guard !plans[index].isCompleted else { throw DiaryError.planIsCompleted }
        guard !plans[index].isRemoved else { throw DiaryError.taskIsRemoved }
        var copy = plans
        var metadata = copy[index].organization ?? TaskOrganization()
        metadata.atRisk = atRisk
        copy[index].organization = metadata
        copy[index].updatedAt = diaryNormalized(now)
        let updated = copy[index]
        try persist(entries: entries, plans: copy, notes: notes, projects: projects)
        return updated
    }

    @discardableResult
    func saveProject(id: UUID? = nil, title: String, outcome: String, area: TaskArea,
                     uncertainty: String, reviewDate: Date?, calendar: Calendar = .current,
                     now: Date = Date()) throws -> DiaryProject {
        let name = Self.cleanText(title)
        let result = Self.cleanText(outcome)
        guard !name.isEmpty, !result.isEmpty else { throw DiaryError.emptyText }
        var copy = projects
        var project: DiaryProject
        if let id {
            guard let existing = projects.first(where: { $0.id == id }) else { throw DiaryError.notFound }
            project = existing
        } else {
            project = DiaryProject(title: name, outcome: result, area: area,
                                   createdAt: diaryNormalized(now), updatedAt: diaryNormalized(now))
        }
        project.title = name
        project.outcome = result
        project.area = area
        project.uncertainty = Self.cleanText(uncertainty)
        project.reviewDate = reviewDate.map { calendar.startOfDay(for: $0) }
        project.updatedAt = diaryNormalized(now)
        copy.removeAll { $0.id == project.id }
        copy.append(project)
        var tasks = plans
        for index in tasks.indices where tasks[index].projectID == project.id {
            tasks[index].organization?.area = area
        }
        try persist(entries: entries, plans: tasks, notes: notes, projects: copy)
        return project
    }

    func setNextAction(projectID: UUID, taskID: UUID?, now: Date = Date()) throws {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw DiaryError.notFound }
        if let taskID {
            guard let task = plans.first(where: { $0.id == taskID }), task.projectID == projectID,
                  !task.isCompleted, task.taskStatus == .ready else {
                throw DiaryError.unsupportedFormat("следующим шагом может быть открытая задача этого проекта со статусом «Можно делать»")
            }
        }
        var copy = projects
        copy[index].nextActionID = taskID
        copy[index].updatedAt = diaryNormalized(now)
        try persist(entries: entries, plans: plans, notes: notes, projects: copy)
    }

    func setProjectArchived(id: UUID, archived: Bool, now: Date = Date()) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        // Снятая задача закрыта так же, как выполненная: проект она не держит.
        if archived, plans.contains(where: { $0.projectID == id && $0.isOpen }) {
            throw DiaryError.unsupportedFormat("сначала завершите или перенесите открытые задачи проекта")
        }
        var copy = projects
        copy[index].archived = archived
        copy[index].updatedAt = diaryNormalized(now)
        try persist(entries: entries, plans: plans, notes: notes, projects: copy)
    }

    func deleteProject(id: UUID) throws {
        guard projects.contains(where: { $0.id == id }) else { throw DiaryError.notFound }
        var tasks = plans
        for index in tasks.indices where tasks[index].projectID == id {
            tasks[index].organization?.projectID = nil
        }
        try persist(entries: entries, plans: tasks, notes: notes, projects: projects.filter { $0.id != id })
    }

    private func checkedOrganization(_ value: TaskOrganization, calendar: Calendar) throws -> TaskOrganization {
        var copy = value
        if let id = copy.projectID {
            guard let project = projects.first(where: { $0.id == id }), !project.archived else { throw DiaryError.notFound }
            copy.area = project.area
        }
        copy.waitingFor = Self.cleanContext(copy.waitingFor)
        copy.promisedTo = Self.cleanContext(copy.promisedTo)
        copy.details = Self.cleanContext(copy.details)
        // Причина живёт только вместе со статусом «Снято», иначе она выглядела бы текущей.
        copy.removalReason = copy.status == .removed ? Self.cleanContext(copy.removalReason) : nil
        copy.reviewDate = copy.reviewDate.map { calendar.startOfDay(for: $0) }
        copy.deadline = copy.deadline.map { calendar.startOfDay(for: $0) }
        return copy
    }

    func sortedChaos() -> [ChaosItem] {
        chaos.sorted { a, b in
            if a.urgent != b.urgent { return a.urgent && !b.urgent }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    @discardableResult
    func addChaosItem(text: String, urgent: Bool = false, now: Date = Date()) throws -> ChaosItem {
        let title = Self.cleanText(text)
        guard !title.isEmpty else { throw DiaryError.emptyText }
        let item = ChaosItem(text: title, createdAt: diaryNormalized(now), urgent: urgent)
        try persist(entries: entries, plans: plans, notes: notes, chaos: chaos + [item])
        return item
    }

    @discardableResult
    func setChaosUrgent(id: UUID, _ urgent: Bool) throws -> ChaosItem {
        guard let index = chaos.firstIndex(where: { $0.id == id }) else { throw DiaryError.notFound }
        var copy = chaos
        copy[index].urgent = urgent
        let updated = copy[index]
        try persist(entries: entries, plans: plans, notes: notes, chaos: copy)
        return updated
    }

    @discardableResult
    func deleteChaosItem(id: UUID) throws -> ChaosItem {
        guard let item = chaos.first(where: { $0.id == id }) else { throw DiaryError.notFound }
        try persist(entries: entries, plans: plans, notes: notes, chaos: chaos.filter { $0.id != id })
        return item
    }

    func restoreChaosItem(_ item: ChaosItem) throws {
        guard !chaos.contains(where: { $0.id == item.id }) else { return }
        try persist(entries: entries, plans: plans, notes: notes, chaos: chaos + [item])
    }

    /// Решение «это задача» через редактор. Строка уходит из корзины только вместе с
    /// успешно сохранённой задачей, одним persist: отмена и ошибка оставляют её с тем же id.
    /// Срочная строка даёт отметку «Обещание под угрозой»; даты приложение не выдумывает.
    @discardableResult
    func makeTask(fromChaos id: UUID, text: String, plannedDay: Date? = nil,
                  organization: TaskOrganization, calendar: Calendar = .current,
                  now: Date = Date()) throws -> DayPlan {
        guard let item = chaos.first(where: { $0.id == id }) else { throw DiaryError.notFound }
        let title = Self.cleanText(text)
        guard !title.isEmpty else { throw DiaryError.emptyText }
        var metadata = try checkedOrganization(organization, calendar: calendar)
        if item.urgent { metadata.atRisk = true }
        let stamp = diaryNormalized(now)
        var task = DayPlan(text: title, day: plannedDay.map { DiaryDay.key($0, calendar: calendar) } ?? "",
                           createdAt: stamp, updatedAt: stamp)
        task.organization = metadata
        try persist(entries: entries, plans: plans + [task], notes: notes, chaos: chaos.filter { $0.id != id })
        return task
    }

    /// Решение «это заметка». Дневник не меняется.
    @discardableResult
    func makeNote(fromChaos id: UUID, now: Date = Date()) throws -> DiaryNote {
        guard let item = chaos.first(where: { $0.id == id }) else { throw DiaryError.notFound }
        let stamp = diaryNormalized(now)
        let firstLine = item.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? item.text
        let note = DiaryNote(title: DiaryStore.cleanTitle(firstLine), body: item.text, createdAt: stamp, updatedAt: stamp)
        try persist(entries: entries, plans: plans, notes: notes + [note], chaos: chaos.filter { $0.id != id })
        return note
    }

    // MARK: Выборки пересмотра

    /// Статусы, при которых отметка «Обещание под угрозой» возвращает дело в выборки.
    static let atRiskStatuses: Set<TaskStatus> = [.ready, .waiting, .paused]

    /// Каноничный порядок задач: день, затем время создания, затем id.
    static func planOrder(_ a: DayPlan, _ b: DayPlan) -> Bool {
        if a.day != b.day { return a.day < b.day }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    static func reviewDateOrder(_ a: DayPlan, _ b: DayPlan) -> Bool {
        let left = a.organization?.reviewDate
        let right = b.organization?.reviewDate
        if left != right { return (left ?? .distantFuture) < (right ?? .distantFuture) }
        return planOrder(a, b)
    }

    /// Задачи, которые участвуют в выборках: не выполнены и не сняты.
    var openTasks: [DayPlan] { plans.filter(\.isOpen) }

    /// «Сегодня»: назначенные на сегодня и оставшиеся с прошлых дней, с наступившим сроком
    /// результата и отмеченные «Обещание под угрозой». Отложенное дело видно только с отметкой.
    func tasksForToday(now: Date = Date(), calendar: Calendar = .current) -> [DayPlan] {
        let todayKey = DiaryDay.key(now, calendar: calendar)
        let startOfToday = calendar.startOfDay(for: now)
        return Self.sortedPlans(openTasks.filter { task in
            if task.isAtRisk, Self.atRiskStatuses.contains(task.taskStatus) { return true }
            guard task.taskStatus != .paused else { return false }
            if !task.day.isEmpty, task.day <= todayKey { return true }
            guard let deadline = task.organization?.deadline else { return false }
            return calendar.startOfDay(for: deadline) <= startOfToday
        })
    }

    /// Выборка угрозы. Отметку ставит и снимает только человек: приложение её не вычисляет,
    /// не меняет статус и даты и не ранжирует остальные дела.
    func tasksAtRisk() -> [DayPlan] {
        Self.sortedPlans(openTasks.filter { $0.isAtRisk && Self.atRiskStatuses.contains($0.taskStatus) })
    }

    /// «Ожидаю»: открытые задачи в статусе ожидания.
    func waitingTasks() -> [DayPlan] {
        Self.sortedPlans(openTasks.filter { $0.taskStatus == .waiting })
    }

    /// «Все задачи»: снятые и выполненные скрыты, пока человек не включит их показ.
    func visibleTasks(showCompleted: Bool = false, showRemoved: Bool = false) -> [DayPlan] {
        plans.filter { task in
            (showCompleted || !task.isCompleted) && (showRemoved || !task.isRemoved)
        }
    }

    /// Порядок пересмотра: шесть групп, дело попадает только в первую подходящую.
    /// Выполненные задачи, снятые задачи и архивные проекты исключены.
    func reviewGroups(now: Date = Date(), calendar: Calendar = .current) -> [ReviewGroup] {
        let open = Self.sortedPlans(openTasks)
        let startOfToday = calendar.startOfDay(for: now)
        let todayKey = DiaryDay.key(now, calendar: calendar)
        func isDue(_ date: Date?) -> Bool {
            guard let date else { return false }
            return calendar.startOfDay(for: date) <= startOfToday
        }
        var placed = Set<UUID>()
        var groups: [ReviewGroup] = []
        func take(_ list: [DayPlan]) -> [ReviewItem] {
            let fresh = list.filter { !placed.contains($0.id) }
            fresh.forEach { placed.insert($0.id) }
            return fresh.map { ReviewItem.task($0) }
        }
        func append(_ title: String, _ items: [ReviewItem]) {
            groups.append(ReviewGroup(title: title, items: items))
        }

        // 1. Обещания со сроком: ближайшие раньше.
        let promised = open.filter { !($0.promisedTo ?? "").isEmpty }
        let withDeadline = promised.filter { $0.organization?.deadline != nil }.sorted { a, b in
            let left = a.organization?.deadline ?? .distantFuture
            let right = b.organization?.deadline ?? .distantFuture
            return left != right ? left < right : Self.planOrder(a, b)
        }
        append("Обещания со сроком", take(withDeadline))

        // 2. Обещания без срока: дату не выдумываем.
        append("Обещания без срока", take(promised.filter { $0.organization?.deadline == nil }))

        // 3. Остальные дела под угрозой.
        append("Под угрозой", take(open.filter { $0.isAtRisk && Self.atRiskStatuses.contains($0.taskStatus) }))

        // 4. Дела на сегодня и следующий шаг проектов.
        let scheduled = open.filter { $0.taskStatus != .paused && !$0.day.isEmpty && $0.day <= todayKey }
        let nextStepIDs = Set(projects.filter { !$0.archived }.compactMap(\.nextActionID))
        append("Сегодня и следующие шаги", take(scheduled) + take(open.filter { nextStepIDs.contains($0.id) }))

        // 5. Ожидания с названным условием продолжения.
        let waiting = open.filter { $0.taskStatus == .waiting && !($0.organization?.waitingFor ?? "").isEmpty }
        append("Ожидания", take(waiting.sorted(by: Self.reviewDateOrder)))

        // 6. Наступившая дата пересмотра и проекты без следующего шага.
        let dueReview = open.filter { isDue($0.organization?.reviewDate) }.sorted(by: Self.reviewDateOrder)
        let dueProjects = projects.filter { !$0.archived && ($0.nextActionID == nil || isDue($0.reviewDate)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { ReviewItem.project($0) }
        append("Пересмотр", take(dueReview) + dueProjects)
        return groups
    }

    /// Один поиск по делам: открытые задачи (текст, подробности, ожидание, адресат обещания),
    /// неархивные проекты (название, результат, неопределённость) и строки места хаоса.
    /// Выполненные и снятые задачи попадают в выдачу только по явному переключателю.
    func searchOrganizer(_ query: String, includeCompleted: Bool = false,
                         includeRemoved: Bool = false) -> OrganizerSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return OrganizerSearchResults() }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func hits(_ text: String?) -> Bool {
            guard let text, !text.isEmpty else { return false }
            return text.range(of: q, options: options, locale: DiaryFormat.ru) != nil
        }
        let tasks = Self.sortedPlans(plans.filter { task in
            guard includeCompleted || !task.isCompleted else { return false }
            guard includeRemoved || !task.isRemoved else { return false }
            return hits(task.text) || hits(task.organization?.details)
                || hits(task.organization?.waitingFor) || hits(task.organization?.promisedTo)
        })
        let foundProjects = projects.filter { project in
            !project.archived
                && (hits(project.title) || hits(project.outcome) || hits(project.uncertainty))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return OrganizerSearchResults(tasks: tasks, projects: foundProjects, chaos: sortedChaos().filter { hits($0.text) })
    }
}

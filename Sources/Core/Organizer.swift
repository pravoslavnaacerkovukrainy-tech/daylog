import Foundation

public enum TaskArea: String, Codable, CaseIterable, Identifiable {
    case work, personal
    public var id: String { rawValue }
    public var title: String { self == .work ? "Работа" : "Личное" }
}

public enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case inbox, ready, waiting, paused
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .inbox: return "Входящие"
        case .ready: return "Можно делать"
        case .waiting: return "Ожидаю"
        case .paused: return "Отложено"
        }
    }
}

/// Дополнительные поля задачи. Отсутствие блока в старом плане означает обычную личную задачу.
public struct TaskOrganization: Codable, Equatable, Hashable {
    public var area: TaskArea
    public var projectID: UUID?
    public var status: TaskStatus
    public var waitingFor: String?
    public var reviewDate: Date?
    public var deadline: Date?
    public var details: String?

    public init(area: TaskArea = .personal, projectID: UUID? = nil, status: TaskStatus = .ready,
                waitingFor: String? = nil, reviewDate: Date? = nil, deadline: Date? = nil, details: String? = nil) {
        self.area = area
        self.projectID = projectID
        self.status = status
        self.waitingFor = waitingFor
        self.reviewDate = reviewDate
        self.deadline = deadline
        self.details = details
    }
}

public extension DayPlan {
    var taskArea: TaskArea { organization?.area ?? .personal }
    var taskStatus: TaskStatus { organization?.status ?? .ready }
    var projectID: UUID? { organization?.projectID }
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

public extension DiaryStore {
    var hasOrganizerData: Bool { !projects.isEmpty || plans.contains { $0.organization != nil } }

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
        output += "\n### Задачи\n"
        for task in Self.sortedPlans(plans) {
            output += "\n" + quoted(task.text) + "\n\n"
            output += "Сфера: \(task.taskArea.title). Состояние: \(task.isCompleted ? "выполнено" : task.taskStatus.title).\n"
            if let project = projects.first(where: { $0.id == task.projectID }) { output += "\nПроект:\n" + quoted(project.title) + "\n" }
            if !task.day.isEmpty { output += "\nДень работы:\n" + quoted(task.day) + "\n" }
            if let deadline = task.organization?.deadline { output += "\nСрок результата: \(formatter.string(from: deadline)).\n" }
            if let review = task.organization?.reviewDate { output += "\nПересмотреть: \(formatter.string(from: review)).\n" }
            if let who = task.organization?.waitingFor { output += "\nОжидаю:\n" + quoted(who) + "\n" }
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
        var copy = plans
        copy[index].text = title
        copy[index].day = plannedDay.map { DiaryDay.key($0, calendar: calendar) } ?? ""
        copy[index].organization = try checkedOrganization(organization, calendar: calendar)
        copy[index].updatedAt = diaryNormalized(now)
        try persist(entries: entries, plans: copy, notes: notes, projects: projects)
        return copy[index]
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
        if archived, plans.contains(where: { $0.projectID == id && !$0.isCompleted }) {
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
        copy.details = Self.cleanContext(copy.details)
        copy.reviewDate = copy.reviewDate.map { calendar.startOfDay(for: $0) }
        copy.deadline = copy.deadline.map { calendar.startOfDay(for: $0) }
        return copy
    }
}

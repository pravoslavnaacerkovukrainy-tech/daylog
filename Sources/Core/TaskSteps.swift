import Foundation

/// Шаг является частью результата одной задачи, без собственных дат и связей с дневником.
public struct TaskStep: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var completedAt: Date?
    public var isCompleted: Bool { completedAt != nil }

    public init(id: UUID = UUID(), text: String, completedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.completedAt = completedAt.map(diaryNormalized)
    }
}

public enum TaskStepsError: Error, LocalizedError, Equatable {
    case invalidList
    case parentHasSteps
    case changedParent

    public var errorDescription: String? {
        switch self {
        case .invalidList: return "Нужны непустые шаги до 500 знаков, не более 100 шагов, без повторов."
        case .parentHasSteps: return "У задачи есть шаги. Сначала явно удалите их в редакторе шагов и сохраните список. Для выполненной или снятой задачи сначала верните её в работу."
        case .changedParent: return "Задача или её шаги изменились. Черновик сохранён. Нажмите «Загрузить заново» и проверьте предложение перед добавлением."
        }
    }
}

public extension DayPlan {
    var taskSteps: [TaskStep] { steps ?? [] }
    var nextStep: TaskStep? { taskSteps.first { !$0.isCompleted } }
}

public extension DiaryStore {
    /// Весь список сохраняется одним persist. Ожидается полный снимок родителя,
    /// чтобы ответ ИИ не применялся к уже изменённому заданию.
    @discardableResult
    func replaceTaskSteps(parent: DayPlan, steps: [TaskStep], now: Date = Date()) throws -> DayPlan {
        guard let index = plans.firstIndex(where: { $0.id == parent.id }) else { throw DiaryError.notFound }
        guard plans[index] == parent else { throw TaskStepsError.changedParent }
        guard !parent.isCompleted else { throw DiaryError.planIsCompleted }
        let checked = try Self.checkedSteps(steps)
        var copy = plans
        copy[index].steps = checked
        copy[index].updatedAt = diaryNormalized(now)
        try persist(entries: entries, plans: copy, notes: notes)
        return copy[index]
    }

    /// Устойчивые ID делают повторное утверждение того же предложения идемпотентным.
    /// Частичное совпадение или изменённое содержимое не скрывают конфликт.
    @discardableResult
    func appendTaskSteps(parent: DayPlan, proposal: [TaskStep], now: Date = Date()) throws -> DayPlan {
        let checked = try Self.checkedSteps(proposal)
        guard !checked.isEmpty else { throw TaskStepsError.invalidList }
        guard let current = plans.first(where: { $0.id == parent.id }) else { throw DiaryError.notFound }
        let ids = Set(checked.map(\.id))
        let existing = current.taskSteps.filter { ids.contains($0.id) }
        if existing == checked { return current }
        guard existing.isEmpty else { throw TaskStepsError.changedParent }
        return try replaceTaskSteps(parent: parent, steps: parent.taskSteps + checked, now: now)
    }

    private static func checkedSteps(_ steps: [TaskStep]) throws -> [TaskStep] {
        var result = steps
        for index in result.indices {
            result[index].text = cleanText(result[index].text)
            result[index].completedAt = result[index].completedAt.map(diaryNormalized)
        }
        let names = result.map { $0.text.folding(options: [.caseInsensitive], locale: Locale(identifier: "ru_RU")) }
        guard result.count <= 100, Set(result.map(\.id)).count == result.count,
              Set(names).count == names.count,
              result.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 500 }) else { throw TaskStepsError.invalidList }
        return result
    }
}

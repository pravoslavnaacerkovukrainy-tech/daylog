import Foundation
import Combine
import SwiftUI

/// Черновик шагов одной задачи. Живёт до выхода из приложения.
@MainActor
final class TaskBreakdownDraft: ObservableObject {
    @Published var parent: DayPlan
    @Published private(set) var observedParent: DayPlan
    @Published var savedSteps: [TaskStep]
    @Published var error: String?
    @Published var notice: String?

    init(parent: DayPlan) {
        self.parent = parent
        self.observedParent = parent
        self.savedSteps = parent.taskSteps
    }

    var hasSavedEdits: Bool { savedSteps != parent.taskSteps }

    /// Если список шагов на диске тот же, обновляет снимок родителя и оставляет ручные правки.
    /// Смена названия или подробностей тогда не мешает сохранению. Изменившийся список
    /// не затирается: правки остаются до «Загрузить заново».
    func reopen(parent current: DayPlan) {
        if observedParent != current { observedParent = current }
        guard parent != current else { return }
        if !hasSavedEdits || savedSteps == current.taskSteps {
            parent = current
            savedSteps = current.taskSteps
            error = nil
            return
        }
        if parent.taskSteps == current.taskSteps {
            parent = current
            error = nil
            return
        }
        error = TaskStepsError.changedParent.localizedDescription
    }

    /// Только после явного подтверждения сброса правок сохранённого списка.
    func reloadSavedSteps(parent current: DayPlan) {
        observedParent = current
        parent = current
        savedSteps = current.taskSteps
        error = nil
    }

    func addStep() {
        savedSteps.append(TaskStep(text: ""))
    }

    func stepTextBinding(id: UUID) -> Binding<String> {
        Binding(get: { self.savedSteps.first { $0.id == id }?.text ?? "" }, set: { value in
            self.changeStep(id: id) { $0.text = value }
        })
    }

    private func changeStep(id: UUID, change: (inout TaskStep) -> Void) {
        guard let index = savedSteps.firstIndex(where: { $0.id == id }) else { return }
        var rows = savedSteps
        change(&rows[index])
        savedSteps = rows
    }

    func toggleStep(id: UUID) {
        changeStep(id: id) { $0.completedAt = $0.isCompleted ? nil : diaryNormalized(Date()) }
    }

    func moveStep(id: UUID, offset: Int) {
        guard let index = savedSteps.firstIndex(where: { $0.id == id }),
              [-1, 1].contains(offset), savedSteps.indices.contains(index + offset) else { return }
        var rows = savedSteps
        rows.swapAt(index, index + offset)
        savedSteps = rows
    }

    func removeStep(id: UUID) {
        savedSteps.removeAll { $0.id == id }
    }
}

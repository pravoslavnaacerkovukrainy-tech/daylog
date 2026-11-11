import SwiftUI

struct TaskBreakdownView: View {
    @ObservedObject var state: AppState
    @ObservedObject var draft: TaskBreakdownDraft
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReload = false

    private var locked: Bool { state.isBlocked || draft.observedParent.isCompleted }
    private var current: DayPlan? { state.plans.first { $0.id == draft.parent.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Разбить на шаги").font(Theme.title)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            if draft.hasSavedEdits {
                HStack(spacing: 12) {
                    Text("Правки и отметки выполнения ещё не сохранены.")
                        .font(Theme.caption).foregroundStyle(Theme.quiet)
                    Spacer()
                    Button("Сохранить шаги", action: saveSteps).disabled(locked)
                }.padding(.horizontal, 24).padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(draft.observedParent.text).font(Theme.groupTitle).textSelection(.enabled)
                    Text("Шаги относятся к этой задаче и вводятся вручную. Их выполнение не завершает задачу и не создаёт записи дневника. Результат подтверждаете вы.")
                        .font(Theme.text).foregroundStyle(Theme.quiet)
                    if draft.observedParent.isCompleted {
                        Text("Задача выполнена. Для изменения шагов сначала верните её в работу.").foregroundStyle(Theme.quiet)
                    }
                    savedSection
                    if let error = draft.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let notice = draft.notice { Text(notice).foregroundStyle(Theme.quiet).textSelection(.enabled) }
                }.padding(24)
            }
        }.frame(width: 680, height: 640)
            .tint(Theme.accent)
            .confirmationDialog("Загрузить сохранённые шаги заново?", isPresented: $confirmReload) {
                Button("Загрузить") {
                    let ok = state.changeOrganizer("Данные перечитаны") { try state.store.load() }
                    if ok, let current { draft.reloadSavedSteps(parent: current) }
                    else { draft.error = state.errorMessage ?? "Исходная задача удалена. Несохранённые правки шагов остаются в этом окне." }
                }
            } message: { Text("Несохранённые правки шагов в этом окне будут сброшены.") }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сохранённые шаги").font(Theme.groupTitle)
            if draft.savedSteps.isEmpty { Text("Пока нет. Добавьте шаг вручную ниже.").foregroundStyle(Theme.quiet) }
            stepRows
            HStack {
                Button("Добавить шаг") { draft.addStep() }.disabled(locked)
                Button("Сохранить правки шагов", action: saveSteps).disabled(locked || !draft.hasSavedEdits)
                Spacer()
                Button("Загрузить заново") { confirmReload = true }.disabled(current == nil)
            }
            Text("Текст, порядок, удаление и отметки выполнения применятся только после сохранения правок. Несохранённые правки не восстанавливаются после выхода из приложения.")
                .font(Theme.caption).foregroundStyle(Theme.quiet)
        }
    }

    private var stepRows: some View {
        ForEach(Array(draft.savedSteps.enumerated()), id: \.element.id) { index, step in
            HStack(alignment: .top, spacing: 8) {
                Button {
                    draft.toggleStep(id: step.id)
                } label: { Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle").compactHitArea() }
                    .buttonStyle(.plain).disabled(locked)
                    .accessibilityLabel(step.isCompleted ? "Вернуть шаг в работу" : "Отметить шаг выполненным")
                VStack(alignment: .leading, spacing: 3) {
                    if !step.isCompleted, draft.savedSteps.first(where: { !$0.isCompleted })?.id == step.id {
                        Text("Следующий шаг").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    TextField("Шаг \(index + 1)", text: draft.stepTextBinding(id: step.id), axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder)
                        .strikethrough(step.isCompleted).disabled(locked)
                }
                // Области 28×28 стоят вплотную без перекрытия; клик между строками не попадает в кнопку.
                VStack(spacing: 0) {
                    Button { draft.moveStep(id: step.id, offset: -1) } label: { Image(systemName: "arrow.up").compactHitArea() }
                        .disabled(locked || index == 0).accessibilityLabel("Переместить шаг выше")
                    Button { draft.moveStep(id: step.id, offset: 1) } label: { Image(systemName: "arrow.down").compactHitArea() }
                        .disabled(locked || index == draft.savedSteps.count - 1).accessibilityLabel("Переместить шаг ниже")
                }.buttonStyle(.borderless)
                Button(role: .destructive) { draft.removeStep(id: step.id) } label: { Image(systemName: "trash").compactHitArea() }
                    .buttonStyle(.borderless).disabled(locked).accessibilityLabel("Удалить шаг")
            }
        }
    }

    private func saveSteps() {
        apply("Правки шагов сохранены") { try state.store.replaceTaskSteps(parent: draft.parent, steps: draft.savedSteps) }
    }

    @discardableResult private func apply(_ message: String, change: () throws -> DayPlan) -> Bool {
        var result: DayPlan?
        let ok = state.changeOrganizer(message) { result = try change() }
        if let result, ok {
            draft.reloadSavedSteps(parent: result)
            draft.notice = message
        } else { draft.error = state.errorMessage }
        return ok
    }
}

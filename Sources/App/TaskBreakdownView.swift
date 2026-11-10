import SwiftUI

struct TaskBreakdownView: View {
    @ObservedObject var state: AppState
    @ObservedObject var draft: TaskBreakdownDraft
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRegenerate = false
    @State private var confirmClear = false
    @State private var confirmReload = false
    @State private var confirmReview = false
    @State private var confirmDiscardContext = false

    private var locked: Bool { state.isBlocked || draft.observedParent.isCompleted || draft.busy }
    private var current: DayPlan? { state.plans.first { $0.id == draft.parent.id } }
    private var canRequest: Bool { (try? TaskBreakdown.requestBody(input: draft.input)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Разбить на шаги").font(.title2.weight(.semibold))
                Spacer()
                Button("Закрыть") { draft.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            if draft.hasSavedEdits {
                HStack(spacing: 12) {
                    Text("Правки и отметки выполнения ещё не сохранены.")
                        .font(.caption).foregroundStyle(Theme.quiet)
                    Spacer()
                    Button("Сохранить шаги", action: saveSteps).disabled(locked)
                }.padding(.horizontal, 24).padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(draft.currentContext.title).font(.headline).textSelection(.enabled)
                    Text("Шаги относятся к этой задаче. Их выполнение не завершает задачу и не создаёт записи дневника. Результат подтверждаете вы.")
                        .font(.callout).foregroundStyle(Theme.quiet)
                    if draft.observedParent.isCompleted {
                        Text("Задача выполнена. Для изменения шагов сначала верните её в работу.").foregroundStyle(Theme.quiet)
                    }
                    if draft.isContextStale { staleContextSection }
                    savedSection
                    Divider()
                    proposalSection
                    Divider()
                    aiSection
                    if let error = draft.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let notice = draft.notice { Text(notice).foregroundStyle(Theme.quiet).textSelection(.enabled) }
                }.padding(24)
            }
        }.frame(width: 680, height: 640)
            .tint(Theme.accent)
            .interactiveDismissDisabled(draft.busy)
            .onDisappear { draft.cancel() }
            .confirmationDialog("Использовать черновик с изменённой задачей?", isPresented: $confirmReview) {
                Button("Я сверил шаги, вопросы и ответы с текущей задачей") { draft.confirmContextReview() }
            } message: { Text("Подтвердите пересмотр предложения и всех уточнений. После этого их можно будет добавлять или отправлять с показанными текущими названием и подробностями.") }
            .confirmationDialog("Удалить прежний черновик и начать новый?", isPresented: $confirmDiscardContext) {
                Button("Удалить предложение, вопросы, ответы и уточнения", role: .destructive) { draft.discardContextDraft() }
            } message: { Text("Сохранённые шаги останутся. Новый запрос выполняется только отдельным нажатием после проверки отправляемых данных.") }
            .confirmationDialog("Заменить только черновик предложения новым ответом?", isPresented: $confirmRegenerate) {
                Button("Запросить новый вариант") { draft.generate() }
            } message: { Text("Сохранённые шаги останутся. При ошибке или отмене текущий черновик предложения сохранится.") }
            .confirmationDialog("Удалить черновик предложения?", isPresented: $confirmClear) {
                Button("Удалить черновик", role: .destructive) { draft.proposal = [] }
            }
            .confirmationDialog("Загрузить сохранённые шаги заново?", isPresented: $confirmReload) {
                Button("Загрузить") {
                    let ok = state.changeOrganizer("Данные перечитаны") { try state.store.load() }
                    if ok, let current { draft.reloadSavedSteps(parent: current) }
                    else { draft.error = state.errorMessage ?? "Исходная задача удалена. Черновик предложения сохранён." }
                }
            } message: { Text("Правки списка сохранённых шагов в этом окне будут сброшены. Предложение и уточнения останутся.") }
    }

    private var staleContextSection: some View {
        GroupBox("Черновик относится к прежней задаче") {
            VStack(alignment: .leading, spacing: 10) {
                Text(BreakdownDraftError.staleContext.localizedDescription).foregroundStyle(.red)
                Text("Прежнее название: \(draft.sourceContext.title)")
                Text("Прежние подробности: \(draft.sourceContext.details.isEmpty ? "не указаны" : draft.sourceContext.details)")
                Text("Текущее название: \(draft.currentContext.title)")
                Text("Текущие подробности: \(draft.currentContext.details.isEmpty ? "не указаны" : draft.currentContext.details)")
                Text("Старые шаги, вопросы и уточнения сохранены ниже для сверки. Добавление и новые запросы заблокированы до вашего решения.")
                    .font(.callout).foregroundStyle(Theme.quiet)
                Button("Я пересмотрел черновик для текущей задачи") { confirmReview = true }.disabled(locked)
                Button("Удалить прежний черновик и начать новый") { confirmDiscardContext = true }.disabled(locked)
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сохранённые шаги").font(.headline)
            if draft.savedSteps.isEmpty { Text("Пока нет. Можно ввести вручную ниже или попросить QwenCloud.").foregroundStyle(Theme.quiet) }
            stepRows(.saved, completion: true)
            HStack {
                Button("Добавить шаг в черновик") { draft.proposal.append(TaskStep(text: "")) }.disabled(locked)
                Button("Сохранить правки шагов", action: saveSteps).disabled(locked || !draft.hasSavedEdits)
                Spacer()
                Button("Загрузить заново") { confirmReload = true }.disabled(draft.busy || current == nil)
            }
            Text("Текст, порядок, удаление и отметки выполнения применятся только после сохранения правок. Несохранённые правки не восстанавливаются после выхода из приложения.")
                .font(.caption).foregroundStyle(Theme.quiet)
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QwenCloud по вашему запросу").font(.headline)
            Text("Будут отправлены только показанные ниже название, подробности и ваши явные уточнения. Другие задачи, дневник, заметки и сохранённые шаги не отправляются.")
                .font(.callout).foregroundStyle(Theme.quiet)
            GroupBox("Название и подробности для отправки") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.input.title)
                    Text(draft.input.details.isEmpty ? "Подробности не указаны" : draft.input.details)
                        .foregroundStyle(Theme.quiet)
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            TextField("Необязательно: нужный результат, ограничения, ресурсы или просьба изменить вариант", text: $draft.clarifications, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(locked || draft.isContextStale)
            ForEach(draft.questions, id: \.self) { question in
                Text(question).font(.callout)
                TextField("Ваш ответ или что пока неизвестно", text: draft.answerBinding(question: question), axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).disabled(locked || draft.isContextStale)
            }
            if !draft.questions.isEmpty {
                GroupBox("Уточнения для отправки") {
                    Text(draft.explicitClarifications.isEmpty ? "Ответы пока не указаны" : draft.explicitClarifications)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
            HStack {
                if draft.busy {
                    ProgressView().controlSize(.small)
                    Text("Запрос к QwenCloud…")
                    Button("Отменить запрос") { draft.cancel() }
                } else {
                    Button(draft.proposal.isEmpty ? "Предложить шаги" : "Запросить новый вариант") {
                        if draft.proposal.isEmpty { draft.generate() } else { confirmRegenerate = true }
                    }.disabled(locked || draft.isContextStale || !canRequest)
                    Text("Без автоматических повторов").font(.caption).foregroundStyle(Theme.quiet)
                }
            }
            if !canRequest { Text(TaskBreakdownError.contextTooLarge.localizedDescription).font(.callout).foregroundStyle(.red) }
            Text("Черновики сохраняются при закрытии окна до выхода из приложения.").font(.caption).foregroundStyle(Theme.quiet)
        }
    }

    @ViewBuilder private var proposalSection: some View {
        if !draft.proposal.isEmpty {
            Divider()
            Text("Предложение, ещё не сохранено").font(.headline)
            stepRows(.proposal, completion: false)
            HStack {
                Button("Ещё шаг") { draft.proposal.append(TaskStep(text: "")) }.disabled(locked)
                Button("Удалить черновик") { confirmClear = true }.disabled(locked)
                Spacer()
                Button("Добавить шаги", action: appendSteps).buttonStyle(.borderedProminent)
                    .disabled(locked || draft.isContextStale || draft.hasSavedEdits)
            }
            if draft.hasSavedEdits { Text("Сначала сохраните правки существующих шагов.").font(.caption).foregroundStyle(Theme.quiet) }
        }
    }

    private func stepRows(_ list: BreakdownStepList, completion: Bool) -> some View {
        ForEach(Array(draft.steps(in: list).enumerated()), id: \.element.id) { index, step in
            HStack(alignment: .top, spacing: 8) {
                if completion {
                    Button {
                        draft.toggleStep(id: step.id, in: list)
                    } label: { Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle").compactHitArea() }
                        .buttonStyle(.plain).disabled(locked)
                        .accessibilityLabel(step.isCompleted ? "Вернуть шаг в работу" : "Отметить шаг выполненным")
                }
                VStack(alignment: .leading, spacing: 3) {
                    if completion, !step.isCompleted, draft.savedSteps.first(where: { !$0.isCompleted })?.id == step.id {
                        Text("Следующий шаг").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    TextField("Шаг \(index + 1)", text: draft.stepTextBinding(id: step.id, in: list), axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder)
                        .strikethrough(step.isCompleted).disabled(locked)
                }
                // Области 28×28 стоят вплотную без перекрытия; клик между строками не попадает в кнопку.
                VStack(spacing: 0) {
                    Button { draft.moveStep(id: step.id, in: list, offset: -1) } label: { Image(systemName: "arrow.up").compactHitArea() }
                        .disabled(locked || index == 0).accessibilityLabel("Переместить шаг выше")
                    Button { draft.moveStep(id: step.id, in: list, offset: 1) } label: { Image(systemName: "arrow.down").compactHitArea() }
                        .disabled(locked || index == draft.steps(in: list).count - 1).accessibilityLabel("Переместить шаг ниже")
                }.buttonStyle(.borderless)
                Button(role: .destructive) { draft.removeStep(id: step.id, in: list) } label: { Image(systemName: "trash").compactHitArea() }
                    .buttonStyle(.borderless).disabled(locked).accessibilityLabel("Удалить шаг")
            }
        }
    }

    private func saveSteps() {
        apply("Правки шагов сохранены") { try state.store.replaceTaskSteps(parent: draft.parent, steps: draft.savedSteps) }
    }
    private func appendSteps() {
        let ok = apply("Шаги добавлены", change: {
            try draft.appendProposal(to: state.store)
        })
        if ok { draft.proposal = [] }
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

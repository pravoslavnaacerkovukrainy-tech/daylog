import Foundation
import Combine
import SwiftUI

struct BreakdownTaskContext: Equatable {
    let title: String
    let details: String

    init(_ task: DayPlan) {
        title = task.text
        details = task.organization?.details ?? ""
    }
}

enum BreakdownStepList { case saved, proposal }

enum BreakdownDraftError: Error, LocalizedError {
    case staleContext
    var errorDescription: String? {
        "Название или подробности задачи изменились. Предложение и ответы относятся к прежним данным. Сначала явно пересмотрите черновик или удалите его и начните новый."
    }
}

/// Черновик переживает закрытие sheet и отмену запроса в пределах текущего запуска.
@MainActor
final class TaskBreakdownDraft: ObservableObject {
    @Published var parent: DayPlan
    @Published private(set) var observedParent: DayPlan
    @Published private(set) var sourceContext: BreakdownTaskContext
    @Published var savedSteps: [TaskStep]
    @Published var proposal: [TaskStep] = []
    @Published var clarifications = ""
    @Published var questions: [String] = []
    @Published var answers: [String] = []
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    private var requestTask: Task<Void, Never>?
    private var requestID = UUID()
    private let generateResponse: (TaskBreakdownInput) async throws -> TaskBreakdownResult

    init(parent: DayPlan, generateResponse: @escaping (TaskBreakdownInput) async throws -> TaskBreakdownResult = { input in
        guard let key = GroqKeyStore.resolve() else { throw TaskBreakdownError.noKey }
        return try await TaskBreakdownClient().generate(input: input, apiKey: key)
    }) {
        self.generateResponse = generateResponse
        self.parent = parent
        self.observedParent = parent
        self.sourceContext = BreakdownTaskContext(parent)
        self.savedSteps = parent.taskSteps
    }

    var currentContext: BreakdownTaskContext { BreakdownTaskContext(observedParent) }
    var isContextStale: Bool { sourceContext != currentContext }
    var hasSavedEdits: Bool { savedSteps != parent.taskSteps }
    var explicitClarifications: String {
        var parts = [clarifications]
        for index in questions.indices where answers.indices.contains(index) && !answers[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Вопрос: \(questions[index])\nМой ответ: \(answers[index])")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var input: TaskBreakdownInput {
        TaskBreakdownInput(title: currentContext.title, details: currentContext.details, clarifications: explicitClarifications)
    }

    func reopen(parent current: DayPlan) {
        if observedParent != current { observedParent = current }
        if isContextStale && busy { cancel() }
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

    func addStep() { savedSteps.append(TaskStep(text: "")) }

    /// Только после явного подтверждения сброса правок сохранённого списка.
    func reloadSavedSteps(parent current: DayPlan) {
        observedParent = current
        if isContextStale && busy { cancel() }
        parent = current
        savedSteps = current.taskSteps
        error = nil
    }

    /// Только после отдельного подтверждения сверки старых и текущих данных в UI.
    func confirmContextReview() {
        guard parent.taskSteps == observedParent.taskSteps else {
            error = "Сохранённые шаги тоже изменились. Загрузите актуальный список перед сохранением. Ручные правки остаются в черновике до явного подтверждения сброса."
            return
        }
        // Контекст мог измениться при неизменном списке шагов. Обновляем снимок
        // для проверки конфликта, сохраняя ручные правки в savedSteps.
        parent = observedParent
        sourceContext = currentContext
        error = nil
        notice = "Пересмотр черновика подтверждён. Проверьте шаги и уточнения перед использованием."
    }

    /// Явное удаление всех данных прежнего черновика, без изменений сохранённых шагов.
    func discardContextDraft() {
        cancel()
        proposal = []
        questions = []
        answers = []
        clarifications = ""
        sourceContext = currentContext
        error = nil
        notice = "Прежний черновик удалён. Можно задать уточнения и запросить новый вариант."
    }

    func appendProposal(to store: DiaryStore) throws -> DayPlan {
        guard !isContextStale else { throw BreakdownDraftError.staleContext }
        return try store.appendTaskSteps(parent: parent, proposal: proposal)
    }

    func generate() {
        guard !isContextStale else { error = BreakdownDraftError.staleContext.localizedDescription; return }
        guard !busy, !observedParent.isCompleted, observedParent.taskStatus != .removed else { return }
        let input = input
        do { _ = try TaskBreakdown.requestBody(input: input) }
        catch { self.error = error.localizedDescription; return }
        busy = true
        error = nil
        notice = nil
        let token = UUID()
        requestID = token
        requestTask = Task { @MainActor in
            defer { if requestID == token { busy = false; requestTask = nil } }
            do {
                let result = try await generateResponse(input)
                guard requestID == token, !Task.isCancelled else { return }
                switch result {
                case .steps(let texts):
                    proposal = texts.map { TaskStep(text: $0) }
                    notice = "Предложение готово. Проверьте факты и порядок. Сохранённые шаги не изменены."
                case .questions(let texts):
                    // Предыдущие явные ответы сохраняются в уточнениях.
                    clarifications = input.clarifications
                    questions = texts
                    answers = Array(repeating: "", count: texts.count)
                    notice = "Ответьте на нужные вопросы или обозначьте, что пока неизвестно. Затем запросите шаги."
                }
            } catch is CancellationError {
                if requestID == token { notice = "Запрос отменён. Черновик сохранён." }
            } catch {
                if requestID == token { self.error = error.localizedDescription }
            }
        }
    }

    func steps(in list: BreakdownStepList) -> [TaskStep] {
        list == .saved ? savedSteps : proposal
    }

    func stepTextBinding(id: UUID, in list: BreakdownStepList) -> Binding<String> {
        Binding(get: { self.steps(in: list).first { $0.id == id }?.text ?? "" }, set: { value in
            self.changeStep(id: id, in: list) { $0.text = value }
        })
    }

    func answerBinding(question: String) -> Binding<String> {
        Binding(get: {
            guard let index = self.questions.firstIndex(of: question), self.answers.indices.contains(index) else { return "" }
            return self.answers[index]
        }, set: { value in
            guard let index = self.questions.firstIndex(of: question), self.answers.indices.contains(index) else { return }
            self.answers[index] = value
        })
    }

    private func changeStep(id: UUID, in list: BreakdownStepList, change: (inout TaskStep) -> Void) {
        var rows = steps(in: list)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
        setSteps(rows, in: list)
    }

    func toggleStep(id: UUID, in list: BreakdownStepList) {
        changeStep(id: id, in: list) { $0.completedAt = $0.isCompleted ? nil : diaryNormalized(Date()) }
    }

    func moveStep(id: UUID, in list: BreakdownStepList, offset: Int) {
        var rows = steps(in: list)
        guard let index = rows.firstIndex(where: { $0.id == id }), [-1, 1].contains(offset), rows.indices.contains(index + offset) else { return }
        rows.swapAt(index, index + offset)
        setSteps(rows, in: list)
    }

    func removeStep(id: UUID, in list: BreakdownStepList) {
        setSteps(steps(in: list).filter { $0.id != id }, in: list)
    }

    private func setSteps(_ rows: [TaskStep], in list: BreakdownStepList) {
        if list == .saved { savedSteps = rows } else { proposal = rows }
    }

    func cancel() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        busy = false
        notice = "Запрос отменён. Черновик сохранён."
    }
}

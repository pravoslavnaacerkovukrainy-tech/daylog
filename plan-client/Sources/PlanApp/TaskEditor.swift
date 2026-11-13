import SwiftUI

/// Редактор выбранной задачи. Название и подробности сохраняются на Mac по Enter, при уходе
/// из поля или кнопкой «Сохранить на Mac» (⌘S). День сохраняется сразу.
struct TaskEditor: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p
    let task: SyncTask

    @State private var title = ""
    @State private var details = ""
    @FocusState private var focus: Field?

    enum Field { case title, details }

    private var pending: PendingEdit? { model.pending(task.id) }
    private var dirty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) != task.text ||
            details.trimmingCharacters(in: .whitespacesAndNewlines) != (task.details ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                syncBanner
                if let p = pending, p.status == .conflict, let server = p.serverTask {
                    ConflictPanel(edit: p, server: server)
                }
                titleField
                dayField
                detailsField
                actions
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { load() }
        .onChange(of: task) { _, _ in if focus == nil { load() } }
        .onChange(of: focus) { old, _ in
            if old == .title { commitTitle() }
            if old == .details { commitDetails() }
        }
        .onDisappear { commitAll() }
        .background(
            Button("") { commitAll() }.keyboardShortcut("s", modifiers: .command).opacity(0).accessibilityHidden(true)
        )
    }

    private func load() {
        title = task.text
        details = task.details ?? ""
    }

    private func commitTitle() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { title = task.text; model.notice = "Название не может быть пустым. Оставлено прежнее."; return }
        if t != task.text { model.edit(task.id, .text, .string(t)) }
    }

    private func commitDetails() {
        let d = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if d != (task.details ?? "") { model.edit(task.id, .details, d.isEmpty ? .null : .string(d)) }
    }

    private func commitAll() {
        commitTitle()
        commitDetails()
    }

    // MARK: Части

    private var syncBanner: some View {
        let mark = SyncMark.of(pending, p)
        let text: String
        if let pe = pending {
            switch pe.status {
            case .queued:
                let fields = pe.changes.keys.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", ")
                text = pe.inflight != nil
                    ? "Правка отправлена, ответ не получен. Повторим тот же запрос, дубля не будет."
                    : "Сохранено на этом Mac, ждёт отправки: \(fields.lowercased())."
            case .conflict:
                text = "Эту задачу изменили на сервере. Ничего не отправлено. Выберите версию для каждого поля."
            case .gone:
                text = (pe.message ?? "Задачи больше нет на сервере.") + " Правка хранится на Mac, пока вы её не уберёте."
            case .rejected:
                text = (pe.message ?? "Сервер не принял правку.") + " Исправьте поле или уберите правку."
            }
        } else {
            text = model.engine?.isLoggedIn == true ? "Совпадает с сервером." : "Последняя полученная версия с сервера."
        }
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(mark.color ?? p.synced).frame(width: 8, height: 8).padding(.top, 5)
            Text(text).font(.system(size: 12.5)).foregroundStyle(mark.color == nil ? p.muted : p.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor-sync-state")
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Название").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
            TextField("Название задачи", text: $title, axis: .vertical)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1...4)
                .focused($focus, equals: .title)
                .onSubmit { commitTitle() }
                .fieldChrome(focused: focus == .title)
                .accessibilityLabel("Название")
                .accessibilityIdentifier("editor-title")
        }
    }

    private var dayField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Рабочий день").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
            HStack(spacing: 8) {
                DatePicker("Рабочий день", selection: Binding(
                    get: { Days.date(task.day) ?? Days.date(model.day) ?? Date() },
                    set: { model.edit(task.id, .day, .string(Days.key($0))) }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .opacity(task.day.isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("editor-day")
                Button("Сегодня") { model.edit(task.id, .day, .string(Days.today)) }
                    .buttonStyle(PlanButtonStyle())
                    .accessibilityIdentifier("editor-day-today")
                Button("Завтра") { model.edit(task.id, .day, .string(Days.add(1, to: Days.today))) }
                    .buttonStyle(PlanButtonStyle())
                    .accessibilityIdentifier("editor-day-tomorrow")
                Button("Без даты") { model.edit(task.id, .day, .string("")) }
                    .buttonStyle(PlanButtonStyle())
                    .disabled(task.day.isEmpty)
                    .accessibilityIdentifier("editor-day-none")
            }
            Text(task.day.isEmpty ? "Дата не назначена." : Days.long(task.day).capitalizedFirst)
                .font(.system(size: 12)).foregroundStyle(p.muted)
        }
    }

    private var detailsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Подробности").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
            TextEditor(text: $details)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .details)
                .frame(minHeight: 140)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.raised))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focus == .details ? p.accent : p.line, lineWidth: focus == .details ? 1.5 : 1))
                .accessibilityLabel("Подробности")
                .accessibilityIdentifier("editor-details")
        }
    }

    private var actions: some View {
        let online = model.engine?.canUseServer ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Сохранить на Mac") { commitAll(); focus = nil }
                    .buttonStyle(PlanButtonStyle(primary: true))
                    .disabled(!dirty)
                    .help("Сохранить название и подробности (⌘S)")
                    .accessibilityIdentifier("editor-save")
                if task.isCompleted {
                    Button("Вернуть в работу") {
                        model.runOnline { try await model.engine?.setCompleted(task.id, false) }
                    }
                    .buttonStyle(PlanButtonStyle())
                    .disabled(!online || model.busy)
                    .accessibilityIdentifier("editor-reopen")
                } else if !task.isRemoved {
                    Button("Выполнено") {
                        commitAll()
                        model.runOnline { try await model.engine?.setCompleted(task.id, true) }
                    }
                    .buttonStyle(PlanButtonStyle())
                    .disabled(!online || model.busy)
                    .accessibilityIdentifier("editor-complete")
                }
                if let pe = pending, pe.status == .gone || pe.status == .rejected {
                    Button("Убрать правку") { model.discard(task.id) }
                        .buttonStyle(PlanButtonStyle())
                        .accessibilityIdentifier("editor-discard")
                }
            }
            if !online && !task.isRemoved {
                Text("Отметить выполнение можно только при связи с сервером. Правки названия, дня и подробностей работают и без неё.")
                    .font(.system(size: 12)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let n = model.notice {
                Text(n).font(.system(size: 12)).foregroundStyle(p.conflict)
                    .accessibilityIdentifier("editor-notice")
            }
        }
    }
}

/// Обе версии каждого спорного поля и выбор. Пока выбора нет, правка не отправляется.
struct ConflictPanel: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p
    let edit: PendingEdit
    let server: SyncTask

    private func show(_ f: SyncField, _ v: FieldValue?) -> String {
        switch v {
        case .some(.string(let s)):
            if f == .day { return s.isEmpty ? "Без даты" : Days.long(s).capitalizedFirst }
            return s.isEmpty ? "Пусто" : s
        default: return "Пусто"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Конфликт версий").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.conflict)
                .accessibilityAddTraits(.isHeader)
            ForEach(edit.conflictFields, id: \.self) { f in
                VStack(alignment: .leading, spacing: 8) {
                    Text(f.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                    HStack(alignment: .top, spacing: 12) {
                        version("Моя версия", show(f, edit.changes[f]), p.pending)
                        version("Версия сервера", show(f, server.value(f)), p.accent)
                    }
                    Text("Было до правки: \(show(f, edit.base[f]))").font(.system(size: 11.5)).foregroundStyle(p.muted)
                    HStack(spacing: 8) {
                        Button("Моя версия") { model.resolve(edit.taskId, f, .mine) }
                            .buttonStyle(PlanButtonStyle(primary: true))
                            .accessibilityLabel("\(f.title): оставить мою версию")
                            .accessibilityIdentifier("conflict-mine-\(f.rawValue)")
                        Button("Версия сервера") { model.resolve(edit.taskId, f, .server) }
                            .buttonStyle(PlanButtonStyle())
                            .accessibilityLabel("\(f.title): взять версию сервера")
                            .accessibilityIdentifier("conflict-server-\(f.rawValue)")
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.conflict.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.conflict.opacity(0.55)))
        .accessibilityIdentifier("conflict-panel")
    }

    private func version(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.raised))
    }
}

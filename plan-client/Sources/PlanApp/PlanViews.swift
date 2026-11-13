import SwiftUI

/// Состояние синхронизации задачи: цвет метки строки и короткая подпись.
struct SyncMark {
    let color: Color?
    let label: String?

    static func of(_ p: PendingEdit?, _ pal: Palette) -> SyncMark {
        guard let p else { return SyncMark(color: nil, label: nil) }
        switch p.status {
        case .queued:
            return SyncMark(color: pal.pending, label: p.inflight != nil ? "Отправлено, ждём подтверждения" : "Ждёт отправки")
        case .conflict: return SyncMark(color: pal.conflict, label: "Конфликт")
        case .gone: return SyncMark(color: pal.conflict, label: "Нет на сервере")
        case .rejected: return SyncMark(color: pal.conflict, label: "Сервер не принял")
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p
    let task: SyncTask
    var showDay = false

    var body: some View {
        let mark = SyncMark.of(model.pending(task.id), p)
        let selected = model.selectedTask == task.id
        Button {
            model.selectedTask = task.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(mark.color ?? Color.clear)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.text)
                        .font(.system(size: 13.5, weight: .medium))
                        .strikethrough(!task.isOpen, color: p.muted)
                        .foregroundStyle(task.isOpen ? p.text : p.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        if showDay { Text(Days.short(task.day)) }
                        if task.isCompleted { Text("Выполнена") }
                        if task.isRemoved { Text("Снята") }
                        if let d = task.details, !d.isEmpty {
                            Text(d.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
                        }
                        if let l = mark.label { Text(l).foregroundStyle(mark.color ?? p.muted).fontWeight(.medium) }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.trailing, 10)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? p.raised : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("task-row-\(task.id)")
        .accessibilityLabel("\(task.text). \(Days.short(task.day)). \(mark.label ?? "Отправлено")")
    }
}

/// «План»: компактная неделя с датами и задачи выбранного дня.
struct PlanView: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Days.long(model.day).capitalizedFirst)
                        .font(.system(size: 24, weight: .semibold, design: .default))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("plan-day-title")
                    Spacer()
                    if model.day != Days.today {
                        Button("Сегодня") { model.day = Days.today }
                            .buttonStyle(PlanButtonStyle())
                            .accessibilityIdentifier("week-today")
                    }
                }
                WeekStrip()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Rectangle().fill(p.line).frame(height: 1)

            let list = model.tasks(on: model.day)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if list.isEmpty {
                        Text("На этот день задач нет. Назначьте рабочий день задаче в разделе «Все задачи» или запишите новую строку.")
                            .foregroundStyle(p.muted)
                            .font(.system(size: 13))
                            .padding(.vertical, 18)
                            .padding(.horizontal, 6)
                    }
                    ForEach(list) { TaskRow(task: $0) }
                    let undated = model.tasks.filter { $0.day.isEmpty && $0.isOpen }
                    if !undated.isEmpty {
                        Text("Без даты")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.muted)
                            .padding(.top, 16).padding(.bottom, 4).padding(.leading, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(undated) { TaskRow(task: $0) }
                    }
                }
                .padding(10)
            }
        }
    }
}

struct WeekStrip: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 4) {
            Button { model.day = Days.add(-7, to: model.day) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Предыдущая неделя")
                .accessibilityLabel("Предыдущая неделя")
                .accessibilityIdentifier("week-prev")
            ForEach(Days.week(of: model.day), id: \.self) { key in
                dayCell(key)
            }
            Button { model.day = Days.add(7, to: model.day) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Следующая неделя")
                .accessibilityLabel("Следующая неделя")
                .accessibilityIdentifier("week-next")
        }
    }

    private func dayCell(_ key: String) -> some View {
        let selected = key == model.day
        let today = key == Days.today
        let count = model.openCount(on: key)
        return Button { model.day = key } label: {
            VStack(spacing: 2) {
                Text(Days.format(key, "EEE")).font(.system(size: 11)).foregroundStyle(selected ? p.onAccent : p.muted)
                Text(Days.format(key, "d")).font(.system(size: 16, weight: today ? .bold : .medium)).monospacedDigit()
                Text(count > 0 ? "\(count)" : " ")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(selected ? p.onAccent : p.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? p.onAccent : p.text)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? p.accent : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(today && !selected ? p.accent : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Days.long(key)). Задач: \(count)\(today ? ". Сегодня" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("week-day-\(key)")
    }
}

/// «Все задачи»: группы по рабочему дню, без даты в начале.
struct AllTasksView: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Toggle("Показывать выполненные", isOn: $model.showCompleted)
                    .accessibilityIdentifier("toggle-completed")
                Toggle("Показывать снятые", isOn: $model.showRemoved)
                    .accessibilityIdentifier("toggle-removed")
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .padding(.horizontal, 16).padding(.vertical, 10)
            Rectangle().fill(p.line).frame(height: 1)
            let groups = Dictionary(grouping: model.visibleAll, by: \.day)
            let keys = groups.keys.sorted { a, b in a.isEmpty ? !b.isEmpty : (b.isEmpty ? false : a < b) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if keys.isEmpty {
                        Text(model.engine?.isLoggedIn == true ? "Задач нет." : "Задач пока нет. Подключитесь к серверу в разделе «Подключение».")
                            .foregroundStyle(p.muted).font(.system(size: 13)).padding(16)
                    }
                    ForEach(keys, id: \.self) { key in
                        Text(key.isEmpty ? "Без даты" : Days.long(key).capitalizedFirst)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(key == Days.today ? p.accent : p.muted)
                            .padding(.top, 12).padding(.bottom, 4).padding(.leading, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(groups[key] ?? []) { TaskRow(task: $0) }
                    }
                }
                .padding(10)
            }
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

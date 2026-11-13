import AppKit
import SwiftUI

@main
struct PlanPilotApp: App {
    @StateObject private var model = PlanModel()

    var body: some Scene {
        WindowGroup("Хаос Дня — План") {
            RootView()
                .environmentObject(model)
                .environment(\.palette, model.palette)
                .preferredColorScheme(model.theme.scheme)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1220, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Записать…") { model.captureOpen = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Синхронизация") {
                Button("Отправить и обновить") { Task { await model.syncNow() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button(model.engine?.isOffline == true ? "Выключить офлайн" : "Включить офлайн") {
                    model.setOffline(!(model.engine?.isOffline ?? false))
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Picker("Оформление", selection: $model.theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        Group {
            if let error = model.startupError {
                Text(error).foregroundStyle(p.conflict).padding(40)
            } else {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
                } content: {
                    ContentColumn()
                        .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 560)
                } detail: {
                    DetailColumn()
                }
            }
        }
        .background(p.canvas)
        .foregroundStyle(p.text)
        .tint(p.accent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                StatusPill()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.captureOpen = true
                } label: {
                    Label("Записать", systemImage: "square.and.pencil").labelStyle(.titleAndIcon)
                }
                .help("Записать строку в место хаоса (⇧⌘N)")
                .accessibilityIdentifier("capture-button")

                Button {
                    Task { await model.syncNow() }
                } label: {
                    Label("Отправить", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Отправить правки и обновить задачи (⌘R)")
                .disabled(!(model.engine?.canUseServer ?? false) || model.busy)
                .accessibilityIdentifier("sync-now")

                Picker("Оформление", selection: $model.theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .help("Оформление окна")
                .accessibilityIdentifier("theme-picker")
            }
        }
        .sheet(isPresented: $model.captureOpen) {
            CaptureSheet()
                .environmentObject(model)
                .environment(\.palette, model.palette)
                .preferredColorScheme(model.theme.scheme)
        }
    }
}

/// Явный статус синхронизации: где сейчас правки и что с ними будет.
struct StatusPill: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    private var info: (String, Color, String) {
        guard let e = model.engine else { return ("Нет локальной копии", p.conflict, "xmark.octagon") }
        let queued = e.queuedCount
        let decide = e.decisionCount
        let waiting = queued > 0 ? " Ждут отправки: \(queued)." : ""
        if decide > 0 && e.connection != .syncing {
            var where_ = ""
            switch e.connection {
            case .offlineManual: where_ = " Офлайн включён."
            case .unreachable: where_ = " Нет связи."
            case .needsLogin: where_ = " Нужен вход."
            case .idle where !e.isLoggedIn: where_ = " Вход не выполнен."
            default: break
            }
            return ("Нужно решение: \(decide).\(waiting)\(where_)", p.conflict, "exclamationmark.triangle")
        }
        switch e.connection {
        case .noServer: return ("Сервер не выбран", p.muted, "network.slash")
        case .offlineManual: return ("Офлайн включён. Правки сохраняются на Mac.\(waiting)", p.pending, "airplane")
        case .unreachable: return ("Нет связи. Правки сохранены на Mac.\(waiting)", p.pending, "wifi.slash")
        case .needsLogin: return ("Нужен вход. Правки сохранены на Mac.\(waiting)", p.pending, "person.crop.circle.badge.exclamationmark")
        case .serverError(let m): return ("Сервер не ответил: \(m)\(waiting)", p.conflict, "exclamationmark.icloud")
        case .syncing: return ("Отправка…", p.accent, "arrow.triangle.2.circlepath")
        case .idle where !e.isLoggedIn: return ("Вход не выполнен. Правки сохраняются на Mac.\(waiting)", p.muted, "person.crop.circle")
        case .idle, .online:
            return queued > 0 ? ("Ждут отправки: \(queued)", p.pending, "clock.arrow.circlepath")
                              : ("Всё отправлено", p.synced, "checkmark.circle")
        }
    }

    var body: some View {
        let (text, color, symbol) = info
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().stroke(color.opacity(0.45)))
        .frame(maxWidth: 460, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Состояние синхронизации: \(text)")
        .accessibilityIdentifier("status-pill")
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            ForEach(Section.allCases) { s in
                HStack {
                    Label(s.title, systemImage: s.symbol)
                    Spacer()
                    badge(for: s)
                }
                .tag(s)
                .accessibilityIdentifier("nav-\(s.rawValue)")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(p.panel)
    }

    @ViewBuilder private func badge(for s: Section) -> some View {
        switch s {
        case .outbox:
            let n = model.engine?.pending.count ?? 0
            if n > 0 {
                Text("\(n)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill((model.engine?.decisionCount ?? 0) > 0 ? p.conflict : p.pending))
                    .foregroundStyle(p.onAccent)
                    .accessibilityLabel("Неотправленных правок: \(n)")
            }
        case .chaos:
            let n = model.engine?.chaos.count ?? 0
            if n > 0 { Text("\(n)").font(.system(size: 11)).monospacedDigit().foregroundStyle(p.muted) }
        default:
            EmptyView()
        }
    }
}

struct ContentColumn: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        Group {
            switch model.section {
            case .plan: PlanView()
            case .all: AllTasksView()
            case .chaos: ChaosView()
            case .outbox: OutboxView()
            case .connection: ConnectionView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(p.panel)
        .navigationTitle(model.section.title)
    }
}

struct DetailColumn: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        Group {
            if let id = model.selectedTask, let task = model.engine?.task(id) {
                TaskEditor(task: task).id(task.id)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Задача не выбрана").font(.system(size: 15, weight: .semibold))
                    Text("Выберите задачу в списке, чтобы изменить название, рабочий день или подробности. Правка сразу сохраняется на этом Mac и уходит на сервер, когда есть связь.")
                        .foregroundStyle(p.muted)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(p.canvas)
    }
}

import SwiftUI

private let onlineOnlyHint = "Нужна связь с сервером. Эти действия не ставятся в очередь: они выполняются сразу или не выполняются."

/// «Записать»: одна строка в место хаоса.
struct CaptureSheet: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var urgent = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let online = model.engine?.canUseServer ?? false
        VStack(alignment: .leading, spacing: 14) {
            Text("Записать").font(.system(size: 17, weight: .semibold))
            TextField("Что сейчас занимает голову", text: $text)
                .focused($focused)
                .fieldChrome(focused: focused)
                .onSubmit { save() }
                .accessibilityIdentifier("capture-text")
            Toggle("Не может ждать", isOn: $urgent).toggleStyle(.checkbox)
                .accessibilityIdentifier("capture-urgent")
            if !online {
                Text(onlineOnlyHint).font(.system(size: 12)).foregroundStyle(p.pending)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(p.conflict) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PlanButtonStyle())
                Button("Записать") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PlanButtonStyle(primary: true))
                    .disabled(!online || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("capture-save")
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(p.canvas)
        .foregroundStyle(p.text)
        .onAppear { focused = true }
    }

    private func save() {
        guard let engine = model.engine, engine.canUseServer else { return }
        Task {
            do {
                _ = try await engine.capture(text, urgent: urgent)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Место хаоса: строки ждут разбора в задачу или заметку.
struct ChaosView: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        let online = model.engine?.canUseServer ?? false
        let items = model.engine?.chaos ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { model.captureOpen = true } label: { Label("Записать", systemImage: "square.and.pencil") }
                    .buttonStyle(PlanButtonStyle(primary: true))
                    .accessibilityIdentifier("chaos-capture")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if !online {
                Text(onlineOnlyHint).font(.system(size: 12)).foregroundStyle(p.pending)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(p.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty {
                        Text("Место хаоса пусто.").foregroundStyle(p.muted).font(.system(size: 13)).padding(16)
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.text).font(.system(size: 13.5))
                                if item.urgent {
                                    Text("Не может ждать").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.pending)
                                }
                            }
                            HStack(spacing: 8) {
                                Button("В задачу на \(Days.short(model.day).lowercased())") {
                                    model.runOnline { _ = try await model.engine?.chaosToTask(item.id, day: model.day) }
                                }
                                .accessibilityIdentifier("chaos-to-task-\(item.id)")
                                Button("В задачу без даты") {
                                    model.runOnline { _ = try await model.engine?.chaosToTask(item.id, day: "") }
                                }
                                Button("В заметку") {
                                    model.runOnline { try await model.engine?.chaosToNote(item.id) }
                                }
                                .accessibilityIdentifier("chaos-to-note-\(item.id)")
                            }
                            .buttonStyle(PlanButtonStyle())
                            .disabled(!online || model.busy)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        Rectangle().fill(p.line.opacity(0.6)).frame(height: 1)
                    }
                }
            }
            if let n = model.notice {
                Text(n).font(.system(size: 12)).foregroundStyle(p.conflict).padding(12)
            }
        }
    }
}

/// Отправка: все неотправленные правки и те, что ждут решения.
struct OutboxView: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p

    var body: some View {
        let items = model.engine?.pending ?? []
        let others = model.engine?.otherServersWithPending() ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(items.isEmpty ? "Все правки отправлены." : "Правки хранятся на этом Mac до подтверждения сервера или вашего решения.")
                    .font(.system(size: 12.5)).foregroundStyle(p.muted)
                    .padding(.horizontal, 6).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(items) { pe in
                    if let t = model.engine?.task(pe.taskId) {
                        TaskRow(task: t, showDay: true)
                    } else {
                        HStack {
                            Text("Задача \(pe.taskId)").foregroundStyle(p.muted)
                            Spacer()
                            Button("Убрать правку") { model.discard(pe.taskId) }.buttonStyle(PlanButtonStyle())
                        }
                        .padding(8)
                    }
                }
                if !others.isEmpty {
                    Text("На других серверах")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                        .padding(.top, 16).padding(.leading, 6)
                    ForEach(others, id: \.server) { o in
                        Text("\(o.server): неотправленных правок \(o.count). Они уйдут, когда вы снова подключитесь к этому серверу.")
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
        }
        .accessibilityIdentifier("outbox")
    }
}

/// Подключение: сервер, вход, офлайн, оформление. Пароль живёт только в поле до входа.
struct ConnectionView: View {
    @EnvironmentObject var model: PlanModel
    @Environment(\.palette) private var p
    @State private var password = ""
    @FocusState private var focus: Int?

    var body: some View {
        let e = model.engine
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Сервер").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                    TextField("http://127.0.0.1:3000", text: $model.serverDraft)
                        .focused($focus, equals: 0)
                        .fieldChrome(focused: focus == 0)
                        .accessibilityLabel("Адрес сервера")
                        .accessibilityIdentifier("server-field")
                    Text("Без https можно подключаться только к этому Mac. У каждого сервера своя локальная копия и своя очередь правок.")
                        .font(.system(size: 11.5)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Пароль").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                    SecureField("Пароль сервера", text: $password)
                        .focused($focus, equals: 1)
                        .fieldChrome(focused: focus == 1)
                        .onSubmit { connect() }
                        .accessibilityLabel("Пароль")
                        .accessibilityIdentifier("login-password")
                    Text("Пароль не сохраняется. После перезапуска нужно войти снова, неотправленные правки при этом остаются.")
                        .font(.system(size: 11.5)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(e?.isLoggedIn == true ? "Войти заново" : "Войти") { connect() }
                        .buttonStyle(PlanButtonStyle(primary: true))
                        .disabled(password.isEmpty || model.busy || e?.isOffline == true)
                        .accessibilityIdentifier("login-button")
                    if e?.isLoggedIn == true {
                        Button("Выйти") { model.logout() }.buttonStyle(PlanButtonStyle())
                            .accessibilityIdentifier("logout-button")
                    }
                }
                Text(e?.isLoggedIn == true ? "Вход выполнен: \(e?.server ?? "")" : "Вход не выполнен.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(e?.isLoggedIn == true ? p.synced : p.muted)
                    .accessibilityIdentifier("login-state")

                Rectangle().fill(p.line).frame(height: 1)

                Toggle(isOn: Binding(get: { e?.isOffline ?? false }, set: { model.setOffline($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Работать офлайн")
                        Text("Ничего не отправляется. Правки копятся на Mac и уйдут после выключения.")
                            .font(.system(size: 11.5)).foregroundStyle(p.muted)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("offline-toggle")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Оформление").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                    Picker("Оформление", selection: $model.theme) {
                        ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .accessibilityIdentifier("theme-picker-settings")
                }

                Text("Локальная копия: \(model.dataDir.path)")
                    .font(.system(size: 11)).foregroundStyle(p.muted).textSelection(.enabled)
                if let n = model.notice {
                    Text(n).font(.system(size: 12)).foregroundStyle(p.conflict)
                        .accessibilityIdentifier("connection-notice")
                }
            }
            .padding(18)
        }
    }

    private func connect() {
        let pw = password
        Task {
            if await model.connect(password: pw) { password = "" }
        }
    }
}

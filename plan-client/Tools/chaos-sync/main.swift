import Foundation

// chaos-sync: CLI поверх SyncCore (тот же код, что в приложении) для воспроизводимой приёмки.
// Вывод всегда JSON в stdout. Коды выхода: 0 — успех, 1 — ошибка, 2 — неверный вызов,
// 3 — есть конфликт, удалённая или отклонённая правка (нужно решение).
// Пароль читается только из CHAOS_SYNC_PASSWORD и на диск не пишется.

let usage = """
chaos-sync --data DIR [--server URL] КОМАНДА
  pull                         войти и получить задачи
  list                         локальный вид: сервер + неотправленные правки
  edit ID [--day ГГГГ-ММ-ДД | --no-day] [--text T] [--details D | --clear-details]
                               правка только в локальной копии, без сети
  push [--offline]             отправить очередь (--offline: ручной офлайн на этот вызов)
  sync                         отправить очередь, затем получить задачи
  status                       сервер, связь, очередь, конфликты
  resolve ID FIELD mine|server решение конфликта по полю (day, text, details)
  discard ID                   отказаться от правки задачи
  offline on|off               сохранить переключатель офлайна
Пароль: переменная окружения CHAOS_SYNC_PASSWORD.
"""

struct UsageError: Error { let message: String }

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func json(_ v: FieldValue?) -> Any {
    switch v {
    case .some(.string(let s)): return s
    default: return NSNull()
    }
}

func fields(_ d: [SyncField: FieldValue]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in d { out[k.rawValue] = json(v) }
    return out
}

func taskJSON(_ t: SyncTask) -> [String: Any] {
    ["id": t.id, "text": t.text, "day": t.day, "details": t.details as Any? ?? NSNull(),
     "is_completed": t.isCompleted, "is_removed": t.isRemoved, "updated_at": t.updatedAt as Any? ?? NSNull()]
}

func pendingJSON(_ p: PendingEdit) -> [String: Any] {
    var o: [String: Any] = [
        "task_id": p.taskId, "status": p.status.rawValue, "base": fields(p.base), "changes": fields(p.changes),
        "uncertain": p.inflight != nil, "attempts": p.attempts,
        "conflict_fields": p.conflictFields.map(\.rawValue),
    ]
    if let m = p.message { o["message"] = m }
    if let s = p.serverTask { o["server_task"] = taskJSON(s) }
    if let i = p.inflight { o["inflight"] = ["base": fields(i.base), "changes": fields(i.changes)] }
    return o
}

@MainActor func connectionJSON(_ c: ConnectionState) -> [String: Any] {
    switch c {
    case .idle: return ["state": "idle"]
    case .syncing: return ["state": "syncing"]
    case .online: return ["state": "online"]
    case .offlineManual: return ["state": "offline_manual"]
    case .unreachable(let m): return ["state": "unreachable", "message": m]
    case .needsLogin(let m): return ["state": "needs_login", "message": m]
    case .serverError(let m): return ["state": "server_error", "message": m]
    case .noServer: return ["state": "no_server"]
    }
}

@MainActor func statusJSON(_ e: SyncEngine) -> [String: Any] {
    [
        "server": e.server as Any? ?? NSNull(),
        "offline": e.isOffline,
        "connection": connectionJSON(e.connection),
        "queued": e.queuedCount,
        "needs_decision": e.decisionCount,
        "pending": e.pending.map(pendingJSON),
        "other_servers": e.otherServersWithPending().map { ["server": $0.server, "pending": $0.count] },
    ]
}

func reportJSON(_ r: FlushReport) -> [String: Any] {
    ["applied": r.applied, "conflicts": r.conflicts, "gone": r.gone, "rejected": r.rejected,
     "stopped": r.stopped as Any? ?? NSNull()]
}

@MainActor func loginIfNeeded(_ e: SyncEngine) async throws {
    if e.isOffline || e.isLoggedIn { return }
    guard let pw = ProcessInfo.processInfo.environment["CHAOS_SYNC_PASSWORD"], !pw.isEmpty else {
        throw SyncError.unauthorized("Задайте пароль в CHAOS_SYNC_PASSWORD.")
    }
    try await e.login(password: pw)
}

@main
struct ChaosSync {
    @MainActor static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var dataDir = ProcessInfo.processInfo.environment["CHAOS_PLAN_DATA_DIR"]
        var server: String?
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        func flag(_ name: String) -> Bool {
            guard let i = args.firstIndex(of: name) else { return false }
            args.remove(at: i)
            return true
        }
        if let d = take("--data") { dataDir = d }
        server = take("--server")
        if flag("--help") || flag("-h") { print(usage); exit(0) }
        guard let dataDir, let command = args.first else {
            FileHandle.standardError.write(usage.data(using: .utf8)!)
            exit(2)
        }
        args.removeFirst()

        do {
            let e = try SyncEngine(dataDir: URL(fileURLWithPath: dataDir), transport: URLSessionTransport())
            if let server { try e.setServer(server) }
            var code: Int32 = 0
            var out: [String: Any] = [:]
            switch command {
            case "pull":
                try await loginIfNeeded(e)
                try await e.pull()
                out["tasks"] = e.tasks.map(taskJSON)
            case "list":
                out["tasks"] = e.tasks.map { t -> [String: Any] in
                    var o = taskJSON(t)
                    o["sync"] = e.pendingEdit(t.id)?.status.rawValue ?? "synced"
                    return o
                }
            case "edit":
                guard let id = args.first else { throw UsageError(message: "edit: нужен ID") }
                args.removeFirst()
                var any = false
                if let d = take("--day") { try e.edit(id, .day, .string(d)); any = true }
                if flag("--no-day") { try e.edit(id, .day, .string("")); any = true }
                if let t = take("--text") { try e.edit(id, .text, .string(t)); any = true }
                if let d = take("--details") { try e.edit(id, .details, .string(d)); any = true }
                if flag("--clear-details") { try e.edit(id, .details, .null); any = true }
                guard any else { throw UsageError(message: "edit: укажите хотя бы одно поле") }
                out["task"] = e.task(id).map(taskJSON) ?? NSNull()
                out["pending"] = e.pendingEdit(id).map(pendingJSON) ?? NSNull()
            case "push", "sync":
                let wasOffline = e.isOffline
                if flag("--offline") && !wasOffline { try e.setOffline(true) }
                defer { if !wasOffline && e.isOffline { try? e.setOffline(false) } }
                try? await loginIfNeeded(e)
                let r = command == "sync" ? await e.syncNow() : await e.flush()
                out["report"] = reportJSON(r)
                if r.stopped != nil && e.queuedCount > 0 { code = 1 }
            case "status":
                break
            case "resolve":
                guard args.count >= 3, let f = SyncField(rawValue: args[1]), let c = ResolveChoice(rawValue: args[2]) else {
                    throw UsageError(message: "resolve ID day|text|details mine|server")
                }
                try e.resolve(args[0], f, c)
            case "discard":
                guard let id = args.first else { throw UsageError(message: "discard: нужен ID") }
                try e.discard(id)
            case "offline":
                guard let v = args.first, v == "on" || v == "off" else { throw UsageError(message: "offline on|off") }
                try e.setOffline(v == "on")
            default:
                throw UsageError(message: "неизвестная команда \(command)")
            }
            out["status"] = statusJSON(e)
            out["ok"] = code == 0
            if code == 0 && e.decisionCount > 0 { code = 3 }
            emit(out)
            exit(code)
        } catch let u as UsageError {
            emit(["ok": false, "error": u.message])
            exit(2)
        } catch {
            emit(["ok": false, "error": error.localizedDescription])
            exit(1)
        }
    }
}

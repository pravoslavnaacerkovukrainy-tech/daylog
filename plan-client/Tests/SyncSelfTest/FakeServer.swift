import Foundation

/// Сервер в памяти по протоколу синхронизации. Только синтетические данные.
/// Сбои: down (нет связи до запроса), dropNextResponse (запрос применён, ответ потерян).
final class FakeServer: HTTPTransport {
    struct Stored { var task: SyncTask; var revision: Int }

    var tasks: [String: Stored] = [:]
    var order: [String] = []
    var password = "synthetic-pass"
    var sessions: Set<String> = []
    var down = false
    var dropNextResponse = false
    var failNextWith500 = false
    var requests: [String] = []
    var syncBodies: [[String: Any]] = []

    func add(_ task: SyncTask) {
        tasks[task.id] = Stored(task: task, revision: 1)
        order.append(task.id)
    }

    func revision(_ id: String) -> Int { tasks[id]?.revision ?? -1 }

    /// Правка «с другого клиента» в обход протокола синхронизации.
    func externalEdit(_ id: String, _ field: SyncField, _ value: FieldValue) {
        tasks[id]?.task.set(field, value)
        tasks[id]?.revision += 1
    }

    func killSessions() { sessions.removeAll() }

    private func json(_ status: Int, _ obj: Any, headers: [String: String] = [:]) -> HTTPReply {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        var h = headers
        h["Content-Type"] = "application/json"
        return HTTPReply(status: status, headers: h, body: data)
    }

    private func taskJSON(_ t: SyncTask) -> [String: Any] {
        let data = try! JSONEncoder().encode(t)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func error(_ status: Int, _ code: String, _ message: String, data: Any? = nil) -> HTTPReply {
        var obj: [String: Any] = ["error": ["code": code, "message": message]]
        if let data { obj["data"] = data }
        return json(status, obj)
    }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        if down { throw URLError(.notConnectedToInternet) }
        let reply = handle(request)
        if dropNextResponse {
            dropNextResponse = false
            throw URLError(.networkConnectionLost)
        }
        return reply
    }

    private func handle(_ request: URLRequest) -> HTTPReply {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path
        requests.append("\(method) \(path)")
        if failNextWith500 { failNextWith500 = false; return error(500, "internal", "Сбой сервера.") }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        if method == "POST" && path == "/api/auth/login" {
            guard body["password"] as? String == password else { return error(401, "unauthorized", "Неверный пароль.") }
            let token = UUID().uuidString
            sessions.insert(token)
            return json(200, ["ok": true, "authenticated": true],
                        headers: ["Set-Cookie": "chaos_day_session=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=3600"])
        }
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let token = cookie.components(separatedBy: "chaos_day_session=").dropFirst().first ?? ""
        guard sessions.contains(token) else { return error(401, "unauthorized", "Нужно войти.") }
        if method != "GET" && request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") != true {
            return error(415, "unsupported_media_type", "Только JSON.")
        }

        let seg = path.split(separator: "/").map(String.init)
        if method == "GET" && path == "/api/tasks" {
            return json(200, ["ok": true, "data": ["tasks": order.compactMap { tasks[$0].map { taskJSON($0.task) } }]])
        }
        if method == "GET" && seg.count == 3 && seg[1] == "tasks" {
            guard let t = tasks[seg[2].lowercased()] else { return error(404, "not_found", "Задача не найдена.") }
            return json(200, ["ok": true, "data": ["task": taskJSON(t.task)]])
        }
        if method == "POST" && seg.count == 4 && seg[1] == "sync" && seg[2] == "tasks" {
            syncBodies.append(body)
            return sync(seg[3].lowercased(), body)
        }
        if path == "/api/chaos" && method == "GET" {
            return json(200, ["ok": true, "data": ["chaos": chaos.map(chaosJSON)]])
        }
        if path == "/api/chaos" && method == "POST" {
            let item = ChaosItem(id: UUID().uuidString, text: (body["text"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                                 urgent: body["urgent"] as? Bool ?? false)
            chaos.append(item)
            return json(201, ["ok": true, "data": ["chaos": chaosJSON(item)]])
        }
        if method == "POST" && seg.count == 4 && seg[1] == "chaos" {
            let cid = seg[2].lowercased()
            guard chaos.contains(where: { $0.id == cid }) else { return error(404, "not_found", "Строки нет.") }
            chaos.removeAll { $0.id == cid }
            if seg[3] == "to-task" {
                let t = SyncTask(id: UUID().uuidString, text: body["text"] as? String ?? "", day: body["day"] as? String ?? "")
                add(t)
                return json(201, ["ok": true, "data": ["task": taskJSON(t), "removed_chaos_id": cid]])
            }
            notes += 1
            return json(201, ["ok": true, "data": ["note": ["id": UUID().uuidString.lowercased()], "removed_chaos_id": cid]])
        }
        if method == "POST" && seg.count == 4 && seg[1] == "tasks" && (seg[3] == "complete" || seg[3] == "reopen") {
            guard var stored = tasks[seg[2].lowercased()] else { return error(404, "not_found", "Задача не найдена.") }
            stored.task.isCompleted = seg[3] == "complete"
            stored.revision += 1
            tasks[stored.task.id] = stored
            return json(200, ["ok": true, "data": ["task": taskJSON(stored.task), "entry": NSNull()]])
        }
        return error(404, "not_found", "Такого пути API нет.")
    }

    var chaos: [ChaosItem] = []
    var notes = 0

    private func chaosJSON(_ c: ChaosItem) -> [String: Any] {
        ["id": c.id, "text": c.text, "urgent": c.urgent, "created_at": "2026-11-13T10:00:00Z"]
    }

    private func value(_ any: Any?) -> FieldValue? {
        if any is NSNull { return .null }
        if let s = any as? String { return .string(s) }
        return nil
    }

    private func sync(_ id: String, _ body: [String: Any]) -> HTTPReply {
        guard let base = body["base"] as? [String: Any], let changes = body["changes"] as? [String: Any],
              !changes.isEmpty, Set(base.keys) == Set(changes.keys) else {
            return error(400, "invalid_request", "base и changes должны содержать одинаковые поля.")
        }
        guard var stored = tasks[id] else { return error(404, "not_found", "Задача не найдена.") }
        var conflicts: [String] = []
        var apply: [(SyncField, FieldValue)] = []
        for key in changes.keys.sorted() {
            guard let field = SyncField(rawValue: key), let b = value(base[key]), let c = value(changes[key]) else {
                return error(400, "invalid_request", "Поле \(key) не поддерживается.")
            }
            let normalized: FieldValue
            do { normalized = try SyncNormalize.value(field, c) } catch let failure {
                return self.error(400, "invalid_request", failure.localizedDescription)
            }
            let current = stored.task.value(field)
            if current == normalized { continue }
            if current == b { apply.append((field, normalized)) } else { conflicts.append(key) }
        }
        if !conflicts.isEmpty {
            return error(409, "sync_conflict", "Задачу изменили на сервере.",
                         data: ["task": taskJSON(stored.task), "conflicts": conflicts])
        }
        if !apply.isEmpty {
            for (f, v) in apply { stored.task.set(f, v) }
            stored.revision += 1
            stored.task.updatedAt = "rev-\(stored.revision)"
            tasks[id] = stored
        }
        return json(200, ["ok": true, "data": ["task": taskJSON(stored.task)]])
    }
}

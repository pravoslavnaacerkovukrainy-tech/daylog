import Foundation

/// Ответ HTTP без привязки к URLSession, чтобы самопроверка могла подставить свой сервер.
public struct HTTPReply: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: AnyObject {
    /// Бросает ошибку только при сбое транспорта (нет связи, тайм-аут). Любой HTTP-статус — это ответ.
    func send(_ request: URLRequest) async throws -> HTTPReply
}

/// Сетевой транспорт. Куки и кэш не пишутся на диск: сессия живёт только в памяти процесса.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        // API не перенаправляет. Любой 3xx возвращается как ответ и не выполняется,
        // чтобы пароль и cookie не ушли на другой адрес.
        let (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.badResponse("не HTTP")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPReply(status: http.statusCode, headers: headers, body: data)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Результат POST /api/sync/tasks/:id.
public enum SyncOutcome: Equatable, Sendable {
    case applied(SyncTask)
    case conflict(SyncTask, [SyncField])
    case gone(String)
    case rejected(Int, String)
    case unauthorized(String)
    case serverError(Int, String)
}

/// Тонкий клиент протокола. Cookie сессии хранится только в памяти.
public final class SyncAPI {
    public static let cookieName = "chaos_day_session"

    public let server: String
    private let transport: HTTPTransport
    public private(set) var sessionCookie: String?

    public init(server: String, transport: HTTPTransport) {
        self.server = server
        self.transport = transport
    }

    public var isLoggedIn: Bool { sessionCookie != nil }

    public func forgetSession() { sessionCookie = nil }

    private func makeRequest(_ method: String, _ path: String, json: Any? = nil) throws -> URLRequest {
        guard let url = URL(string: server + path) else { throw SyncError.noServer }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie = sessionCookie {
            req.setValue("\(Self.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        if method != "GET" {
            // Сервер принимает изменяющие запросы только в JSON (защита от CSRF).
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json ?? [String: Any](), options: [.sortedKeys])
        }
        return req
    }

    private func perform(_ req: URLRequest) async throws -> HTTPReply {
        do {
            return try await transport.send(req)
        } catch let e as SyncError {
            throw e
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
    }

    private static func errorInfo(_ body: Data) -> (code: String, message: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return ("", "") }
        return (err["code"] as? String ?? "", err["message"] as? String ?? "")
    }

    private static func dataObject(_ body: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj["data"] as? [String: Any]
    }

    private static func decodeTask(_ any: Any?) throws -> SyncTask {
        guard let any, JSONSerialization.isValidJSONObject(any) else { throw SyncError.badResponse("нет task") }
        let data = try JSONSerialization.data(withJSONObject: any)
        do { return try JSONDecoder().decode(SyncTask.self, from: data) } catch {
            throw SyncError.badResponse("task не читается")
        }
    }

    private static func httpError(_ reply: HTTPReply) -> SyncError {
        let info = errorInfo(reply.body)
        if reply.status == 401 {
            return .unauthorized(info.message.isEmpty ? "Нужно войти заново." : info.message)
        }
        return .http(reply.status, info.code, info.message.isEmpty ? "ошибка \(reply.status)" : info.message)
    }

    /// POST /api/auth/login. Пароль не сохраняется, в памяти остаётся только cookie.
    public func login(password: String) async throws {
        let req = try makeRequest("POST", "/api/auth/login", json: ["password": password])
        let reply = try await perform(req)
        guard reply.status == 200 else { throw Self.httpError(reply) }
        guard let setCookie = reply.header("Set-Cookie"), let token = Self.parseSessionCookie(setCookie) else {
            throw SyncError.badResponse("сервер не выдал cookie сессии")
        }
        sessionCookie = token
    }

    static func parseSessionCookie(_ header: String) -> String? {
        // Несколько Set-Cookie склеиваются через запятую; ищем нужное имя.
        for chunk in header.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            let part = chunk.trimmingCharacters(in: .whitespaces)
            if part.hasPrefix(cookieName + "=") {
                let value = String(part.dropFirst(cookieName.count + 1))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    public func fetchTasks() async throws -> [SyncTask] {
        let reply = try await perform(try makeRequest("GET", "/api/tasks?show_completed=1&show_removed=1"))
        guard reply.status == 200 else {
            if reply.status == 401 { sessionCookie = nil }
            throw Self.httpError(reply)
        }
        guard let data = Self.dataObject(reply.body), let list = data["tasks"] as? [Any] else {
            throw SyncError.badResponse("нет data.tasks")
        }
        return try list.map(Self.decodeTask)
    }

    public func fetchTask(_ id: String) async throws -> SyncTask {
        let reply = try await perform(try makeRequest("GET", "/api/tasks/\(SyncNormalize.id(id))"))
        guard reply.status == 200 else {
            if reply.status == 401 { sessionCookie = nil }
            throw Self.httpError(reply)
        }
        return try Self.decodeTask(Self.dataObject(reply.body)?["task"])
    }

    /// Обычный вызов существующего API: data при 2xx, иначе ошибка.
    public func call(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> [String: Any] {
        let reply = try await perform(try makeRequest(method, path, json: json))
        guard (200..<300).contains(reply.status) else {
            if reply.status == 401 { sessionCookie = nil }
            throw Self.httpError(reply)
        }
        return Self.dataObject(reply.body) ?? [:]
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ any: Any?) throws -> T {
        guard let any, JSONSerialization.isValidJSONObject(any) else { throw SyncError.badResponse("нет данных") }
        do { return try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: any)) } catch {
            throw SyncError.badResponse("данные не читаются")
        }
    }

    public func fetchChaos() async throws -> [ChaosItem] {
        try Self.decode([ChaosItem].self, try await call("GET", "/api/chaos")["chaos"])
    }

    /// Бросает только при сбое транспорта; ответы сервера возвращаются как SyncOutcome.
    public func sync(taskId: String, request: SentRequest) async throws -> SyncOutcome {
        var base: [String: Any] = [:]
        var changes: [String: Any] = [:]
        for (k, v) in request.base { base[k.rawValue] = v.json }
        for (k, v) in request.changes { changes[k.rawValue] = v.json }
        let req = try makeRequest("POST", "/api/sync/tasks/\(SyncNormalize.id(taskId))",
                                  json: ["base": base, "changes": changes])
        let reply = try await perform(req)
        let info = Self.errorInfo(reply.body)
        switch reply.status {
        case 200:
            return .applied(try Self.decodeTask(Self.dataObject(reply.body)?["task"]))
        case 409 where info.code == "sync_conflict":
            let data = Self.dataObject(reply.body)
            let task = try Self.decodeTask(data?["task"])
            let fields = (data?["conflicts"] as? [String] ?? []).compactMap(SyncField.init(rawValue:))
            return .conflict(task, fields)
        case 401:
            sessionCookie = nil
            return .unauthorized(info.message.isEmpty ? "Нужно войти заново." : info.message)
        case 404:
            return .gone(info.message.isEmpty ? "Задачи больше нет на сервере." : info.message)
        case 400..<500:
            return .rejected(reply.status, info.message.isEmpty ? "Сервер не принял правку (\(reply.status))." : info.message)
        default:
            return .serverError(reply.status, info.message.isEmpty ? "Сервер ответил \(reply.status)." : info.message)
        }
    }
}

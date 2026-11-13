import Foundation

// Самопроверка SyncCore против сервера в памяти. Только синтетические данные во временном каталоге.

var failures = 0
var checks = 0

@MainActor func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("  ✗ \(what) (строка \(line))")
    }
}

let T1 = "AAAAAAAA-0000-4000-8000-000000000001"
let t1 = T1.lowercased()
let t2 = "aaaaaaaa-0000-4000-8000-000000000002"
let t3 = "aaaaaaaa-0000-4000-8000-000000000003"
let serverA = "http://127.0.0.1:3100"
let serverB = "http://127.0.0.1:3200"

func makeServer() -> FakeServer {
    let s = FakeServer()
    s.add(SyncTask(id: T1, text: "Синтетика: отчёт", day: "2026-11-14", details: "черновик"))
    s.add(SyncTask(id: t2, text: "Синтетика: звонок", day: ""))
    s.add(SyncTask(id: t3, text: "Синтетика: снятая", day: "2026-11-10", isRemoved: true))
    return s
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-selftest-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor func ready(_ server: FakeServer, _ dir: URL, url: String = serverA) async throws -> SyncEngine {
    let e = try SyncEngine(dataDir: dir, transport: server)
    try e.setServer(url)
    try await e.login(password: server.password)
    try await e.pull()
    return e
}

@MainActor func scenario(_ name: String, _ body: () async throws -> Void) async {
    print("• \(name)")
    do { try await body() } catch {
        failures += 1
        print("  ✗ исключение: \(error.localizedDescription)")
    }
}

func allFileText(_ dir: URL) -> String {
    var out = ""
    let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
    while let u = en?.nextObject() as? URL {
        if let d = try? Data(contentsOf: u), let s = String(data: d, encoding: .utf8) { out += s }
    }
    return out
}

@main
struct SelfTest {
    @MainActor static func main() async {
        await scenario("нормализация значений") {
            check(try SyncNormalize.value(.details, .string("   ")) == .null, "пустые подробности = null")
            check(try SyncNormalize.value(.text, .string("  Тест  ")) == .string("Тест"), "название обрезается")
            check((try? SyncNormalize.value(.text, .string("  "))) == nil, "пустое название отклоняется")
            check((try? SyncNormalize.value(.day, .string("2026-02-30"))) == nil, "несуществующая дата отклоняется")
            check(try SyncNormalize.value(.day, .string("")) == .string(""), "пустой день = без даты")
            check(try SyncNormalize.server("127.0.0.1:3100/путь?x=1") == "http://127.0.0.1:3100", "адрес сервера без пути")
            check((try? SyncNormalize.server("http://example.org:3100")) == nil, "http не на loopback отклоняется")
            check(try SyncNormalize.server("https://Example.org") == "https://example.org", "https разрешён")
            check(try SyncNormalize.server("localhost:3000") == "http://localhost:3000", "localhost разрешён")
            check(SyncAPI.parseSessionCookie("chaos_day_session=abc; Path=/; HttpOnly") == "abc", "cookie читается")
        }

        await scenario("вход и пароль не на диске") {
            let s = makeServer()
            let dir = tempDir()
            let e = try SyncEngine(dataDir: dir, transport: s)
            try e.setServer(serverA)
            do { try await e.login(password: "wrong"); check(false, "неверный пароль должен отклоняться") } catch {
                check(e.connection == .needsLogin("Неверный пароль."), "статус после неверного пароля")
            }
            try await e.login(password: s.password)
            check(e.isLoggedIn, "вход выполнен")
            try await e.pull()
            check(e.tasks.count == 3, "получены три задачи")
            check(e.task(T1)?.id == t1, "UUID в нижнем регистре")
            check(!allFileText(dir).contains(s.password), "пароль не записан в каталог данных")
            check(!allFileText(dir).contains("chaos_day_session"), "cookie не записана в каталог данных")
        }

        await scenario("офлайн: правка сохраняется до сети и переживает перезапуск") {
            let s = makeServer()
            let dir = tempDir()
            let e = try await ready(s, dir)
            try e.setOffline(true)
            try e.edit(t1, .day, .string("2026-11-15"))
            try e.edit(t1, .text, .string("  Синтетика: отчёт v2 "))
            let before = s.requests.count
            let r = await e.flush()
            check(r.stopped != nil && s.requests.count == before, "в офлайне ничего не отправлено")
            check(e.connection == .offlineManual, "статус офлайн")
            check(e.task(t1)?.day == "2026-11-15" && e.task(t1)?.text == "Синтетика: отчёт v2", "локальная копия показывает правку")
            check(s.tasks[t1]?.task.day == "2026-11-14", "сервер не изменён")
            check(allFileText(dir).contains("\"day\""), "очередь на диске с ключами полей")

            let e2 = try SyncEngine(dataDir: dir, transport: s)
            check(e2.queuedCount == 1 && e2.isOffline, "после перезапуска очередь и офлайн на месте")
            check(!e2.isLoggedIn, "после перезапуска сессии нет")
            try e2.setOffline(false)
            let r0 = await e2.flush()
            check(r0.stopped != nil && e2.queuedCount == 1, "без входа очередь не отправляется и не теряется")
            try await e2.login(password: s.password)
            let r2 = await e2.flush()
            check(r2.applied == [t1] && e2.queuedCount == 0, "очередь отправлена")
            check(s.tasks[t1]?.task.day == "2026-11-15" && s.tasks[t1]?.task.text == "Синтетика: отчёт v2", "сервер получил правку")
            check(s.revision(t1) == 2, "одна ревизия на одну отправку")
        }

        await scenario("потерянный ответ: повтор подтверждается без новой ревизии") {
            let s = makeServer()
            let dir = tempDir()
            let e = try await ready(s, dir)
            try e.edit(t1, .day, .string("2026-11-16"))
            s.dropNextResponse = true
            let r = await e.flush()
            check(r.stopped != nil, "отправка остановлена потерей ответа")
            check(e.pendingEdit(t1)?.inflight != nil, "запрос помечен как неподтверждённый")
            check(s.revision(t1) == 2, "сервер применил правку")
            if case .unreachable = e.connection {} else { check(false, "статус «нет связи»") }

            let e2 = try SyncEngine(dataDir: dir, transport: s)
            try await e2.login(password: s.password)
            let r2 = await e2.flush()
            check(r2.applied == [t1] && e2.queuedCount == 0, "повтор подтверждён")
            check(s.revision(t1) == 2, "повтор не увеличил ревизию")
            let last = s.syncBodies.last
            check((last?["changes"] as? [String: String])?["day"] == "2026-11-16", "повтор дословный")
        }

        await scenario("потерянный ответ, затем новая правка того же поля") {
            let s = makeServer()
            let e = try await ready(s, tempDir())
            try e.edit(t1, .day, .string("2026-11-16"))
            s.dropNextResponse = true
            await e.flush()
            try e.edit(t1, .day, .string("2026-11-17"))
            try await e.login(password: s.password)
            let r = await e.flush()
            check(r.conflicts.isEmpty && e.queuedCount == 0, "без ложного конфликта")
            check(s.tasks[t1]?.task.day == "2026-11-17", "на сервере последняя правка")
        }

        await scenario("потерянный ответ, затем возврат к прежнему значению") {
            let s = makeServer()
            let e = try await ready(s, tempDir())
            try e.edit(t1, .day, .string("2026-11-16"))
            s.dropNextResponse = true
            await e.flush()
            try e.edit(t1, .day, .string("2026-11-14"))
            check(e.queuedCount == 1, "возврат не теряется, пока исход неизвестен")
            let r = await e.flush()
            check(r.stopped == nil && e.queuedCount == 0, "очередь пуста")
            check(s.tasks[t1]?.task.day == "2026-11-14", "на сервере прежнее значение")
        }

        await scenario("правка и возврат без сети не оставляют очереди") {
            let s = makeServer()
            let e = try await ready(s, tempDir())
            try e.edit(t2, .details, .string("временно"))
            try e.edit(t2, .details, .string(" "))
            check(e.pending.isEmpty, "очередь пуста")
        }

        await scenario("конфликт: показ обеих версий, ничего не применено, «Моя версия»") {
            let s = makeServer()
            let e = try await ready(s, tempDir())
            s.externalEdit(t1, .day, .string("2026-11-20"))
            try e.edit(t1, .day, .string("2026-11-15"))
            try e.edit(t1, .text, .string("Синтетика: отчёт (Mac)"))
            let r = await e.flush()
            check(r.conflicts == [t1], "конфликт обнаружен")
            let p = e.pendingEdit(t1)
            check(p?.status == .conflict && p?.conflictFields == [.day], "конфликт по дню")
            check(p?.serverTask?.day == "2026-11-20" && p?.changes[.day] == .string("2026-11-15"), "видны обе версии")
            check(s.tasks[t1]?.task.text == "Синтетика: отчёт", "при конфликте не применено ни одно поле")
            check(s.revision(t1) == 2, "ревизия не изменилась при конфликте")
            let again = await e.flush()
            check(again.applied.isEmpty && e.pendingEdit(t1)?.status == .conflict, "конфликт ждёт решения")
            try e.resolve(t1, .day, .mine)
            let r2 = await e.flush()
            check(r2.applied == [t1] && e.queuedCount == 0, "«Моя версия» отправлена")
            check(s.tasks[t1]?.task.day == "2026-11-15" && s.tasks[t1]?.task.text == "Синтетика: отчёт (Mac)", "сервер принял обе правки")
        }

        await scenario("конфликт: «Версия сервера»") {
            let s = makeServer()
            let e = try await ready(s, tempDir())
            s.externalEdit(t2, .details, .string("с другого клиента"))
            try e.edit(t2, .details, .string("с Mac"))
            await e.flush()
            try e.resolve(t2, .details, .server)
            check(e.pending.isEmpty, "правка убрана")
            check(e.task(t2)?.details == "с другого клиента", "показана версия сервера")
        }

        await scenario("удалённая задача (404) ждёт решения") {
            let s = makeServer()
            let e = try await ready(s, tempDir())
            try e.edit(t2, .text, .string("Синтетика: звонок 2"))
            s.tasks[t2] = nil
            let r = await e.flush()
            check(r.gone == [t2] && e.pendingEdit(t2)?.status == .gone, "статус «нет на сервере»")
            await e.flush()
            check(e.pendingEdit(t2) != nil, "правка не удалена без решения")
            try e.discard(t2)
            check(e.pending.isEmpty, "правка убрана явным решением")
        }

        await scenario("сессия истекла (401), сеть пропала, сервер упал") {
            let s = makeServer()
            let e = try await ready(s, tempDir())
            try e.edit(t1, .day, .string(""))
            s.killSessions()
            await e.flush()
            if case .needsLogin = e.connection {} else { check(false, "статус «нужен вход»") }
            check(e.queuedCount == 1, "очередь сохранена после 401")
            try await e.login(password: s.password)
            s.down = true
            await e.flush()
            if case .unreachable = e.connection {} else { check(false, "статус «нет связи»") }
            check(e.queuedCount == 1, "очередь сохранена при обрыве сети")
            s.down = false
            s.failNextWith500 = true
            await e.flush()
            if case .serverError = e.connection {} else { check(false, "статус «ошибка сервера»") }
            check(e.queuedCount == 1, "очередь сохранена после 500")
            let r = await e.flush()
            check(r.applied == [t1] && s.tasks[t1]?.task.day == "", "день снят после восстановления")
        }

        await scenario("смена сервера: очередь остаётся у своего сервера") {
            let a = makeServer()
            let dir = tempDir()
            let e = try await ready(a, dir)
            try e.setOffline(true)
            try e.edit(t1, .day, .string("2026-11-18"))
            try e.setOffline(false)
            try e.setServer(serverB)
            check(e.pending.isEmpty && e.tasks.isEmpty, "у нового сервера своя копия")
            check(e.otherServersWithPending().map(\.count) == [1], "видна очередь прежнего сервера")
            try await e.login(password: a.password)
            let before = a.syncBodies.count
            await e.flush()
            check(a.syncBodies.count == before, "чужая очередь не ушла на новый сервер")
            try e.setServer(serverA)
            check(e.queuedCount == 1, "очередь вернулась с сервером")
        }

        await scenario("«Записать», разбор и выполнение — только при связи") {
            let s = makeServer()
            let e = try await ready(s, tempDir())
            let item = try await e.capture("  Синтетика: купить батарейки ")
            check(e.chaos.map(\.text) == ["Синтетика: купить батарейки"], "строка записана в место хаоса")
            let task = try await e.chaosToTask(item.id, day: "2026-11-14")
            check(e.chaos.isEmpty && e.task(task.id)?.day == "2026-11-14", "строка стала задачей")
            let note = try await e.capture("Синтетика: мысль")
            try await e.chaosToNote(note.id)
            check(e.chaos.isEmpty && s.notes == 1, "строка стала заметкой")
            try await e.setCompleted(t1, true)
            check(e.task(t1)?.isCompleted == true && s.tasks[t1]?.task.isCompleted == true, "задача выполнена")
            try await e.setCompleted(t1, false)
            check(e.task(t1)?.isCompleted == false, "задача возвращена в работу")
            try e.setOffline(true)
            check(!e.canUseServer, "в офлайне действия сети недоступны")
            let before = s.requests.count
            do { _ = try await e.capture("не уйдёт"); check(false, "запись в офлайне должна отклоняться") } catch {
                check(s.requests.count == before && e.chaos.isEmpty, "в офлайне запрос не отправлен и не имитирован")
            }
        }

        print("\(checks - failures)/\(checks) проверок, ошибок: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

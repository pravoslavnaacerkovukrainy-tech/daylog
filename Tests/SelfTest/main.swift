// Самопроверка ядра «Хаос Дня». Использует производственный DiaryStore, без копий логики.
// Только нейтральные искусственные примеры. Запуск: ./test.sh
import Foundation
import Darwin
import Combine

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL (строка \(line)): \(message)")
    }
}

@discardableResult
func expectError(_ message: String, line: Int = #line, _ body: () throws -> Void) -> Error? {
    do {
        try body()
        check(false, "\(message): ожидалась ошибка", line: line)
        return nil
    } catch {
        check(true, message)
        return error
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do {
        try body()
    } catch {
        failures += 1
        print("  FAIL: неожиданная ошибка \(error)")
    }
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

// MARK: Изолированный каталог

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment
let root: URL = {
    if CommandLine.arguments.count > 1 { return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    if let p = env["DAYLOG_DATA_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
    return fm.temporaryDirectory.appendingPathComponent("daylog-selftest-\(UUID().uuidString)", isDirectory: true)
}()
let realDefault = DiaryStore.defaultDirectory(environment: [:]).standardizedFileURL.path
guard !root.standardizedFileURL.path.hasPrefix(realDefault) else {
    print("Отказ: тесты не должны работать в обычном каталоге данных (\(realDefault)).")
    exit(2)
}
try? fm.createDirectory(at: root, withIntermediateDirectories: true)
print("Каталог тестов: \(root.path)")

func freshDir(_ name: String) -> URL {
    let d = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

let cal = Calendar.current
func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
let day1 = date(2030, 3, 10, 0, 0)
let day2 = date(2030, 3, 11, 0, 0)

// MARK: Тесты

test("Каталог данных: DAYLOG_DATA_DIR переопределяет Application Support") {
    let custom = DiaryStore.defaultDirectory(environment: ["DAYLOG_DATA_DIR": "/tmp/daylog-x"])
    check(custom.path == "/tmp/daylog-x", "ожидался /tmp/daylog-x, получено \(custom.path)")
    let normal = DiaryStore.defaultDirectory(environment: [:])
    check(normal.path.hasSuffix("Application Support/Daylog"), "обычный путь: \(normal.path)")
}

test("Добавление, автоматическое время и перезагрузка с диска") {
    let dir = freshDir("add")
    let store = DiaryStore(directory: dir)
    try store.load()
    check(store.entries.isEmpty, "новое хранилище пустое")
    let before = Date()
    let e = try store.add(text: "  Полил цветы  ")
    check(e.text == "Полил цветы", "текст обрезан по краям")
    check(e.context == nil, "контекст пустой по умолчанию")
    check(abs(e.timestamp.timeIntervalSince(before)) < 5, "время поставлено автоматически")
    try store.add(text: "Прогулка", context: "дошёл до парка", at: date(2030, 3, 10, 9, 15))

    let reloaded = DiaryStore(directory: dir)
    try reloaded.load()
    check(reloaded.entries == store.entries, "после перезапуска данные совпадают")
    check(reloaded.entries.count == 2, "две записи")
    check(fm.fileExists(atPath: dir.appendingPathComponent("entries.json").path), "файл entries.json создан")
}

test("Пустой текст отклоняется и ничего не пишет") {
    let dir = freshDir("empty")
    let store = DiaryStore(directory: dir)
    try store.load()
    expectError("пустая запись") { try store.add(text: "   \n ") }
    check(store.entries.isEmpty, "в памяти ничего нет")
    check(!fm.fileExists(atPath: store.fileURL.path), "файл не создан")
}

test("Изменение времени меняет порядок и день") {
    let dir = freshDir("order")
    let store = DiaryStore(directory: dir)
    try store.load()
    let a = try store.add(text: "Запись А", at: date(2030, 3, 10, 9, 0))
    let b = try store.add(text: "Запись Б", at: date(2030, 3, 10, 11, 0))
    check(store.entriesOnDay(day1).map(\.id) == [a.id, b.id], "сначала ранние")

    try store.update(id: b.id, text: b.text, context: nil, timestamp: date(2030, 3, 10, 8, 0))
    check(store.entriesOnDay(day1).map(\.id) == [b.id, a.id], "после правки времени Б раньше А")

    try store.update(id: a.id, text: a.text, context: nil, timestamp: date(2030, 3, 11, 7, 30))
    check(store.entriesOnDay(day1).map(\.id) == [b.id], "в первом дне осталась Б")
    check(store.entriesOnDay(day2).map(\.id) == [a.id], "А перенесена на следующий день")

    let reloaded = DiaryStore(directory: dir)
    try reloaded.load()
    check(reloaded.entriesOnDay(day2).first?.timestamp == date(2030, 3, 11, 7, 30), "новое время сохранено на диске")
}

test("Изменение текста и «На чём остановился»") {
    let dir = freshDir("edit")
    let store = DiaryStore(directory: dir)
    try store.load()
    let e = try store.add(text: "Читал книгу", at: date(2030, 3, 10, 20, 0))
    let u = try store.update(id: e.id, text: "Читал книгу о море", context: "глава 4, страница 51", timestamp: e.timestamp)
    check(u.text == "Читал книгу о море", "текст обновлён")
    check(u.context == "глава 4, страница 51", "контекст добавлен")
    let cleared = try store.update(id: e.id, text: u.text, context: "   ", timestamp: e.timestamp)
    check(cleared.context == nil, "пустой контекст становится nil")
    expectError("пустой текст при правке") { try store.update(id: e.id, text: "", context: nil, timestamp: e.timestamp) }
    check(store.entries.first?.text == "Читал книгу о море", "после отклонённой правки текст прежний")
    expectError("правка несуществующей записи") { try store.update(id: UUID(), text: "x", context: nil, timestamp: Date()) }
}

test("Поиск по всем дням, включая контекст") {
    let dir = freshDir("search")
    let store = DiaryStore(directory: dir)
    try store.load()
    let a = try store.add(text: "Проверил почту", at: date(2030, 3, 10, 9, 0))
    let b = try store.add(text: "Ремонт велосипеда", context: "осталось поменять цепь", at: date(2030, 3, 11, 18, 0))
    let c = try store.add(text: "Снова почта", at: date(2030, 3, 11, 19, 0))
    check(store.search("ПОЧТ").map(\.id) == [c.id, a.id], "регистр не важен, все дни, сначала новые")
    check(store.search("цепь").map(\.id) == [b.id], "поиск по «На чём остановился»")
    check(store.search("  ").isEmpty, "пустой запрос — нет результатов")
    check(store.search("кино").isEmpty, "нет совпадений")
}

test("Удаление и возврат") {
    let dir = freshDir("delete")
    let store = DiaryStore(directory: dir)
    try store.load()
    let a = try store.add(text: "Помыл посуду", at: date(2030, 3, 10, 13, 0))
    let b = try store.add(text: "Позвонил в сервис", at: date(2030, 3, 10, 14, 0))
    let removed = try store.delete(id: a.id)
    check(removed == a, "удалённая запись возвращена вызову")
    check(store.entries.map(\.id) == [b.id], "в памяти осталась одна")
    let reloaded = DiaryStore(directory: dir)
    try reloaded.load()
    check(reloaded.entries.map(\.id) == [b.id], "удаление сохранено на диске")
    try store.restore(removed)
    check(store.entries.map(\.id) == [a.id, b.id], "запись возвращена на своё место")
    expectError("удаление несуществующей") { try store.delete(id: UUID()) }
}

test("Экспорт JSON (версия, разбор) и Markdown") {
    let dir = freshDir("export")
    let store = DiaryStore(directory: dir)
    try store.load()
    try store.add(text: "Завтрак", at: date(2030, 3, 10, 9, 30))
    try store.add(text: "Встреча с соседом", context: "договорились о субботе", at: date(2030, 3, 11, 17, 5))

    let data = try store.exportJSON(now: date(2030, 3, 12, 10, 0))
    let parsed = try DiaryStore.parseExport(data)
    check(parsed == store.entries, "экспорт JSON разбирается обратно без потерь")
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    check(obj?["format"] as? String == "daylog", "поле format")
    check(obj?["version"] as? Int == 1, "поле version = 1")
    check(obj?["exportedAt"] != nil, "поле exportedAt")

    let md = try store.exportMarkdown(now: date(2030, 3, 12, 10, 0))
    check(md.hasPrefix("# Хаос Дня — экспорт"), "заголовок Markdown")
    check(md.contains("- **09:30** — Завтрак"), "время и текст")
    check(md.contains("- **17:05** — Встреча с соседом"), "вторая запись")
    check(md.contains("  - На чём остановился: договорились о субботе"), "контекст")
    let r1 = md.range(of: "Завтрак"), r2 = md.range(of: "Встреча")
    check(r1 != nil && r2 != nil && r1!.lowerBound < r2!.lowerBound, "дни по порядку")
    check(md.contains("## Воскресенье, 10 марта 2030"), "заголовок дня по-русски: \(md)")

    expectError("чужой JSON не принимается") { _ = try DiaryStore.parseExport(Data("{\"a\":1}".utf8)) }
}

test("Повреждённый файл: ошибка видна, файл не перезаписывается") {
    let dir = freshDir("corrupt")
    let file = dir.appendingPathComponent("entries.json")
    let garbage = Data("{ это не json".utf8)
    try garbage.write(to: file)
    let store = DiaryStore(directory: dir)
    expectError("загрузка повреждённого файла") { try store.load() }
    check(store.isBlocked, "хранилище заблокировано")
    check(store.blockReason?.contains(file.path) == true, "в причине указан путь")
    let err = expectError("добавление в заблокированное хранилище") { try store.add(text: "Тест") }
    if case .storeBlocked = err as? DiaryError {} else { check(false, "ожидалась storeBlocked, получено \(String(describing: err))") }
    expectError("экспорт из заблокированного хранилища") { _ = try store.exportJSON() }
    check((try? Data(contentsOf: file)) == garbage, "файл остался байт-в-байт")
}

test("Неизвестная версия формата: блокировка без перезаписи") {
    let dir = freshDir("version")
    let file = dir.appendingPathComponent("entries.json")
    let future = Data("{\"format\":\"daylog\",\"version\":99,\"entries\":[]}".utf8)
    try future.write(to: file)
    let store = DiaryStore(directory: dir)
    let err = expectError("загрузка версии 99") { try store.load() }
    if case .unsupportedFormat = err as? DiaryError {} else { check(false, "ожидалась unsupportedFormat") }
    expectError("запись запрещена") { try store.add(text: "Тест") }
    check((try? Data(contentsOf: file)) == future, "файл не тронут")
}

test("Каталог только для чтения: ошибка записи, память не меняется") {
    if geteuid() == 0 {
        print("  (пропущено: root игнорирует права доступа)")
        return
    }
    let dir = freshDir("readonly")
    let store = DiaryStore(directory: dir)
    try store.load()
    let a = try store.add(text: "Исходная запись", at: date(2030, 3, 10, 10, 0))
    let snapshot = store.entries
    let fileBefore = try Data(contentsOf: store.fileURL)

    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

    let err = expectError("добавление при запрете записи") { try store.add(text: "Не должна сохраниться") }
    if case .writeFailed = err as? DiaryError {} else { check(false, "ожидалась writeFailed, получено \(String(describing: err))") }
    check(store.entries == snapshot, "добавление не попало в память")
    expectError("правка при запрете записи") { try store.update(id: a.id, text: "Изменено", context: nil, timestamp: a.timestamp) }
    check(store.entries == snapshot, "правка не попала в память")
    expectError("удаление при запрете записи") { try store.delete(id: a.id) }
    check(store.entries == snapshot, "удаление не попало в память")
    check((try? Data(contentsOf: store.fileURL)) == fileBefore, "файл на диске прежний")

    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    try store.add(text: "После восстановления прав")
    check(store.entries.count == 2, "после восстановления прав запись работает")
}

// MARK: План на день (версия формата 2)

func fileVersion(_ url: URL) -> Int? {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj["version"] as? Int
}

test("Совместимость: файл версии 1 читается, без планов остаётся версией 1") {
    let dir = freshDir("v1")
    let file = dir.appendingPathComponent("entries.json")
    let v1 = """
    {"format":"daylog","version":1,"entries":[{"id":"11111111-1111-1111-1111-111111111111",\
    "text":"Старая запись","context":"страница 3","timestamp":"2030-03-10T06:30:00Z",\
    "createdAt":"2030-03-10T06:30:00Z","updatedAt":"2030-03-10T06:30:00Z"}]}
    """
    try Data(v1.utf8).write(to: file)
    let original = try Data(contentsOf: file)
    let store = DiaryStore(directory: dir)
    try store.load()
    check(store.entries.count == 1, "старая запись загружена")
    check(store.entries.first?.text == "Старая запись", "текст старой записи")
    check(store.entries.first?.context == "страница 3", "контекст старой записи")
    check(store.entries.first?.planID == nil, "у старой записи нет связи с планом")
    check(store.plans.isEmpty, "планов нет")
    check((try? Data(contentsOf: file)) == original, "загрузка не переписывает файл")

    try store.add(text: "Новая запись без плана", at: date(2030, 3, 10, 12, 0))
    check(fileVersion(file) == 1, "без планов файл пишется версией 1")

    try store.addPlan(text: "Купить хлеб", day: day1)
    check(fileVersion(file) == 2, "с планами файл пишется версией 2")
    let reloaded = DiaryStore(directory: dir)
    try reloaded.load()
    check(reloaded.entries.contains { $0.id.uuidString == "11111111-1111-1111-1111-111111111111" }, "старая запись сохранилась")
    check(reloaded.plans.count == 1, "план сохранился")
}

test("План: добавить, изменить, перенести, удалить, перезапуск") {
    let dir = freshDir("plans")
    let store = DiaryStore(directory: dir)
    try store.load()
    expectError("пустой пункт плана") { try store.addPlan(text: "  ", day: day1) }
    check(store.plans.isEmpty, "пустой пункт не добавлен")

    let p = try store.addPlan(text: "Позвонить в сервис", day: date(2030, 3, 10, 18, 40))
    check(p.day == "2030-03-10", "день плана — календарный день: \(p.day)")
    check(store.plansOnDay(day1).map(\.id) == [p.id], "план виден в своём дне")
    check(store.plansOnDay(day2).isEmpty, "в другом дне его нет")

    let edited = try store.updatePlan(id: p.id, text: "Позвонить в сервис до обеда", day: day1)
    check(edited.text == "Позвонить в сервис до обеда", "текст изменён")
    try store.updatePlan(id: p.id, text: edited.text, day: day2)
    check(store.plansOnDay(day1).isEmpty, "после переноса первый день пуст")
    check(store.plansOnDay(day2).map(\.id) == [p.id], "план перенесён на следующий день")

    let reloaded = DiaryStore(directory: dir)
    try reloaded.load()
    check(reloaded.plans == store.plans, "планы одинаковы после перезапуска")

    try store.deletePlan(id: p.id)
    check(store.plans.isEmpty, "план удалён")
    let reloaded2 = DiaryStore(directory: dir)
    try reloaded2.load()
    check(reloaded2.plans.isEmpty, "удаление сохранено на диске")
    expectError("изменение удалённого плана") { try store.updatePlan(id: p.id, text: "x", day: day1) }
}

test("Отметка плана: ровно одна запись в момент отметки, без дублей") {
    let dir = freshDir("complete")
    let store = DiaryStore(directory: dir)
    try store.load()
    let p = try store.addPlan(text: "Полить цветы", day: day1)
    let other = try store.addPlan(text: "Отнести книги", day: day2)
    let doneAt = date(2030, 3, 10, 14, 5)

    let result = try store.completePlan(id: p.id, now: doneAt)
    check(result.entry.text == "Полить цветы", "текст записи = текст плана")
    check(result.entry.timestamp == doneAt, "время записи = момент отметки")
    check(result.entry.planID == p.id, "запись ссылается на план")
    check(result.plan.completedAt == doneAt, "план отмечен в момент отметки")
    check(result.plan.entryID == result.entry.id, "план ссылается на запись")
    check(store.entries.count == 1, "создана ровно одна запись")
    check(store.plansOnDay(day1).first?.isCompleted == true, "план выполнен")

    let err = expectError("повторная отметка") { try store.completePlan(id: p.id, now: date(2030, 3, 10, 15, 0)) }
    check((err as? DiaryError) == .planAlreadyCompleted, "ошибка planAlreadyCompleted")
    check(store.entries.count == 1, "дубля нет")
    let err2 = expectError("правка выполненного пункта") { try store.updatePlan(id: p.id, text: "x", day: day1) }
    check((err2 as? DiaryError) == .planIsCompleted, "ошибка planIsCompleted")

    // План на завтра, отмеченный сегодня: запись — в день отметки, план остаётся в своём дне.
    let r2 = try store.completePlan(id: other.id, now: date(2030, 3, 10, 16, 0))
    check(store.entriesOnDay(day1).map(\.id).contains(r2.entry.id), "запись в дне отметки")
    check(store.plansOnDay(day2).first?.id == other.id, "план остался в своём дне")

    let reloaded = DiaryStore(directory: dir)
    try reloaded.load()
    check(reloaded.entries == store.entries, "записи после перезапуска")
    check(reloaded.plans == store.plans, "планы со связями после перезапуска")
}

test("Вернуть в план: неизменённая запись убирается, изменённая остаётся") {
    let dir = freshDir("reopen")
    let store = DiaryStore(directory: dir)
    try store.load()
    let p = try store.addPlan(text: "Вынести мусор", day: day1)
    let r = try store.completePlan(id: p.id, now: date(2030, 3, 10, 9, 0))
    check(store.linkedEntryIsUnchanged(forPlan: p.id), "запись ещё не меняли")
    let outcome = try store.reopenPlan(id: p.id, now: date(2030, 3, 10, 9, 1))
    check(outcome == .removedEntry(r.entry), "запись убрана: \(outcome)")
    check(store.entries.isEmpty, "в дневнике пусто")
    check(store.plan(id: p.id)?.isCompleted == false, "план снова открыт")
    check(store.plan(id: p.id)?.entryID == nil, "ссылки нет")
    expectError("повторный возврат") { try store.reopenPlan(id: p.id) }

    let r2 = try store.completePlan(id: p.id, now: date(2030, 3, 10, 10, 0))
    try store.update(id: r2.entry.id, text: "Вынес мусор и пакеты", context: nil, timestamp: r2.entry.timestamp,
                     now: date(2030, 3, 10, 10, 5))
    check(!store.linkedEntryIsUnchanged(forPlan: p.id), "запись изменена")
    let outcome2 = try store.reopenPlan(id: p.id, now: date(2030, 3, 10, 10, 6))
    if case .keptEntry = outcome2 {} else { check(false, "ожидалось keptEntry, получено \(outcome2)") }
    check(store.entries.count == 1, "изменённая запись осталась")
    check(store.entries.first?.text == "Вынес мусор и пакеты", "её текст не тронут")
    check(store.entries.first?.planID == nil, "связь с планом снята")
    check(store.plan(id: p.id)?.isCompleted == false, "план открыт")
}

test("Удаление: план и запись не тянут друг друга за собой") {
    let dir = freshDir("relations")
    let store = DiaryStore(directory: dir)
    try store.load()
    let p = try store.addPlan(text: "Забрать посылку", day: day1)
    let r = try store.completePlan(id: p.id, now: date(2030, 3, 10, 11, 0))

    let removedPlan = try store.deletePlan(id: p.id)
    check(store.entries.count == 1, "удаление плана сохраняет запись")
    check(store.entries.first?.planID == nil, "у записи снята ссылка")
    try store.restorePlan(removedPlan)
    check(store.plan(id: p.id)?.entryID == r.entry.id, "возврат плана восстанавливает ссылку")
    check(store.entries.first?.planID == p.id, "и обратную ссылку")

    let removedEntry = try store.delete(id: r.entry.id)
    check(store.plan(id: p.id)?.isCompleted == true, "удаление записи оставляет план выполненным")
    check(store.plan(id: p.id)?.entryID == nil, "но без ссылки на запись")
    try store.restore(removedEntry)
    check(store.plan(id: p.id)?.entryID == r.entry.id, "возврат записи восстанавливает ссылку")

    try store.delete(id: r.entry.id)
    let outcome = try store.reopenPlan(id: p.id)
    check(outcome == .noEntry, "без записи возврат в план ничего не удаляет")
    check(store.entries.isEmpty, "записей нет")

    let reloaded = DiaryStore(directory: dir)
    try reloaded.load()
    check(reloaded.plans == store.plans && reloaded.entries == store.entries, "состояние на диске совпадает")
}

test("Экспорт JSON и Markdown с планами") {
    let dir = freshDir("export-plans")
    let store = DiaryStore(directory: dir)
    try store.load()
    try store.add(text: "Завтрак", at: date(2030, 3, 10, 9, 30))
    let open = try store.addPlan(text: "Купить батарейки", day: day1)
    let done = try store.addPlan(text: "Полить цветы", day: day1)
    try store.completePlan(id: done.id, now: date(2030, 3, 10, 14, 5))
    _ = open

    let data = try store.exportJSON(now: date(2030, 3, 12, 10, 0))
    let doc = try DiaryStore.parseExportDocument(data)
    check(doc.version == 2, "экспорт с планами — версия 2")
    check(doc.plans == store.plans, "планы в JSON без потерь")
    check(doc.entries == store.entries, "записи в JSON без потерь (со ссылками)")

    let md = try store.exportMarkdown(now: date(2030, 3, 12, 10, 0))
    check(md.contains("План:"), "раздел плана")
    check(md.contains("- [ ] Купить батарейки"), "открытый пункт")
    check(md.contains("- [x] Полить цветы (выполнено 10 марта 2030 в 14:05)\n"), "выполненный пункт одной фразой: \(md)")
    check(md.contains("Записи:"), "раздел записей")
    check(md.contains("- **14:05** — Полить цветы"), "запись, созданная отметкой")
    check(md.contains("- **09:30** — Завтрак"), "обычная запись")
}

test("Сбой записи: ни план, ни записи не меняются") {
    if geteuid() == 0 {
        print("  (пропущено: root игнорирует права доступа)")
        return
    }
    let dir = freshDir("readonly-plans")
    let store = DiaryStore(directory: dir)
    try store.load()
    let p = try store.addPlan(text: "Открытый пункт", day: day1)
    let q = try store.addPlan(text: "Выполненный пункт", day: day1)
    try store.completePlan(id: q.id, now: date(2030, 3, 10, 12, 0))
    let entriesBefore = store.entries
    let plansBefore = store.plans
    let fileBefore = try Data(contentsOf: store.fileURL)

    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

    expectError("добавление плана") { try store.addPlan(text: "Новый", day: day1) }
    expectError("отметка плана") { try store.completePlan(id: p.id, now: date(2030, 3, 10, 13, 0)) }
    expectError("возврат в план") { try store.reopenPlan(id: q.id) }
    expectError("перенос плана") { try store.updatePlan(id: p.id, text: "x", day: day2) }
    expectError("удаление плана") { try store.deletePlan(id: q.id) }
    check(store.entries == entriesBefore, "записи в памяти не изменились")
    check(store.plans == plansBefore, "планы в памяти не изменились")
    check(store.plan(id: p.id)?.isCompleted == false, "неудачная отметка не оставила план выполненным")
    check((try? Data(contentsOf: store.fileURL)) == fileBefore, "файл на диске прежний")
}

// MARK: Заметки — модель и документ v3

test("Документ: версия 3 только при наличии заметок") {
    let note = DiaryNote(title: "T", body: "B", createdAt: Date(), updatedAt: Date())
    check(DiaryDocument(entries: [], plans: [], notes: [note]).version == 3, "с заметкой → v3")
    check(DiaryDocument(entries: [], plans: []).version == 1, "без ничего → v1")
}
test("Документ: round-trip записей, планов и заметок") {
    let note = DiaryNote(title: "Загол", body: "Тело\nвторая строка", createdAt: diaryNormalized(Date()), updatedAt: diaryNormalized(Date()), pinned: true)
    let doc = DiaryDocument(entries: [], plans: [], notes: [note])
    let data = try DiaryJSON.encoder().encode(doc)
    let back = try DiaryJSON.decode(data)
    check(back.notes == [note], "заметки совпали после round-trip")
}
test("Документ: encode без заметок не пишет ключ notes и даёт ≤ v2") {
    let data = try DiaryJSON.encoder().encode(DiaryDocument(entries: [], plans: []))
    let s = String(data: data, encoding: .utf8)!
    check(!s.contains("\"notes\""), "ключ notes отсутствует: \(s)")
}
test("Документ: v2-файл читается как notes=[]") {
    let v2 = #"{"format":"daylog","version":2,"entries":[],"plans":[]}"#.data(using: .utf8)!
    check(try DiaryJSON.decode(v2).notes.isEmpty, "notes по умолчанию пусты")
}
test("Документ: будущая версия 8 отвергается как неподдерживаемая") {
    let future = #"{"format":"daylog","version":8,"entries":[],"notes":[]}"#.data(using: .utf8)!
    let err = expectError("v8 не поддерживается") { _ = try DiaryJSON.decode(future) }
    check((err as? DiaryError) == .unsupportedFormat("версия 8, приложение понимает версию до 7"), "сообщение про версию: \(String(describing: err))")
}

test("Документ: версия 7 только при новых полях пересмотра") {
    let plain = DayPlan(text: "Обычная", day: "", createdAt: day1, updatedAt: day1)
    check(DiaryDocument(entries: [], plans: [plain]).version == 4, "блок полей без данных версию не поднимает")
    var promised = plain; promised.organization = TaskOrganization(promisedTo: "Коллега")
    check(DiaryDocument(entries: [], plans: [promised]).version == 7, "непустое «Кому обещано» даёт v7")
    var atRisk = plain; atRisk.organization = TaskOrganization(atRisk: true)
    check(DiaryDocument(entries: [], plans: [atRisk]).version == 7, "отметка угрозы даёт v7")
    var removed = plain; removed.organization = TaskOrganization(status: .removed, removalReason: "Уже не нужно")
    check(DiaryDocument(entries: [], plans: [removed]).version == 7, "снятие с причиной даёт v7")
    var emptyPromise = plain; emptyPromise.organization = TaskOrganization(promisedTo: "   ")
    check(DiaryDocument(entries: [], plans: [emptyPromise]).version == 4, "пробелы в адресате версию не поднимают")
    let chaos = ChaosItem(text: "Строка", createdAt: day1)
    check(DiaryDocument(entries: [], plans: [plain], chaos: [chaos]).version == 6, "место хаоса по-прежнему даёт v6")
    check(DiaryDocument(entries: [], plans: [promised], chaos: [chaos]).version == 7, "поля пересмотра сильнее корзины")
}

// MARK: Заметки — хранилище

test("Заметки: add/update/delete/restore и пустое тело") {
    let dir = freshDir("notes-crud"); let s = DiaryStore(directory: dir); try s.load()
    let n = try s.addNote(title: "A", body: "текст")
    check(s.notes.count == 1, "добавлена")
    expectError("пустое тело") { _ = try s.addNote(title: "x", body: "   ") }
    let u = try s.updateNote(id: n.id, title: "A2", body: "текст2")
    check(u.title == "A2" && u.updatedAt >= n.updatedAt, "обновлена")
    let d = try s.deleteNote(id: n.id); check(s.notes.isEmpty, "удалена")
    try s.restoreNote(d); check(s.notes.count == 1, "восстановлена")
    let s2 = DiaryStore(directory: dir); try s2.load()
    check(s2.notes.count == 1, "сохранилось на диск")
}
test("Заметки: заголовок может быть пустым") {
    let s = DiaryStore(directory: freshDir("notes-empty-title")); try s.load()
    let n = try s.addNote(title: "   ", body: "есть тело")
    check(n.title.isEmpty, "пустой заголовок допустим")
}
test("Заметки: порядок — закреплённые сверху, затем по updatedAt") {
    let s = DiaryStore(directory: freshDir("notes-order")); try s.load()
    let a = try s.addNote(title: "a", body: "1", now: Date(timeIntervalSince1970: 100))
    let b = try s.addNote(title: "b", body: "2", now: Date(timeIntervalSince1970: 200))
    _ = try s.setPinned(id: a.id, true)
    let ids = s.sortedNotes().map { $0.id }
    check(ids == [a.id, b.id], "закреплённая a впереди более новой b")
    check(s.notes.first(where: { $0.id == a.id })!.updatedAt == a.updatedAt, "setPinned не трогает updatedAt")
}
test("Заметки: поиск по title и body, без учёта регистра") {
    let s = DiaryStore(directory: freshDir("notes-search")); try s.load()
    _ = try s.addNote(title: "Контакт техника", body: "позвонить")
    _ = try s.addNote(title: "другое", body: "СЗІ отчёт")
    check(s.searchNotes("техник").count == 1, "по заголовку")
    check(s.searchNotes("сзі").count == 1, "по телу, регистр")
}
test("Заметки: мутация на заблокированном хранилище отвергается") {
    let dir = freshDir("notes-blocked")
    try Data("не json".utf8).write(to: dir.appendingPathComponent("entries.json"))
    let s = DiaryStore(directory: dir); _ = try? s.load()
    check(s.isBlocked, "хранилище заблокировано")
    expectError("add на блоке") { _ = try s.addNote(title: "x", body: "y") }
}

// MARK: Заметки — экспорт

test("Markdown: секция заметок, порядок, многострочное тело") {
    let s = DiaryStore(directory: freshDir("md-notes")); try s.load()
    let a = try s.addNote(title: "Первая", body: "строка1\nстрока2")
    _ = try s.addNote(title: "Вторая", body: "x")
    _ = try s.setPinned(id: a.id, true)
    let md = try s.exportMarkdown()
    check(md.contains("## Заметки"), "есть секция")
    check(md.range(of: "Первая")!.lowerBound < md.range(of: "Вторая")!.lowerBound, "закреплённая выше")
    check(md.contains("строка1") && md.contains("строка2"), "многострочное тело не потеряно")
}
test("Markdown: без заметок секции нет") {
    let s = DiaryStore(directory: freshDir("md-none")); try s.load()
    _ = try s.add(text: "запись", context: nil)
    check(!(try s.exportMarkdown().contains("## Заметки")), "секции нет")
}
test("JSON-экспорт включает заметки") {
    let s = DiaryStore(directory: freshDir("json-notes")); try s.load()
    _ = try s.addNote(title: "Экс", body: "тело")
    let doc = try DiaryStore.parseExportDocument(s.exportJSON())
    check(doc.notes.count == 1 && doc.notes.first?.title == "Экс", "заметка в JSON-экспорте")
}

// MARK: Заметки — фиксы по код-ревью

test("Markdown: тело заметки не ломает структуру экспорта") {
    let s = DiaryStore(directory: freshDir("md-escape")); try s.load()
    _ = try s.addNote(title: "A", body: "```\nнезакрытая ограда")
    _ = try s.addNote(title: "ЗаголовокB", body: "## строка-похожая-на-заголовок")
    let md = try s.exportMarkdown()
    check(md.contains("### A"), "заголовок заметки A на месте")
    check(md.contains("### ЗаголовокB"), "заголовок заметки B не поглощён")
    check(md.contains("\\## строка-похожая-на-заголовок"), "строка '##' в теле экранирована")
    check(md.components(separatedBy: "```").count % 2 == 1, "ограды кода сбалансированы (нечётное число разделителей)")
}

// MARK: Markdown в заметках — разбор для просмотра

func plain(_ s: AttributedString) -> String { String(s.characters) }

test("NoteMarkdown: пустой и пробельный текст → нет блоков, без краша") {
    check(NoteMarkdown.parse("").isEmpty, "пустая строка")
    check(NoteMarkdown.parse("   \n\t\n\n").isEmpty, "только пробелы и переводы строк")
}

test("NoteMarkdown: заголовки H1–H6, не-заголовки") {
    let blocks = NoteMarkdown.parse("# Один\n## Два\n### Три\n#### Четыре\n##### Пять\n###### Шесть")
    check(blocks == [.heading(level: 1, text: "Один"), .heading(level: 2, text: "Два"),
                     .heading(level: 3, text: "Три"), .heading(level: 4, text: "Четыре"),
                     .heading(level: 5, text: "Пять"), .heading(level: 6, text: "Шесть")], "шесть уровней: \(blocks)")
    check(NoteMarkdown.parse("####### семь") == [.paragraph("####### семь")], "7 решёток — абзац")
    check(NoteMarkdown.parse("#тег без пробела") == [.paragraph("#тег без пробела")], "хештег — не заголовок")
    check(NoteMarkdown.parse("## Итог ##") == [.heading(level: 2, text: "Итог")], "закрывающие решётки сняты")
    check(NoteMarkdown.parse("# Язык C#") == [.heading(level: 1, text: "Язык C#")], "C# не обрезан")
}

test("NoteMarkdown: абзацы и сохранённые переносы, CRLF") {
    check(NoteMarkdown.parse("строка1\nстрока2") == [.paragraph("строка1\nстрока2")], "перенос внутри абзаца сохранён")
    check(NoteMarkdown.parse("а\n\nб") == [.paragraph("а"), .paragraph("б")], "пустая строка разделяет абзацы")
    check(NoteMarkdown.parse("а\r\nб\rв") == [.paragraph("а\nб\nв")], "CRLF/CR нормализованы")
}

test("NoteMarkdown: огороженный код — буквально, с языком, пробелы целы") {
    let src = "До\n```swift\n    let x = 1   \n\n<b>**не жирный**</b>\n\tтаб\n```\nПосле"
    let blocks = NoteMarkdown.parse(src)
    check(blocks.count == 3, "абзац, код, абзац: \(blocks)")
    check(blocks[1] == .code(language: "swift", code: "    let x = 1   \n\n<b>**не жирный**</b>\n\tтаб", closed: true),
          "содержимое кода буквально: \(blocks[1])")
    check(NoteMarkdown.parse("~~~\n# не заголовок\n~~~") == [.code(language: nil, code: "# не заголовок", closed: true)],
          "ограда ~~~ без языка")
    check(NoteMarkdown.parse("````\n```\n````") == [.code(language: nil, code: "```", closed: true)],
          "короткая ограда внутри длинной — содержимое")
}

test("NoteMarkdown: незакрытая ограда не теряет текст") {
    let blocks = NoteMarkdown.parse("Текст\n```\nкод\n# всё ещё код")
    check(blocks == [.paragraph("Текст"), .code(language: nil, code: "код\n# всё ещё код", closed: false)],
          "код до конца, closed=false: \(blocks)")
    check(NoteMarkdown.parse("```") == [.code(language: nil, code: "", closed: false)], "одна ограда без краша")
    check(NoteMarkdown.parse("```inline``` код") == [.paragraph("```inline``` код")], "``` с ` в info — не ограда")
}

test("NoteMarkdown: списки, вложенность, нумерация, задачи только для чтения") {
    let src = "- один\n- [ ] купить\n- [x] сделано\n  - вложенный\n    * глубже\n1. первый\n1. второй\n5) пятый"
    guard case let .list(items)? = NoteMarkdown.parse(src).first, NoteMarkdown.parse(src).count == 1 else {
        check(false, "ожидался один список: \(NoteMarkdown.parse(src))"); return
    }
    check(items.count == 8, "8 пунктов: \(items.count)")
    check(items[0] == MarkdownListItem(level: 0, ordered: false, number: nil, task: nil, text: "один"), "обычный пункт")
    check(items[1].task == false && items[1].text == "купить", "[ ] → task=false")
    check(items[2].task == true && items[2].text == "сделано", "[x] → task=true")
    check(items[3].level == 1 && items[3].text == "вложенный", "уровень 1")
    check(items[4].level == 2 && items[4].text == "глубже", "уровень 2")
    check(items[5].level == 0 && items[5].ordered && items[5].number == 1, "нумерация с 1")
    check(items[6].number == 2, "1. 1. → 1, 2 (последовательно)")
    check(items[7].number == 3, "далее 3")
    check(NoteMarkdown.parse("- [X]") == [.list([MarkdownListItem(level: 0, ordered: false, number: nil, task: true, text: "")])],
          "пустая выполненная задача")
    check(NoteMarkdown.parse("- [ ]без пробела").first == .list([MarkdownListItem(level: 0, ordered: false, number: nil, task: nil, text: "[ ]без пробела")]),
          "без пробела — не задача")
}

test("NoteMarkdown: список после абзаца, ленивое продолжение, ложные списки") {
    check(NoteMarkdown.parse("Покупки:\n- хлеб") == [.paragraph("Покупки:"), .list([MarkdownListItem(level: 0, ordered: false, number: nil, task: nil, text: "хлеб")])],
          "маркированный пункт прерывает абзац")
    check(NoteMarkdown.parse("Было\n1984. Оруэлл") == [.paragraph("Было\n1984. Оруэлл")], "число в середине абзаца — не список")
    check(NoteMarkdown.parse("**жирный** текст") == [.paragraph("**жирный** текст")], "** в начале — не маркер")
    check(NoteMarkdown.parse("-5 градусов") == [.paragraph("-5 градусов")], "минус без пробела — не маркер")
    let lazy = NoteMarkdown.parse("- пункт\nпродолжение")
    check(lazy == [.list([MarkdownListItem(level: 0, ordered: false, number: nil, task: nil, text: "пункт\nпродолжение")])],
          "продолжение строки пункта: \(lazy)")
    let loose = NoteMarkdown.parse("- а\n\n- б\n\nабзац")
    check(loose.count == 2, "пустая строка между пунктами — тот же список, потом абзац: \(loose)")
}

test("NoteMarkdown: цитаты (вложенные блоки), линии, таблица как текст") {
    check(NoteMarkdown.parse("> мысль\n> # заголовок") == [.quote([.paragraph("мысль"), .heading(level: 1, text: "заголовок")])],
          "цитата с блоками внутри")
    check(NoteMarkdown.parse(">> вложенная") == [.quote([.quote([.paragraph("вложенная")])])], "вложенная цитата")
    let deep = NoteMarkdown.parse(String(repeating: ">", count: 50) + " глубоко")
    check(!deep.isEmpty, "очень глубокая цитата без краша")
    check(NoteMarkdown.parse("---") == [.rule] && NoteMarkdown.parse("* * *") == [.rule] && NoteMarkdown.parse("___") == [.rule], "линии")
    let t = NoteMarkdown.parse("| а | б |\n|---|:-:|\n| 1 | 2 |\nпосле")
    check(t.first == .table(["| а | б |", "|---|:-:|", "| 1 | 2 |"]), "таблица — литеральные строки: \(t)")
    check(NoteMarkdown.parse("a | b").first == .paragraph("a | b"), "просто черта — абзац")
}

test("NoteMarkdown.inline: жирный, курсив, зачёркнутый, код") {
    let s = NoteMarkdown.inline("**ж** *к* ~~з~~ `к<о>д`")
    check(plain(s) == "ж к з к<о>д", "разметка снята, код буквально: \(plain(s))")
    check(s.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "есть жирный")
    check(s.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }, "есть курсив")
    check(s.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }, "есть зачёркнутый")
    check(s.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "есть код")
    check(plain(NoteMarkdown.inline("а\nб")) == "а\nб", "перенос строки сохранён")
}

test("NoteMarkdown.inline: HTML, картинки и незакрытое — литеральный текст") {
    check(plain(NoteMarkdown.inline("<script>alert(1)</script>")) == "<script>alert(1)</script>", "HTML — текст")
    check(plain(NoteMarkdown.inline("<img src=x onerror=y>")) == "<img src=x onerror=y>", "img-тег — текст")
    check(plain(NoteMarkdown.inline("a `b <c>")) == "a `b <c>", "незакрытый ` и угловые скобки видны")
    check(plain(NoteMarkdown.inline("**незакрытый")) == "**незакрытый", "незакрытый ** виден")
    let img = NoteMarkdown.inline("![кот](https://example.com/cat.png)")
    check(plain(img) == "![кот](https://example.com/cat.png)", "картинка — литерал: \(plain(img))")
    check(img.runs.allSatisfy { $0.imageURL == nil }, "у картинки нет imageURL — ничего не загружается")
    check(plain(NoteMarkdown.inline("2 < 3 > 1")) == "2 < 3 > 1", "сравнения целы")
    check(plain(NoteMarkdown.inline("путь C:\\temp")).contains("temp"), "обратный слеш без краша")
}

test("NoteMarkdown: ссылки — только http/https, остальные сняты") {
    let ok = NoteMarkdown.inline("[сайт](https://example.com/a)")
    check(plain(ok) == "сайт", "текст ссылки")
    check(ok.runs.contains { $0.link?.absoluteString == "https://example.com/a" }, "https-ссылка оставлена")
    let auto = NoteMarkdown.inline("<https://example.com>")
    check(auto.runs.contains { $0.link?.host == "example.com" }, "автоссылка <https://…>")
    for bad in ["[x](javascript:alert(1))", "[x](file:///etc/hosts)", "[x](data:text/html,hi)",
                "[x](daylog://open)", "[x](mailto:a@example.com)", "[x](relative/path)", "<javascript:alert(1)>"] {
        let s = NoteMarkdown.inline(bad)
        check(s.runs.allSatisfy { $0.link == nil }, "нет ссылки: \(bad)")
        check(!plain(s).isEmpty, "текст виден: \(bad)")
    }
    check(NoteMarkdown.isSafeLink(URL(string: "HTTPS://Example.com")!), "регистр схемы не важен")
    check(NoteMarkdown.isSafeLink(URL(string: "http://example.com")!), "http разрешён")
    check(!NoteMarkdown.isSafeLink(URL(string: "http:///path")!), "без хоста — нет")
    check(!NoteMarkdown.isSafeLink(URL(string: "ftp://example.com")!), "ftp — нет")
}

test("NoteMarkdown: большой текст разбирается без краша") {
    var big = ""
    for n in 0..<3000 { big += "- пункт \(n) **ж**\n" + (n % 100 == 0 ? "```\nкод\n```\n" : "") }
    let blocks = NoteMarkdown.parse(big)
    check(!blocks.isEmpty, "блоки есть")
}

test("Заметки: сырой Markdown сохраняется в DiaryStore байт-в-байт") {
    let dir = freshDir("notes-markdown")
    let s = DiaryStore(directory: dir); try s.load()
    let md = "# Заголовок\n\n- [ ] задача\n- [x] готово\n\n```sh\n  echo \"<b>\"   \n\tтаб\n```\n> цитата\n\n[ссылка](https://example.com) **жирный**"
    let n = try s.addNote(title: "Md", body: md)
    check(n.body == md, "тело при добавлении без изменений")
    let s2 = DiaryStore(directory: dir); try s2.load()
    check(s2.notes.first?.body == md, "после перезагрузки тело совпадает")
    let md2 = md + "\n\n```\nнезакрытая ограда"
    _ = try s2.updateNote(id: n.id, title: "Md", body: md2)
    let s3 = DiaryStore(directory: dir); try s3.load()
    check(s3.notes.first?.body == md2, "после правки тело совпадает")
    check(s3.notes.first?.title == "Md", "заголовок — обычный текст")
}

test("Markdown folder export: пустой экспорт, повторный запуск и таймзона") {
    let parent = freshDir("md-folder-parent")
    let dir = freshDir("md-folder-empty")
    let store = DiaryStore(directory: dir)
    try store.load()
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!
    let now = cal.date(from: DateComponents(year: 2024, month: 7, day: 1, hour: 3, minute: 5))!

    let first = try store.exportMarkdownFolder(parentDirectory: parent, now: now, calendar: cal)
    let readme = try String(contentsOf: first.readmeURL, encoding: .utf8)
    check(readme.contains("Записей: 0"), "README пишет ноль записей")
    check(readme.contains("Europe/Kyiv"), "README включает таймзону")
    check(readme.contains("UTC+03:00"), "смещение в момент now соответствует DST")
    let archiveDoc = try DiaryStore.parseExportDocument(try Data(contentsOf: first.archiveURL))
    check(archiveDoc.entries == store.entries && archiveDoc.plans == store.plans && archiveDoc.notes == store.notes,
          "полный JSON-архив совпадает с состоянием хранилища")

    let second = try store.exportMarkdownFolder(parentDirectory: parent, now: now, calendar: cal)
    check(first.folderURL != second.folderURL, "повторный экспорт создаёт новую папку")

    let invalidDayDir = freshDir("md-folder-invalid-day")
    let invalidPlan = DayPlan(id: UUID(), text: "X", day: "a/b", createdAt: now, updatedAt: now)
    let invalidDoc = DiaryDocument(entries: [], plans: [invalidPlan], notes: [])
    let invalidJSON = try DiaryJSON.encoder().encode(invalidDoc)
    try invalidJSON.write(to: invalidDayDir.appendingPathComponent("entries.json"), options: .atomic)
    let invalidStore = DiaryStore(directory: invalidDayDir)
    try invalidStore.load()
    let invalidExport = try invalidStore.exportMarkdownFolder(parentDirectory: parent, now: now, calendar: cal)
    let invalidPath = invalidExport.daysDirectoryURL.appendingPathComponent("invalid-day-0.md")
    check(FileManager.default.fileExists(atPath: invalidPath.path), "невалидный день получает ограниченное имя файла")
    let invalidText = try String(contentsOf: invalidPath, encoding: .utf8)
    check(invalidText.contains("a/b"), "невалидный ключ сохраняется как исходный текст")
}

test("Markdown folder export: план/заметка/битовый контроль и сборка мусора") {
    let parent = freshDir("md-folder-parent-2")
    let dir = freshDir("md-folder-real")
    let store = DiaryStore(directory: dir)
    try store.load()
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = cal.date(from: DateComponents(year: 2030, month: 3, day: 10, hour: 23, minute: 30))!
    let entryAt = cal.date(from: DateComponents(year: 2030, month: 3, day: 10, hour: 7, minute: 45))!
    let planAt = cal.date(from: DateComponents(year: 2030, month: 3, day: 10, hour: 8, minute: 0))!

    _ = try store.add(text: "Утренний кофе", context: "планировалось в 7:00", at: entryAt, now: now)
    let plan = try store.addPlan(text: "Проверить почту", day: planAt, calendar: cal, now: now)
    _ = try store.completePlan(id: plan.id, now: cal.date(from: DateComponents(year: 2030, month: 3, day: 10, hour: 9, minute: 15))!)
    let noteBody = "# Вложенный заголовок\n\n```md\nне закрыта ограда\n"
    let note = try store.addNote(title: "   ", body: noteBody)
    let beforeSource = try Data(contentsOf: store.fileURL)

    let result = try store.exportMarkdownFolder(parentDirectory: parent, now: now, calendar: cal)
    let notePath = result.notesDirectoryURL.appendingPathComponent("\(note.id.uuidString).md")
    let noteData = try Data(contentsOf: notePath)
    check(noteData.suffix(note.body.utf8.count) == Data(note.body.utf8), "raw note body сохранён без преобразования")
    let dayText = try String(contentsOf: result.daysDirectoryURL.appendingPathComponent("2030-03-10.md"), encoding: .utf8)
    check(dayText.contains("- [x] Проверить почту"), "выполненный план отмечен в export")
    check(dayText.contains("Проверить почту"), "текст плана сохранился в Markdown")
    let afterSource = try Data(contentsOf: store.fileURL)
    check(afterSource == beforeSource, "исходный файл не меняется после успешного экспорта")

    let duplicateDir = freshDir("md-folder-duplicate")
    let sameID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let dupDoc = DiaryDocument(entries: [], plans: [], notes: [
        DiaryNote(id: sameID, title: "A", body: "1", createdAt: now, updatedAt: now),
        DiaryNote(id: sameID, title: "B", body: "2", createdAt: now.addingTimeInterval(1), updatedAt: now.addingTimeInterval(1))
    ])
    try DiaryJSON.encoder().encode(dupDoc).write(to: duplicateDir.appendingPathComponent("entries.json"), options: .atomic)
    let dupStore = DiaryStore(directory: duplicateDir)
    try dupStore.load()
    let beforeDupParent = try fm.contentsOfDirectory(atPath: parent.path)
    expectError("дубликат UUID в записи заметок") { _ = try dupStore.exportMarkdownFolder(parentDirectory: parent, now: now, calendar: cal) }
    let afterDupParent = try fm.contentsOfDirectory(atPath: parent.path)
    check(afterDupParent == beforeDupParent, "ошибка записи не оставляет мусор в родительской папке")

    let blockedDir = freshDir("md-folder-blocked")
    try Data("не json".utf8).write(to: blockedDir.appendingPathComponent("entries.json"), options: .atomic)
    let blockedStore = DiaryStore(directory: blockedDir)
    _ = try? blockedStore.load()
    let beforeBlockedParent = try fm.contentsOfDirectory(atPath: parent.path)
    expectError("заблокированное хранилище") { _ = try blockedStore.exportMarkdownFolder(parentDirectory: parent, now: now, calendar: cal) }
    let afterBlockedParent = try fm.contentsOfDirectory(atPath: parent.path)
    check(afterBlockedParent == beforeBlockedParent, "блокированное хранилище не создаёт папку")
}

test("Папочный экспорт: завершение плана, многострочный контекст, полный архив и повтор") {
    let dir = freshDir("folder-readability-store")
    let parent = freshDir("folder-readability-parent")
    let store = DiaryStore(directory: dir); try store.load()
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let at = utc.date(from: DateComponents(year: 2030, month: 3, day: 10, hour: 8, minute: 0))!
    _ = try store.add(text: "Первая строка\n# продолжение\n```", context: "Продолжить\n# здесь", at: at, now: at)
    let done = try store.addPlan(text: "Готовая задача", day: at, calendar: utc, now: at)
    _ = try store.completePlan(id: done.id, now: at.addingTimeInterval(3600))
    _ = try store.addPlan(text: "Открытая задача\n# шаг", day: at, calendar: utc, now: at)
    _ = try store.addNote(title: "Общая заметка", body: "# Текст\n\n**сырой Markdown**", now: at)
    let before = try Data(contentsOf: store.fileURL)
    let result = try store.exportMarkdownFolder(parentDirectory: parent, now: at, calendar: utc)
    let day = try String(contentsOf: result.daysDirectoryURL.appendingPathComponent("2030-03-10.md"), encoding: .utf8)
    check(day.contains("- [x] Готовая задача\n  Выполнено: 10 марта 2030, 09:00"), "статус и фактическое время завершения")
    check(day.contains("- [ ] Открытая задача\n  \\# шаг"), "незавершённый план и вложенное продолжение")
    check(day.contains("- 08:00 — Первая строка\n  \\# продолжение\n  \\`\\`\\`\n  - На чём остановился: Продолжить\n    \\# здесь"), "контекст следует после всего текста записи и сохраняет переносы")
    check(!day.contains("\n# продолжение") && !day.contains("\n```"), "текст записи не создаёт самостоятельных блоков")
    let doc = try DiaryStore.parseExportDocument(Data(contentsOf: result.archiveURL))
    check(doc.entries == store.entries && doc.plans == store.plans && doc.notes == store.notes, "непустой архив сохраняет все модели и связи")
    check(doc.exportedAt == diaryNormalized(at), "дата архива соответствует экспорту")
    let sentinel = result.folderURL.appendingPathComponent("мой-файл.txt")
    try Data("сохранить".utf8).write(to: sentinel)
    let firstReadme = try Data(contentsOf: result.readmeURL)
    let second = try store.exportMarkdownFolder(parentDirectory: parent, now: at, calendar: utc)
    check(second.folderURL != result.folderURL, "одинаковое now не приводит к повторному использованию папки")
    check(try Data(contentsOf: sentinel) == Data("сохранить".utf8), "пользовательский файл первого экспорта сохранён")
    check(try Data(contentsOf: result.readmeURL) == firstReadme, "первый экспорт не перезаписан")
    check(try Data(contentsOf: store.fileURL) == before, "повторные экспорты не меняют хранилище")
}

test("Папочный экспорт: календарный день и часы используют один часовой пояс") {
    let store = DiaryStore(directory: freshDir("folder-zone-store")); try store.load()
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
    var kyiv = utc; kyiv.timeZone = TimeZone(identifier: "Europe/Kyiv")!
    let at = utc.date(from: DateComponents(year: 2024, month: 7, day: 1, hour: 21, minute: 15))!
    _ = try store.add(text: "После полуночи", at: at, now: at)
    let planDay = kyiv.date(from: DateComponents(year: 2024, month: 7, day: 3, hour: 12))!
    _ = try store.addPlan(text: "Только план", day: planDay, calendar: kyiv, now: at)
    let result = try store.exportMarkdownFolder(parentDirectory: freshDir("folder-zone-parent"), now: at, calendar: kyiv)
    let files = Set(try fm.contentsOfDirectory(atPath: result.daysDirectoryURL.path))
    check(files == ["2024-07-02.md", "2024-07-03.md"], "местный день и день только с планом присутствуют")
    let day = try String(contentsOf: result.daysDirectoryURL.appendingPathComponent("2024-07-02.md"), encoding: .utf8)
    check(day.contains("- 00:15 — После полуночи"), "часы совпадают с местным днём")
    let plan = try String(contentsOf: result.daysDirectoryURL.appendingPathComponent("2024-07-03.md"), encoding: .utf8)
    check(plan.contains("- [ ] Только план"), "день без событий сохраняет план")
}

test("Папочный экспорт: некорректные ключи не конфликтуют и не выходят за папку") {
    let dir = freshDir("folder-malformed-store")
    let parent = freshDir("folder-malformed-parent")
    let keys = ["a/b", "a?b", ".", "..", "2030-02-30", "2030-03-10\n", String(repeating: "z", count: 500), "/tmp/outside", "2030-03-11"]
    let plans = keys.enumerated().map { DayPlan(text: "План \($0.offset)", day: $0.element, createdAt: day1, updatedAt: day1) }
    try DiaryJSON.encoder().encode(DiaryDocument(entries: [], plans: plans)).write(to: dir.appendingPathComponent("entries.json"))
    let store = DiaryStore(directory: dir); try store.load()
    let result = try store.exportMarkdownFolder(parentDirectory: parent)
    let files = try fm.contentsOfDirectory(atPath: result.daysDirectoryURL.path)
    check(files.count == keys.count, "все разные ключи сохраняются без замещения")
    check(files.contains("2030-03-11.md"), "корректная дата сохраняет имя")
    check(!files.contains("2030-02-30.md"), "несуществующая календарная дата распознана")
    check(!files.contains("2030-03-10\n.md"), "перевод строки не попадает в имя")
    var text = ""
    for file in files {
        check(file.utf8.count < 100 && file.hasSuffix(".md"), "имя ограничено и пригодно для файла")
        text += try String(contentsOf: result.daysDirectoryURL.appendingPathComponent(file), encoding: .utf8)
    }
    for index in keys.indices { check(text.contains("План \(index)"), "план \(index) не потерян") }
    check(text.contains("дата не распознана"), "неверной дате не приписывается текущее число")
    check(try fm.contentsOfDirectory(atPath: parent.path) == [result.folderURL.lastPathComponent], "нет файлов снаружи нового экспорта")
    let archive = try DiaryStore.parseExportDocument(Data(contentsOf: result.archiveURL))
    check(Set(archive.plans.map(\.day)) == Set(keys), "архив сохраняет исходные некорректные ключи")
}

test("Папочный экспорт: одинаковые опасные заголовки и исходный Markdown") {
    let store = DiaryStore(directory: freshDir("folder-titles-store")); try store.load()
    let title = "../[ссылка](file:///tmp/a)\r\n# <img src=x> **текст** `код`"
    let body = "# Вложенный заголовок\n\n<literal>\n\n```swift\n  let value = 1"
    let first = try store.addNote(title: title, body: body)
    let second = try store.addNote(title: title, body: "второе тело")
    let result = try store.exportMarkdownFolder(parentDirectory: freshDir("folder-titles-parent"))
    let files = Set(try fm.contentsOfDirectory(atPath: result.notesDirectoryURL.path))
    check(files == [first.id.uuidString + ".md", second.id.uuidString + ".md"], "файлы заметок используют разные UUID")
    let data = try Data(contentsOf: result.notesDirectoryURL.appendingPathComponent(first.id.uuidString + ".md"))
    check(data.suffix(first.body.utf8.count) == Data(first.body.utf8), "Markdown, HTML-текст и незакрытая ограда сохранены побайтно")
    let text = String(decoding: data, as: UTF8.self)
    let header = String(text.dropLast(first.body.count))
    check(!header.contains("\r") && !header.contains("\n# <img"), "переносы заголовка не создают секции")
    check(header.contains("&lt;img src=x&gt;") && header.contains("\\*\\*текст\\*\\*"), "метаданные читаются буквально")
    let readme = try String(contentsOf: result.readmeURL, encoding: .utf8)
    check(!readme.contains("<img") && !readme.contains("\r"), "оглавление нейтрализует HTML и CR")
    check(readme.contains("Заметки/\(first.id.uuidString).md") && readme.contains("Заметки/\(second.id.uuidString).md"), "обе заметки доступны через оглавление")
}

test("Папочный экспорт: недоступная папка и ошибка внутри staging сохраняют источник") {
    let dir = freshDir("folder-failure-store")
    let store = DiaryStore(directory: dir); try store.load()
    _ = try store.add(text: "Без изменений", at: day1)
    let before = try Data(contentsOf: store.fileURL)
    let parent = freshDir("folder-failure-parent")
    let missing = parent.appendingPathComponent("нет-папки")
    expectError("не создаёт отсутствующего родителя") { _ = try store.exportMarkdownFolder(parentDirectory: missing) }
    check(!fm.fileExists(atPath: missing.path), "отсутствующая папка не создана")
    let regularFile = parent.appendingPathComponent("файл.txt")
    try Data("не каталог".utf8).write(to: regularFile)
    expectError("родитель является файлом") { _ = try store.exportMarkdownFolder(parentDirectory: regularFile) }
    check(try Data(contentsOf: regularFile) == Data("не каталог".utf8), "обычный файл не затронут")
    let readOnly = freshDir("folder-readonly")
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
    expectError("папка только для чтения") { _ = try store.exportMarkdownFolder(parentDirectory: readOnly) }
    check(try fm.contentsOfDirectory(atPath: readOnly.path).isEmpty, "ошибка доступа не оставляет staging")
    check(try Data(contentsOf: store.fileURL) == before, "ошибки назначения не меняют источник")
}

test("Органайзер: ленивое обновление v3 с точной резервной копией") {
    let dir = freshDir("organizer-migration")
    let legacy = DiaryDocument(entries: [], plans: [DayPlan(text: "Старый план", day: "2030-03-10", createdAt: day1, updatedAt: day1)],
                               notes: [DiaryNote(title: "Старая заметка", body: "# Исходный текст", createdAt: day1, updatedAt: day1)])
    let original = try DiaryJSON.encoder().encode(legacy)
    let file = dir.appendingPathComponent("entries.json")
    try original.write(to: file)
    let store = DiaryStore(directory: dir); try store.load()
    check(try Data(contentsOf: file) == original, "загрузка не меняет старый файл")
    check(store.projects.isEmpty && store.plans[0].taskArea == .personal && store.plans[0].taskStatus == .ready, "старые планы доступны без обязательных новых полей")
    let project = try store.saveProject(title: "Отчёт", outcome: "Согласованный документ", area: .work, uncertainty: "Формат", reviewDate: day2)
    let upgraded = try DiaryJSON.decode(Data(contentsOf: file))
    check(upgraded.version == 4 && upgraded.projects.first?.id == project.id, "новые данные пишутся как v4")
    check(upgraded.plans == legacy.plans && upgraded.notes == legacy.notes, "старые объекты и идентификаторы сохранены")
    let backups = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("entries-before-organizer-") }
    check(backups.count == 1, "создана резервная копия до перехода")
    check(try Data(contentsOf: backups[0]) == original, "резервная копия побайтно соответствует старому файлу")
    _ = try store.saveProject(id: project.id, title: project.title, outcome: project.outcome, area: .personal, uncertainty: "Уточнено", reviewDate: nil)
    check(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("entries-before-organizer-") }.count == 1, "следующие сохранения не создают лишних копий миграции")
    let reloaded = DiaryStore(directory: dir); try reloaded.load()
    check(reloaded.projects.first?.area == .personal && reloaded.notes == legacy.notes, "повторная загрузка v4 сохраняет новый и старый контекст")
}

test("Органайзер: входящие, ожидание и три независимые даты") {
    let store = DiaryStore(directory: freshDir("organizer-task")); try store.load()
    let inbox = try store.addTask(text: "Уточнить требования", organization: TaskOrganization(area: .work, status: .inbox), now: day1)
    check(inbox.day.isEmpty && inbox.taskStatus == .inbox && inbox.taskArea == .work, "быстрый ввод без обязательного дня")
    let project = try store.saveProject(title: "Отчёт", outcome: "Отправлен согласованный отчёт", area: .work, uncertainty: "Какие данные нужны?", reviewDate: day2)
    let due = date(2030, 3, 15, 12, 0)
    let metadata = TaskOrganization(area: .personal, projectID: project.id, status: .waiting,
                                    waitingFor: "Ответ коллеги", reviewDate: day2, deadline: due, details: "Три вопроса")
    let updated = try store.updateTask(id: inbox.id, text: inbox.text, plannedDay: day1, organization: metadata)
    check(updated.id == inbox.id && updated.projectID == project.id && updated.taskArea == .work, "разбор сохраняет идентификатор и сферу проекта")
    check(updated.day == DiaryDay.key(day1) && updated.organization?.reviewDate == day2, "день работы и пересмотр независимы")
    check(updated.organization?.deadline == cal.startOfDay(for: due), "срок результата задаётся отдельно")
    check(updated.taskStatus == .waiting && updated.organization?.waitingFor == "Ответ коллеги", "ожидание сохраняет условие продолжения")
    expectError("ожидающая задача не становится следующим шагом") { try store.setNextAction(projectID: project.id, taskID: inbox.id) }
    var ready = metadata; ready.status = .ready
    _ = try store.updateTask(id: inbox.id, text: inbox.text, plannedDay: nil, organization: ready)
    try store.setNextAction(projectID: project.id, taskID: inbox.id)
    check(store.projects.first?.nextActionID == inbox.id && store.plans.first?.day == "", "следующий шаг не требует назначения даты")
    let completed = try store.completePlan(id: inbox.id, now: date(2030, 3, 12, 10, 15))
    check(store.projects.first?.nextActionID == nil, "выполнение освобождает место для следующего шага")
    check(completed.entry.planID == inbox.id && completed.plan.entryID == completed.entry.id, "задача связана с записью дневника")
    check(completed.entry.timestamp == date(2030, 3, 12, 10, 15), "событие создаётся в фактическое время выполнения")
    _ = try store.reopenPlan(id: inbox.id)
    check(store.entries.isEmpty && !store.plans[0].isCompleted, "возврат задачи сохраняет прежние правила дневника")
    expectError("чужой следующий шаг не принимается") {
        let other = try store.addTask(text: "Личное", organization: TaskOrganization())
        try store.setNextAction(projectID: project.id, taskID: other.id)
    }
}

test("Органайзер: проект, следующий шаг и удаление связей") {
    let store = DiaryStore(directory: freshDir("organizer-relations")); try store.load()
    let project = try store.saveProject(title: "Результат", outcome: "Готовый результат", area: .work, uncertainty: "", reviewDate: nil)
    let task = try store.addTask(text: "Первый шаг", organization: TaskOrganization(projectID: project.id))
    try store.setNextAction(projectID: project.id, taskID: task.id)
    expectError("открытый проект нельзя завершить с открытой задачей") { try store.setProjectArchived(id: project.id, archived: true) }
    _ = try store.deletePlan(id: task.id)
    check(store.projects[0].nextActionID == nil, "удаление задачи очищает следующий шаг")
    try store.restorePlan(task)
    _ = try store.saveProject(id: project.id, title: project.title, outcome: project.outcome, area: .personal, uncertainty: "", reviewDate: nil)
    check(store.plans[0].taskArea == .personal, "изменение сферы проекта обновляет его задачи")
    try store.deleteProject(id: project.id)
    check(store.plans.count == 1 && store.plans[0].projectID == nil, "удаление проекта сохраняет задачу без висячей ссылки")
    let archived = try store.saveProject(title: "Завершённый", outcome: "Результат", area: .personal, uncertainty: "", reviewDate: nil)
    try store.setProjectArchived(id: archived.id, archived: true)
    expectError("нельзя добавить задачу в завершённый проект") { _ = try store.addTask(text: "Новая", organization: TaskOrganization(projectID: archived.id)) }
}

test("Органайзер: экспорт всех метаданных и проектов") {
    let store = DiaryStore(directory: freshDir("organizer-export")); try store.load()
    let project = try store.saveProject(title: "Проект", outcome: "Результат", area: .work, uncertainty: "Уточнить формат", reviewDate: day2)
    let task = try store.addTask(text: "Без дня", organization: TaskOrganization(projectID: project.id, status: .waiting,
                               waitingFor: "Ответ", reviewDate: day2, deadline: day1, details: "Материалы"))
    let archive = try DiaryStore.parseExportDocument(store.exportJSON())
    check(archive.projects == store.projects && archive.plans.first == task, "JSON хранит все поля органайзера")
    let result = try store.exportMarkdownFolder(parentDirectory: freshDir("organizer-export-parent"))
    let folderArchive = try DiaryStore.parseExportDocument(Data(contentsOf: result.archiveURL))
    check(folderArchive.projects == store.projects && folderArchive.plans == store.plans, "папочный архив включает проекты и новые задачи")
    check(try fm.contentsOfDirectory(atPath: result.daysDirectoryURL.path).isEmpty, "задаче без дня не выдумывается дата")
    let human = try String(contentsOf: result.folderURL.appendingPathComponent("Органайзер.md"), encoding: .utf8)
    check(human.contains("Уточнить формат") && human.contains("Ожидаю") && human.contains("Ответ"), "ожидания и неопределённость читаются в Markdown")
    let single = try store.exportMarkdown()
    check(single.contains("Органайзер") && single.contains("Без дня") && single.contains("Результат"), "единый Markdown также включает новые данные")
}

test("Место хаоса: запись не становится задачей, заметкой или дневником") {
    let dir = freshDir("chaos-place")
    let store = DiaryStore(directory: dir); try store.load()
    let later = date(2030, 3, 10, 9, 0)
    let early = date(2030, 3, 10, 8, 0)
    let plain = try store.addChaosItem(text: "  Идея без места  ", now: early)
    let urgent = try store.addChaosItem(text: "Черновик обещан, а ответа нет", urgent: true, now: later)
    check(store.chaos.count == 2 && store.plans.isEmpty && store.notes.isEmpty && store.entries.isEmpty, "корзина не создаёт задачу, заметку и дневник")
    check(store.sortedChaos().map(\.id) == [urgent.id, plain.id], "срочное стоит первым")
    check(plain.text == "Идея без места", "пробелы по краям снимаются")
    let reloaded = DiaryStore(directory: dir); try reloaded.load()
    check(reloaded.chaos == store.chaos, "записи читаются после перезапуска")
    let data = try Data(contentsOf: store.fileURL)
    let document = try DiaryJSON.decode(data)
    check(document.version == 6, "непустая корзина поднимает файл до версии 6")
    expectError("пустая строка не записывается") { _ = try store.addChaosItem(text: "   ") }
    let removed = try store.deleteChaosItem(id: plain.id)
    try store.restoreChaosItem(removed)
    check(store.chaos.contains(where: { $0.id == plain.id }), "снятую запись можно вернуть")
    let task = try store.makeTask(fromChaos: urgent.id, text: urgent.text, organization: TaskOrganization(area: .work))
    check(task.taskArea == .work && task.taskStatus == .ready && task.day.isEmpty, "задача выходит без дня и без срока")
    check(task.isAtRisk && task.organization?.deadline == nil && task.organization?.reviewDate == nil, "срочная строка даёт отметку угрозы и не выдумывает даты")
    check(!store.chaos.contains(where: { $0.id == urgent.id }) && store.entries.isEmpty, "задача покидает корзину и не пишет дневник")
    let note = try store.makeNote(fromChaos: plain.id)
    check(note.title == "Идея без места" && note.body == "Идея без места" && store.chaos.isEmpty && store.entries.isEmpty, "заметка забирает запись и не пишет дневник")
    let old = """
    {"format":"daylog","version":5,"entries":[],"plans":[{"id":"11111111-1111-1111-1111-111111111111","text":"Старая","day":"","createdAt":"2030-03-10T08:00:00Z","updatedAt":"2030-03-10T08:00:00Z","organization":{"area":"personal","status":"inbox"}}]}
    """
    let oldDir = freshDir("chaos-old")
    try old.write(to: oldDir.appendingPathComponent("entries.json"), atomically: true, encoding: .utf8)
    let oldStore = DiaryStore(directory: oldDir); try oldStore.load()
    check(oldStore.chaos.isEmpty && oldStore.plans.count == 1 && oldStore.plans[0].taskStatus == .inbox, "старый файл без корзины читается")
}

test("Хранилище: два экземпляра не перезаписывают свежие данные") {
    let dir = freshDir("organizer-conflict")
    let first = DiaryStore(directory: dir), second = DiaryStore(directory: dir)
    try first.load(); try second.load()
    _ = try first.addTask(text: "Первый", organization: TaskOrganization(status: .inbox))
    let source = try Data(contentsOf: first.fileURL)
    let error = expectError("устаревший экземпляр отклоняет запись") { _ = try second.addTask(text: "Второй", organization: TaskOrganization()) }
    check((error as? DiaryError) == .conflictingChanges, "причина конфликта доступна пользователю")
    check(second.plans.isEmpty, "после конфликта память не меняется")
    check(try Data(contentsOf: first.fileURL) == source, "свежий файл не потерян")
    try second.load()
    _ = try second.addTask(text: "Второй", organization: TaskOrganization())
    let reloaded = DiaryStore(directory: dir); try reloaded.load()
    check(reloaded.plans.count == 2, "после загрузки свежей версии обе задачи сохранены")
}

// MARK: Поля пересмотра: обещание, угроза, снятие, поиск и порядок

func reviewTaskIDs(_ groups: [ReviewGroup]) -> [UUID] {
    groups.flatMap(\.items).compactMap { item in
        if case .task(let task) = item { return task.id }
        return nil
    }
}

func reviewProjectIDs(_ groups: [ReviewGroup]) -> [UUID] {
    groups.flatMap(\.items).compactMap { item in
        if case .project(let project) = item { return project.id }
        return nil
    }
}

test("Обещание: «Кому обещано» хранится, ищется и не уходит в дневник") {
    let dir = freshDir("promised-to")
    let store = DiaryStore(directory: dir); try store.load()
    let task = try store.addTask(text: "Отправить черновик",
                                 organization: TaskOrganization(area: .work, promisedTo: "  Редактор  ", details: "Только шаблон A"))
    check(task.promisedTo == "Редактор", "пробелы по краям адресата снимаются")
    check(try DiaryJSON.decode(Data(contentsOf: store.fileURL)).version == 7, "непустой адресат поднимает файл до v7")
    let cleared = try store.updateTask(id: task.id, text: task.text, plannedDay: nil,
                                       organization: TaskOrganization(area: .work, promisedTo: "   "))
    check(cleared.promisedTo == nil, "пустая строка хранится как отсутствие поля")
    _ = try store.updateTask(id: task.id, text: task.text, plannedDay: nil,
                             organization: TaskOrganization(area: .work, promisedTo: "Редактор", details: "Только шаблон A"))
    let reloaded = DiaryStore(directory: dir); try reloaded.load()
    check(reloaded.plans.first?.promisedTo == "Редактор", "адресат переживает перезапуск")
    check(reloaded.searchOrganizer("редактор").tasks.map(\.id) == [task.id], "поиск находит задачу по адресату")
    let markdown = try reloaded.exportMarkdown()
    check(markdown.contains("Кому обещано") && markdown.contains("Редактор"), "Markdown показывает адресата")
    let completed = try reloaded.completePlan(id: task.id, now: day2)
    check(completed.entry.text == "Отправить черновик" && completed.entry.context == nil, "запись дневника не копирует адресата")
    check(reloaded.entries.count == 1, "выполнение по-прежнему создаёт одну запись")
}

test("Пересмотр: дело под угрозой видно при любом статусе, отметку ставит человек") {
    let dir = freshDir("at-risk")
    let store = DiaryStore(directory: dir); try store.load()
    let now = date(2030, 3, 15, 9, 0)
    let paused = try store.addTask(text: "Отложено до весны", organization: TaskOrganization(status: .paused))
    let waiting = try store.addTask(text: "Жду ответа", organization: TaskOrganization(status: .waiting, waitingFor: "Ответ коллеги"))
    let plain = try store.addTask(text: "Обычное дело", organization: TaskOrganization())
    check(store.tasksForToday(now: now).isEmpty && store.tasksAtRisk().isEmpty, "без отметки и без дня дел на сегодня нет")
    let marked = try store.setTaskAtRisk(id: paused.id, true, now: now)
    check(marked.isAtRisk && marked.taskStatus == .paused && marked.day.isEmpty, "отметка не меняет статус и даты")
    check(marked.organization?.deadline == nil && marked.organization?.reviewDate == nil, "отметка не назначает даты")
    check(store.tasksForToday(now: now).map(\.id) == [paused.id], "отложенное дело с отметкой видно в «Сегодня»")
    check(store.tasksAtRisk().map(\.id) == [paused.id], "и в выборке угрозы")
    check(reviewTaskIDs(store.reviewGroups(now: now)).contains(paused.id), "и в пересмотре")
    _ = try store.setTaskAtRisk(id: waiting.id, true, now: now)
    check(Set(store.tasksAtRisk().map(\.id)) == Set([paused.id, waiting.id]), "ожидающее дело с отметкой тоже видно")
    check(store.entries.isEmpty, "отметка не пишет дневник")
    _ = try store.setTaskAtRisk(id: paused.id, false, now: now)
    check(store.tasksAtRisk().map(\.id) == [waiting.id], "человек снимает отметку тем же действием")
    check(!store.tasksForToday(now: now).contains { $0.id == paused.id }, "снятая отметка убирает дело из «Сегодня»")
    check(!reviewTaskIDs(store.reviewGroups(now: now)).contains(paused.id), "и из пересмотра")
    _ = try store.completePlan(id: plain.id, now: now)
    expectError("отметка на выполненной задаче отклоняется") { _ = try store.setTaskAtRisk(id: plain.id, true, now: now) }
    check(!store.tasksAtRisk().contains { $0.id == plain.id }, "выполненная задача в выборку угрозы не входит")
    check(!store.tasksForToday(now: now).contains { $0.id == plain.id }, "выполненная задача не возвращается в «Сегодня»")
    let inbox = try store.addTask(text: "Строка в корзине", organization: TaskOrganization(status: .inbox))
    _ = try store.setTaskAtRisk(id: inbox.id, true, now: now)
    check(!store.tasksAtRisk().contains { $0.id == inbox.id }, "задача места хаоса остаётся в корзине, а не в выборке угрозы")
}

test("Снятие: причина обязательна, работа не считается выполненной") {
    let dir = freshDir("removed-task")
    let store = DiaryStore(directory: dir); try store.load()
    let now = date(2030, 3, 15, 9, 0)
    let project = try store.saveProject(title: "Проект", outcome: "Результат", area: .work, uncertainty: "", reviewDate: nil)
    var task = try store.addTask(text: "Подготовить материалы", plannedDay: day1,
                                 organization: TaskOrganization(area: .work, projectID: project.id,
                                                                promisedTo: "Коллега", atRisk: true,
                                                                reviewDate: day1, deadline: day2))
    task = try store.replaceTaskSteps(parent: task, steps: [TaskStep(text: "Первый шаг")])
    try store.setNextAction(projectID: project.id, taskID: task.id)
    let error = expectError("снятие без причины отклоняется") { _ = try store.setTaskRemoved(id: task.id, reason: "   ") }
    check((error as? DiaryError) == .emptyRemovalReason, "причина обязательна")
    check(store.plans.first { $0.id == task.id }?.isRemoved == false, "после отказа задача не снята")
    let removed = try store.setTaskRemoved(id: task.id, reason: " Потребность отпала ", now: now)
    check(removed.isRemoved && removed.completedAt == nil && removed.entryID == nil, "снятие не отмечается выполнением")
    check(removed.removalReason == "Потребность отпала", "причина сохраняется с обрезанными краями")
    check(store.entries.isEmpty, "снятие не создаёт запись дневника")
    check(removed.taskSteps.map(\.text) == ["Первый шаг"], "шаги снятой задачи сохраняются")
    check(store.tasksForToday(now: now).isEmpty && store.tasksAtRisk().isEmpty, "снятая задача вне «Сегодня» и выборки угрозы")
    check(store.waitingTasks().isEmpty, "снятая задача вне ожидания")
    check(reviewTaskIDs(store.reviewGroups(now: now)).isEmpty, "снятая задача вне пересмотра")
    check(store.visibleTasks().isEmpty, "в полном списке снятая задача скрыта")
    check(store.visibleTasks(showRemoved: true).map(\.id) == [task.id], "и видна только с явным переключателем")
    check(store.projects.first?.nextActionID == nil, "следующий шаг проекта освобождается")
    check(store.searchOrganizer("материалы").tasks.isEmpty, "обычный поиск снятую задачу не возвращает")
    check(store.searchOrganizer("материалы", includeRemoved: true).tasks.map(\.id) == [task.id], "переключатель возвращает её")
    let archive = try DiaryStore.parseExportDocument(store.exportJSON())
    check(archive.plans.first?.removalReason == "Потребность отпала" && archive.plans.first?.taskStatus == .removed, "JSON хранит статус и причину")
    let markdown = try store.exportMarkdown()
    check(markdown.contains("Снято") && markdown.contains("Причина снятия") && markdown.contains("Потребность отпала"), "Markdown показывает снятие и причину")
    try store.setProjectArchived(id: project.id, archived: true)
    check(store.projects.first?.archived == true, "снятая задача считается закрытой и не держит проект")
    expectError("снятую задачу нельзя изменить") {
        _ = try store.updateTask(id: task.id, text: "Другое", plannedDay: nil, organization: TaskOrganization())
    }
    expectError("снятую задачу нельзя выполнить") { _ = try store.completePlan(id: task.id, now: now) }
    let reloaded = DiaryStore(directory: dir); try reloaded.load()
    check(reloaded.plans.first?.removalReason == "Потребность отпала", "причина переживает перезапуск")
    let restored = try reloaded.returnTaskToWork(id: task.id, now: now)
    check(restored.taskStatus == .ready && restored.removalReason == nil, "возврат восстанавливает «Можно делать» и стирает прежнюю причину")
    check(restored.taskSteps.map(\.text) == ["Первый шаг"] && restored.promisedTo == "Коллега" && restored.isAtRisk, "остальные поля и шаги сохраняются")
    expectError("возврат уже работающей задачи отклоняется") { _ = try reloaded.returnTaskToWork(id: task.id) }
    check(try DiaryJSON.decode(Data(contentsOf: reloaded.fileURL)).version == 7, "отметка угрозы держит v7 и после возврата")
}

test("Миграция: v6 читается без перезаписи, первое сохранение v7 создаёт одну копию") {
    let dir = freshDir("review-migration")
    let legacy = DiaryDocument(entries: [],
                               plans: [DayPlan(text: "Прежняя задача", day: "", createdAt: day1, updatedAt: day1)],
                               chaos: [ChaosItem(text: "Прежняя строка", createdAt: day1)])
    check(legacy.version == 6, "исходный документ — v6")
    let original = try DiaryJSON.encoder().encode(legacy)
    let file = dir.appendingPathComponent("entries.json")
    try original.write(to: file)
    let store = DiaryStore(directory: dir); try store.load()
    check(try Data(contentsOf: file) == original, "загрузка не переписывает старый файл")
    check(store.plans.count == 1 && store.plans[0].promisedTo == nil && !store.plans[0].isAtRisk, "прежние задачи читаются без новых полей")
    check(store.chaos.map(\.text) == ["Прежняя строка"], "корзина читается")
    check(store.plans.filter { $0.taskStatus == .inbox }.isEmpty, "старые задачи не переносятся в ChaosItem")
    _ = try store.addChaosItem(text: "Новая строка")
    check(try DiaryJSON.decode(Data(contentsOf: file)).version == 6, "пока новых полей нет, файл остаётся v6")
    check(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("entries-before-review-") }.isEmpty, "копия пересмотра ещё не создавалась")
    let beforeReview = try Data(contentsOf: file)
    _ = try store.setTaskAtRisk(id: store.plans[0].id, true)
    check(try DiaryJSON.decode(Data(contentsOf: file)).version == 7, "первое поле пересмотра поднимает файл до v7")
    let backups = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("entries-before-review-") }
    check(backups.count == 1, "создана одна копия до перехода")
    check(try Data(contentsOf: backups[0]) == beforeReview, "копия побайтно соответствует файлу до перехода")
    _ = try store.setTaskAtRisk(id: store.plans[0].id, false)
    check(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("entries-before-review-") }.count == 1, "следующие сохранения не создают лишних копий")
    let reloaded = DiaryStore(directory: dir); try reloaded.load()
    check(reloaded.chaos.count == 2 && reloaded.plans.count == 1 && !reloaded.plans[0].isAtRisk, "после перезапуска данные целы")
}

test("Пересмотр: один запрос находит задачи, проекты и строки хаоса") {
    let store = DiaryStore(directory: freshDir("organizer-search")); try store.load()
    let project = try store.saveProject(title: "Ремонт кухни", outcome: "Готовая кухня", area: .personal,
                                        uncertainty: "Нужно уточнить, что ответит поставщик", reviewDate: nil)
    let archived = try store.saveProject(title: "Закрытый", outcome: "Поставщик сдан", area: .personal,
                                         uncertainty: "", reviewDate: nil)
    try store.setProjectArchived(id: archived.id, archived: true)
    let promised = try store.addTask(text: "Позвонить", organization: TaskOrganization(promisedTo: "Поставщик"))
    let waiting = try store.addTask(text: "Жду счёт", organization: TaskOrganization(status: .waiting, waitingFor: "Ответ поставщика"))
    let detailed = try store.addTask(text: "Разобрать бумаги", organization: TaskOrganization(details: "Запрос поставщику отправлен"))
    let plain = try store.addTask(text: "Полка на кухне", organization: TaskOrganization(projectID: project.id))
    _ = try store.addChaosItem(text: "Спросить поставщика про гарантию")
    let done = try store.addTask(text: "Оплачено поставщику", organization: TaskOrganization())
    _ = try store.completePlan(id: done.id, now: day1)
    let removed = try store.addTask(text: "Лишнее поставщику", organization: TaskOrganization())
    _ = try store.setTaskRemoved(id: removed.id, reason: "Не нужно")

    let found = store.searchOrganizer("ПОСТАВЩИК")
    check(Set(found.tasks.map(\.id)) == Set([promised.id, waiting.id, detailed.id]), "регистр не важен, ищутся адресат, ожидание и подробности")
    check(found.projects.map(\.id) == [project.id], "неархивный проект находится, архивный — нет")
    check(found.chaos.map(\.text) == ["Спросить поставщика про гарантию"], "строка места хаоса находится")
    check(!found.tasks.contains { $0.id == done.id || $0.id == removed.id }, "выполненные и снятые в обычную выдачу не входят")
    check(store.searchOrganizer("   ").isEmpty, "пустой запрос ничего не возвращает")
    check(store.searchOrganizer("поставщик", includeCompleted: true, includeRemoved: true).tasks.count == 5, "переключатели возвращают выполненные и снятые")
    check(store.searchOrganizer("кухн").projects.map(\.id) == [project.id] && store.searchOrganizer("кухн").tasks.map(\.id) == [plain.id], "проект ищется и по названию, и по результату")
}

test("Пересмотр: порядок групп, первое совпадение побеждает, даты не выдумываются") {
    let store = DiaryStore(directory: freshDir("review-order")); try store.load()
    let now = date(2030, 3, 15, 9, 0)
    let project = try store.saveProject(title: "Проект без шага", outcome: "Результат", area: .work, uncertainty: "", reviewDate: nil)
    let dueReview = try store.addTask(text: "Пересмотреть отчёт", organization: TaskOrganization(reviewDate: date(2030, 3, 14, 0, 0)))
    let waiting = try store.addTask(text: "Жду согласования",
                                    organization: TaskOrganization(status: .waiting, waitingFor: "Ответ редактора",
                                                                   reviewDate: date(2030, 3, 20, 0, 0)))
    let today = try store.addTask(text: "Сегодняшнее дело", plannedDay: date(2030, 3, 15, 0, 0),
                                  organization: TaskOrganization(projectID: project.id))
    let atRisk = try store.addTask(text: "Отложено, но горит", organization: TaskOrganization(status: .paused, atRisk: true))
    let promiseNoDate = try store.addTask(text: "Обещал помочь", organization: TaskOrganization(promisedTo: "Сосед"))
    let promiseFar = try store.addTask(text: "Отчёт к концу месяца",
                                       organization: TaskOrganization(promisedTo: "Руководитель", deadline: date(2030, 3, 28, 0, 0)))
    let promiseNear = try store.addTask(text: "Черновик завтра",
                                        organization: TaskOrganization(promisedTo: "Редактор",
                                                                       reviewDate: date(2030, 3, 10, 0, 0),
                                                                       deadline: date(2030, 3, 16, 0, 0)))
    let done = try store.addTask(text: "Готово", organization: TaskOrganization(promisedTo: "Кто-то", deadline: date(2030, 3, 1, 0, 0)))
    _ = try store.completePlan(id: done.id, now: now)
    let removed = try store.addTask(text: "Снято", organization: TaskOrganization(promisedTo: "Кто-то", atRisk: true))
    _ = try store.setTaskRemoved(id: removed.id, reason: "Не нужно")
    let archived = try store.saveProject(title: "Архивный", outcome: "Результат", area: .work, uncertainty: "",
                                         reviewDate: date(2030, 3, 1, 0, 0))
    try store.setProjectArchived(id: archived.id, archived: true)

    let groups = store.reviewGroups(now: now)
    check(groups.map(\.title) == ["Обещания со сроком", "Обещания без срока", "Под угрозой",
                                  "Сегодня и следующие шаги", "Ожидания", "Пересмотр"], "порядок групп: \(groups.map(\.title))")
    check(reviewTaskIDs([groups[0]]) == [promiseNear.id, promiseFar.id], "ближайший срок раньше")
    check(reviewTaskIDs([groups[1]]) == [promiseNoDate.id], "обещание без срока отдельной группой")
    check(store.plans.first { $0.id == promiseNoDate.id }?.organization?.deadline == nil, "дата обещанию не выдумывается")
    check(reviewTaskIDs([groups[2]]) == [atRisk.id], "остальные отмеченные под угрозой")
    check(reviewTaskIDs([groups[3]]) == [today.id], "дела на сегодня")
    check(reviewTaskIDs([groups[4]]) == [waiting.id], "ожидания с названным условием")
    check(reviewTaskIDs([groups[5]]) == [dueReview.id], "задача с наступившей датой пересмотра")
    check(reviewProjectIDs([groups[5]]) == [project.id], "проект без следующего шага")
    let items = groups.flatMap(\.items)
    check(Set(items.map(\.id)).count == items.count, "одно дело не повторяется в нескольких группах")
    check(!reviewTaskIDs(groups).contains(done.id) && !reviewTaskIDs(groups).contains(removed.id), "выполненные и снятые исключены")
    check(!reviewProjectIDs(groups).contains(archived.id), "архивный проект исключён")

    try store.setNextAction(projectID: project.id, taskID: today.id)
    let withStep = store.reviewGroups(now: now)
    check(reviewProjectIDs(withStep).isEmpty, "проект со следующим шагом уходит из пересмотра")
    check(reviewTaskIDs([withStep[3]]) == [today.id], "следующий шаг остаётся в группе сегодняшних дел без дубля")
    check(store.reviewGroups(now: date(2030, 3, 1, 9, 0)).map(\.title).first == "Обещания со сроком", "порядок не зависит от выбранного дня")
}

test("Обзор: на пустом хранилище все шесть групп на месте и пусты") {
    let dir = freshDir("review-empty-groups")
    let store = DiaryStore(directory: dir); try store.load()
    let groups = store.reviewGroups(now: date(2030, 3, 10, 9, 0))
    check(groups.map(\.title) == ["Обещания со сроком", "Обещания без срока", "Под угрозой",
                                  "Сегодня и следующие шаги", "Ожидания", "Пересмотр"], "порядок пустых групп: \(groups.map(\.title))")
    check(groups.count == 6, "ровно шесть групп")
    check(groups.allSatisfy { $0.items.isEmpty }, "все группы пусты")
}

test("Разбор хаоса: строка уходит только вместе с сохранённой задачей") {
    let dir = freshDir("chaos-to-task")
    let store = DiaryStore(directory: dir); try store.load()
    let created = date(2030, 3, 10, 8, 0)
    let urgent = try store.addChaosItem(text: "Позвонить редактору", urgent: true, now: created)
    expectError("пустой текст не создаёт задачу") {
        _ = try store.makeTask(fromChaos: urgent.id, text: "   ", organization: TaskOrganization(area: .work))
    }
    check(store.chaos.map(\.id) == [urgent.id] && store.plans.isEmpty, "после ошибки строка остаётся с тем же id")
    let task = try store.makeTask(fromChaos: urgent.id, text: "Позвонить редактору и уточнить срок",
                                  organization: TaskOrganization(area: .work, promisedTo: "Редактор"), now: created)
    check(store.chaos.isEmpty && store.plans.map(\.id) == [task.id], "успешное сохранение убирает строку и создаёт одну задачу")
    check(task.text == "Позвонить редактору и уточнить срок" && task.taskArea == .work && task.taskStatus == .ready, "текст и сфера приходят из редактора")
    check(task.isAtRisk && task.promisedTo == "Редактор", "срочная строка даёт отметку угрозы")
    check(task.day.isEmpty && task.organization?.deadline == nil && task.organization?.reviewDate == nil, "даты не выдумываются")
    check(store.entries.isEmpty && store.notes.isEmpty, "разбор места хаоса не пишет дневник")
    let plain = try store.addChaosItem(text: "Обычная строка", now: created)
    let plainTask = try store.makeTask(fromChaos: plain.id, text: plain.text, organization: TaskOrganization(area: .personal), now: created)
    check(!plainTask.isAtRisk && plainTask.taskArea == .personal, "несрочная строка не получает отметку")
    check(store.sortedChaos().isEmpty, "корзина пуста")
    expectError("разбор несуществующей строки отклоняется") {
        _ = try store.makeTask(fromChaos: UUID(), text: "Что-то", organization: TaskOrganization())
    }

    let conflictDir = freshDir("chaos-conflict")
    let first = DiaryStore(directory: conflictDir), second = DiaryStore(directory: conflictDir)
    try first.load(); try second.load()
    let shared = try first.addChaosItem(text: "Общая строка", now: created)
    try second.load()
    _ = try first.addChaosItem(text: "Строка первого экземпляра", now: created)
    let conflict = expectError("устаревший экземпляр отклоняет разбор") {
        _ = try second.makeTask(fromChaos: shared.id, text: shared.text, organization: TaskOrganization())
    }
    check((conflict as? DiaryError) == .conflictingChanges, "причина конфликта видна")
    check(second.chaos.map(\.id) == [shared.id] && second.plans.isEmpty, "после сбоя записи строка остаётся, задача не создана")
    check(first.chaos.contains { $0.id == shared.id }, "свежий файл не потерял строку")
}

// MARK: Линейные шаги задачи

test("Шаги: связь, порядок, ручное редактирование, повторное добавление") {
    let store = DiaryStore(directory: freshDir("steps")); try store.load()
    var parent = try store.addTask(text: "Исходная задача", plannedDay: day1, organization: TaskOrganization(area: .work, deadline: day2, details: "Подробности"))
    let original = parent
    let steps = [TaskStep(text: "Первый"), TaskStep(text: "Второй"), TaskStep(text: "Третий")]
    parent = try store.appendTaskSteps(parent: parent, proposal: steps)
    check(store.plans.count == 1 && parent.id == original.id && parent.text == original.text && parent.organization == original.organization && parent.day == original.day, "исходная задача, сроки и подробности сохранены, второй список не создан")
    check(parent.taskSteps == steps && parent.nextStep == steps[0], "связь через родителя и порядок массива")
    check(store.entries.isEmpty && store.projects.isEmpty, "добавление не создаёт дневник и проект")
    let bytes = try Data(contentsOf: store.fileURL)
    let repeated = try store.appendTaskSteps(parent: original, proposal: steps)
    check(try repeated == parent && store.plans[0].taskSteps.count == 3 && Data(contentsOf: store.fileURL) == bytes, "повторное утверждение с теми же ID идемпотентно")
    var edits = steps
    edits.swapAt(0, 1); edits[0].text = "Второй уточнён"; edits[0].completedAt = day1
    parent = try store.replaceTaskSteps(parent: parent, steps: edits)
    check(parent.nextStep?.id == steps[0].id && parent.taskSteps[0].isCompleted, "следующий незавершённый отличим от выполненного после перестановки")
    let reloaded = DiaryStore(directory: store.directory); try reloaded.load()
    check(reloaded.plans[0] == parent, "перезапуск сохраняет порядок, ID, текст и выполнение")
    edits.remove(at: 1)
    parent = try store.replaceTaskSteps(parent: parent, steps: edits)
    check(parent.taskSteps.count == 2 && !parent.isCompleted && store.entries.isEmpty, "удаление шага не завершает родителя и не создаёт дневник")
    expectError("дубли текста не добавляются") { _ = try store.appendTaskSteps(parent: parent, proposal: [TaskStep(text: "Третий")]) }
    var allDone = parent.taskSteps
    for index in allDone.indices { allDone[index].completedAt = day1 }
    parent = try store.replaceTaskSteps(parent: parent, steps: allDone)
    check(parent.nextStep == nil && !parent.isCompleted && store.entries.isEmpty, "все шаги выполнены, результат родителя ещё не подтверждён")
    let completed = try store.completePlan(id: parent.id)
    check(completed.plan.taskSteps == allDone && store.entries.count == 1, "явное выполнение родителя сохраняет шаги и прежнюю запись дневника")
    expectError("шаги выполненного родителя заморожены") { _ = try store.replaceTaskSteps(parent: completed.plan, steps: []) }
    expectError("удаление родителя с шагами не каскадное") { _ = try store.deletePlan(id: parent.id) }
    _ = try store.reopenPlan(id: parent.id)
    parent = store.plans[0]
    check(parent.taskSteps == allDone && !parent.isCompleted, "возврат родителя не сбрасывает шаги")
    parent = try store.replaceTaskSteps(parent: parent, steps: [])
    _ = try store.deletePlan(id: parent.id)
    check(store.plans.isEmpty, "после явного удаления шагов родителя можно удалить")
}

test("Шаги: устаревший снимок, добавление и атомарность") {
    let store = DiaryStore(directory: freshDir("steps-conflict")); try store.load()
    let original = try store.addTask(text: "Задача", organization: TaskOrganization())
    let firstProposal = [TaskStep(text: "a"), TaskStep(text: "b"), TaskStep(text: "c")]
    let parent = try store.appendTaskSteps(parent: original, proposal: firstProposal)
    check(store.plans[0] == parent && parent.taskSteps == firstProposal, "добавление не создаёт второй список")
    let secondProposal = [TaskStep(text: "d"), TaskStep(text: "e"), TaskStep(text: "f")]
    let stale = expectError("нельзя применить к изменённому снимку") { _ = try store.appendTaskSteps(parent: original, proposal: secondProposal) }
    check(stale as? TaskStepsError == .changedParent && store.plans[0] == parent, "конфликт снимка без частичного списка")
    let bytes = try Data(contentsOf: store.fileURL)
    expectError("пустой шаг внутри списка отклоняет весь список") {
        _ = try store.appendTaskSteps(parent: parent, proposal: [TaskStep(text: "новый"), TaskStep(text: " ")])
    }
    check(try store.plans[0] == parent && Data(contentsOf: store.fileURL) == bytes, "валидация не оставляет частично сохранённые шаги")
    let peer = DiaryStore(directory: store.directory); try peer.load()
    _ = try peer.addTask(text: "Из другого экземпляра", organization: TaskOrganization())
    let fresh = try Data(contentsOf: store.fileURL)
    let err = expectError("конфликт файла при пакетном добавлении") { _ = try store.appendTaskSteps(parent: parent, proposal: secondProposal) }
    check(err as? DiaryError == .conflictingChanges && store.plans[0] == parent, "конфликт не меняет память")
    check(try Data(contentsOf: store.fileURL) == fresh, "конфликт не меняет свежий файл")
    try store.load()
    let appended = try store.appendTaskSteps(parent: store.plans.first { $0.id == parent.id }!, proposal: secondProposal)
    check(appended.taskSteps == firstProposal + secondProposal, "новое предложение добавляется только явно, сохраняя прежние шаги")
    expectError("частичное совпадение ID не создаёт дубли") {
        _ = try store.appendTaskSteps(parent: appended, proposal: [firstProposal[0], TaskStep(text: "ещё")])
    }
    let directory = freshDir("steps-write-fail")
    let broken = DiaryStore(directory: directory); try broken.load()
    let bparent = try broken.addTask(text: "На диске", organization: TaskOrganization())
    // Занятый файл блокировки: отказ записи воспроизводится без прав доступа и root-зависимости.
    let lock = directory.appendingPathComponent(".entries.lock")
    let fd = Darwin.open(lock.path, O_RDWR)
    defer { _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) }
    check(flock(fd, LOCK_EX | LOCK_NB) == 0, "тест удерживает отдельную блокировку")
    expectError("занятая запись отклоняет весь список") { _ = try broken.appendTaskSteps(parent: bparent, proposal: secondProposal) }
    check(broken.plans[0] == bparent, "после отказа записи шагов нет в памяти")
}

test("Шаги: прежние файлы, миграция, round-trip и экспорт") {
    let old = Data(#"{"format":"daylog","version":4,"entries":[],"plans":[{"id":"11111111-1111-1111-1111-111111111111","text":"Старая задача","day":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}]}"#.utf8)
    let document = try DiaryJSON.decode(old)
    check(document.plans[0].steps == nil && document.plans[0].taskSteps.isEmpty, "прежний JSON без steps читается")
    let dir = freshDir("steps-migration")
    try old.write(to: dir.appendingPathComponent(DiaryStore.fileName))
    let store = DiaryStore(directory: dir); try store.load()
    let parent = try store.replaceTaskSteps(parent: store.plans[0], steps: [TaskStep(text: "Первая строка\nВторая строка"), TaskStep(text: "Готовый шаг", completedAt: day1)])
    let archive = try store.exportJSON()
    let restored = try DiaryJSON.decode(archive)
    check(restored.version == 5 && restored.plans[0] == parent, "v5 JSON round-trip хранит все связи и отметки")
    let backups = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("entries-before-steps-") }
    check(try backups.count == 1 && Data(contentsOf: backups[0]) == old, "перед переходом v4-v5 сохранена исходная копия")
    let md = try store.exportMarkdown()
    check(md.contains(parent.id.uuidString) && md.contains(parent.taskSteps[0].id.uuidString) && md.contains("1. [ ]") && md.contains("2. [x]") && md.contains("> Вторая строка"), "Markdown показывает связь, порядок и отметки, безопасно цитирует текст")
    let folder = try store.exportMarkdownFolder(parentDirectory: freshDir("steps-export"))
    check(try DiaryJSON.decode(Data(contentsOf: folder.archiveURL)).plans[0] == parent, "папочный JSON сохраняет шаги")
    let human = try String(contentsOf: folder.folderURL.appendingPathComponent("Органайзер.md"), encoding: .utf8)
    check(human.contains(parent.taskSteps[0].id.uuidString), "папочный Markdown хранит связь")
}

test("AppState: повторное построение sheet использует свежего родителя") {
    try MainActor.assumeIsolated {
        let store = DiaryStore(directory: freshDir("steps-app-state"))
        let state = AppState(store: store)
        let original = try store.addTask(text: "Исходная", organization: TaskOrganization(details: "Условия"))
        _ = state.changeOrganizer("Обновлено") { }
        let draft = state.breakdownDraft(for: original)
        check(state.changeOrganizer("Добавлены шаги") {
            _ = try store.replaceTaskSteps(parent: store.plans[0], steps: [TaskStep(text: "Сохранённый шаг")])
        }, "AppState сохраняет шаги")
        let sameDraft = state.breakdownDraft(for: original)
        check(sameDraft === draft && draft.parent == store.plans[0] && draft.savedSteps == store.plans[0].taskSteps,
              "устаревший sheet item не возвращает старый список")
        draft.savedSteps[0].text = "Правка до сохранения"
        _ = state.changeOrganizer("Изменена задача") {
            _ = try store.updateTask(id: original.id, text: "Новая формулировка", plannedDay: nil,
                                     organization: TaskOrganization(details: "Условия"))
        }
        _ = state.breakdownDraft(for: original)
        check(draft.savedSteps[0].text == "Правка до сохранения" && draft.parent.text == "Новая формулировка" && draft.error == nil,
              "смена названия не затирает ручной черновик и оставляет его сохраняемым")
        let saved = try store.replaceTaskSteps(parent: draft.parent, steps: draft.savedSteps)
        check(saved.taskSteps[0].text == "Правка до сохранения", "ручная правка записывается в актуальную задачу")
    }
}

test("AppState: два ручных шага видны после добавления и повторного render старого sheet item") {
    try MainActor.assumeIsolated {
        let store = DiaryStore(directory: freshDir("draft-sheet-render"))
        let state = AppState(store: store)
        let original = try store.addTask(text: "Ручные шаги", organization: TaskOrganization())
        _ = state.changeOrganizer("Обновлено") { }
        let draft = state.breakdownDraft(for: original)
        draft.addStep()
        draft.addStep()
        draft.stepTextBinding(id: draft.savedSteps[0].id).wrappedValue = "Первый отредактирован"
        draft.stepTextBinding(id: draft.savedSteps[1].id).wrappedValue = "Второй отредактирован"
        var saved: DayPlan?
        check(state.changeOrganizer("Шаги сохранены") {
            saved = try store.replaceTaskSteps(parent: draft.parent, steps: draft.savedSteps)
        }, "ручное сохранение успешно")
        draft.reloadSavedSteps(parent: saved!)
        check(draft.savedSteps.map(\.text) == ["Первый отредактирован", "Второй отредактирован"], "список шагов содержит обе строки")
        check(try DiaryJSON.decode(Data(contentsOf: store.fileURL)).plans[0].taskSteps == draft.savedSteps, "экранный список совпадает с JSON")
        var publishes = 0
        let subscription = draft.objectWillChange.sink { publishes += 1 }
        for _ in 0..<5 { check(state.breakdownDraft(for: original) === draft, "sheet со старым item получает тот же черновик") }
        check(publishes == 0 && draft.savedSteps == saved!.taskSteps && draft.parent == saved!, "получение черновика в render не публикует изменения и не затирает свежий список")
        subscription.cancel()
    }
}

test("Редактор: Binding по ID переживает перестановку, удаление и отложенный callback") {
    MainActor.assumeIsolated {
        let parent = DayPlan(text: "Задача", day: "", createdAt: day1, updatedAt: day1)
        let draft = TaskBreakdownDraft(parent: parent)
        let first = TaskStep(text: "Первый"), second = TaskStep(text: "Второй")
        draft.savedSteps = [first, second]
        let firstBinding = draft.stepTextBinding(id: first.id)
        let secondBinding = draft.stepTextBinding(id: second.id)
        draft.moveStep(id: first.id, offset: 1)
        firstBinding.wrappedValue = "Правка первого после перестановки"
        check(draft.savedSteps.map(\.id) == [second.id, first.id] && secondBinding.wrappedValue == "Второй" && firstBinding.wrappedValue.contains("Правка первого"), "захваченный Binding пишет по ID, а не по прежнему индексу")
        draft.removeStep(id: first.id)
        check(firstBinding.wrappedValue == "", "чтение удалённой строки безопасно")
        firstBinding.wrappedValue = "Поздний callback"
        draft.toggleStep(id: first.id)
        draft.moveStep(id: first.id, offset: -1)
        draft.removeStep(id: first.id)
        check(draft.savedSteps == [second], "отложенные команды удалённой строки не меняют соседнюю и не воскрешают шаг")
        draft.removeStep(id: second.id)
        secondBinding.wrappedValue = "Поздняя правка последней строки"
        draft.moveStep(id: second.id, offset: 1)
        check(draft.savedSteps.isEmpty && secondBinding.wrappedValue == "", "удаление последнего шага не оставляет опасных индексных привязок")
    }
}

test("Смена названия и подробностей оставляет ручные правки шагов сохраняемыми") {
    try MainActor.assumeIsolated {
        let store = DiaryStore(directory: freshDir("context-review-manual-edits")); try store.load()
        let original = try store.addTask(text: "Старое название", organization: TaskOrganization(details: "Старые сведения"))
        let parent = try store.replaceTaskSteps(parent: original, steps: [TaskStep(text: "Исходный шаг")])
        let draft = TaskBreakdownDraft(parent: parent)
        draft.savedSteps[0].text = "Ручная правка шага"
        let renamed = try store.updateTask(id: parent.id, text: "Новое название", plannedDay: nil,
                                          organization: TaskOrganization(details: "Новые сведения"))
        draft.reopen(parent: renamed)
        check(draft.hasSavedEdits && draft.error == nil && draft.parent == renamed, "смена названия и подробностей не блокирует сохранение ручных шагов")
        check(draft.savedSteps[0].text == "Ручная правка шага", "обновление снимка не сбрасывает правку")
        let saved = try store.replaceTaskSteps(parent: draft.parent, steps: draft.savedSteps)
        check(saved.text == "Новое название" && saved.organization?.details == "Новые сведения" && saved.taskSteps[0].text == "Ручная правка шага", "ручные правки сохраняются вместе с актуальными данными родителя")

        let conflictDraft = TaskBreakdownDraft(parent: saved)
        conflictDraft.savedSteps[0].text = "Локальная несохранённая правка"
        var remoteRows = saved.taskSteps
        remoteRows[0].text = "Другая сохранённая правка"
        let changedSteps = try store.replaceTaskSteps(parent: saved, steps: remoteRows)
        let changedBoth = try store.updateTask(id: changedSteps.id, text: "Ещё одно название", plannedDay: nil,
                                              organization: TaskOrganization(details: "Новые сведения"))
        conflictDraft.reopen(parent: changedBoth)
        check(conflictDraft.parent == saved && conflictDraft.error == TaskStepsError.changedParent.localizedDescription, "изменившийся список шагов не подменяется молча")
        check(conflictDraft.savedSteps[0].text == "Локальная несохранённая правка" && store.plans[0].taskSteps[0].text == "Другая сохранённая правка", "оба варианта сохраняются без скрытого затирания")
        conflictDraft.reloadSavedSteps(parent: store.plans[0])
        check(!conflictDraft.hasSavedEdits && conflictDraft.savedSteps[0].text == "Другая сохранённая правка" && conflictDraft.parent.text == "Ещё одно название", "явная перезагрузка берёт сохранённый список")
    }
}

// MARK: P1: раздел дел и быстрая запись хаоса

test("P1-01: раздел дел запоминается для профиля, новый профиль без ключа") {
    try MainActor.assumeIsolated {
        let dir = freshDir("p1-section")
        let fresh = AppState(store: DiaryStore(directory: dir))
        check(fresh.savedOrganizerSection == nil, "новый профиль: сохранённого раздела нет, прежний не выдумывается")
        check(!fm.fileExists(atPath: dir.appendingPathComponent(AppState.uiStateFileName).path), "без выбора человека файл раздела не создаётся")
        fresh.organizerCaptureText = "Черновик строки"
        _ = fresh.changeOrganizer("Записано") { _ = try fresh.store.addChaosItem(text: "Строка хаоса") }
        fresh.rememberOrganizerSection("Проекты")
        check(fresh.organizerCaptureText == "Черновик строки" && fresh.chaos.count == 1, "смена раздела не очищает черновик и записанные строки")
        let reopened = AppState(store: DiaryStore(directory: dir))
        check(reopened.savedOrganizerSection == "Проекты", "выбранный раздел восстанавливается при следующем запуске профиля")
        check(reopened.chaos.count == 1 && reopened.chaos[0].text == "Строка хаоса", "данные профиля не затронуты файлом раздела")
        let json = try String(contentsOf: dir.appendingPathComponent(DiaryStore.fileName), encoding: .utf8)
        check(!json.contains("Проекты"), "раздел не пишется в файл дневника")
        let other = AppState(store: DiaryStore(directory: freshDir("p1-section-other")))
        check(other.savedOrganizerSection == nil, "другой профиль не получает чужой раздел")
    }
}

test("P1-02: команда быстрой записи хаоса только открывает поле") {
    MainActor.assumeIsolated {
        let state = AppState(store: DiaryStore(directory: freshDir("p1-capture")))
        state.mode = .day
        state.organizerCaptureText = "Недописанная мысль"
        let token = state.chaosCaptureToken
        state.requestChaosCapture()
        check(state.mode == .organizer && state.chaosCaptureRequested && state.chaosCaptureToken == token + 1, "команда открывает дела и место хаоса")
        check(state.organizerCaptureText == "Недописанная мысль" && state.chaos.isEmpty, "черновик не затирается, пустая запись не создаётся")
        for mode in [AppMode.notes, .day, .organizer] {
            state.mode = mode
            state.requestChaosCapture()
            check(state.mode == .organizer, "команда работает из любого режима")
        }
        check(state.chaos.isEmpty && state.entries.isEmpty, "команда ничего не записывает")
    }
}

test("P1-03: поиск по ⌘F остаётся в текущем разделе, запись открывает дневник") {
    MainActor.assumeIsolated {
        let state = AppState(store: DiaryStore(directory: freshDir("p1-find")))
        for mode in [AppMode.organizer, .notes, .day] {
            state.mode = mode
            let token = state.focusToken
            state.requestFocus(.search)
            check(state.mode == mode && state.focusRequest == .search && state.focusToken == token + 1,
                  "поиск в режиме \(mode) не меняет режим и выдаёт запрос фокуса")
        }
        state.mode = .organizer
        state.requestFocus(.add)
        check(state.mode == .day && state.focusRequest == .add, "запрос записи по-прежнему открывает дневник")
    }
}

print("\nПроверок: \(checks), ошибок: \(failures)")
exit(failures == 0 ? 0 : 1)

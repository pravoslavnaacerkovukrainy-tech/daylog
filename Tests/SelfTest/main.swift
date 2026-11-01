// Самопроверка ядра «Ход дня». Использует производственный DiaryStore, без копий логики.
// Только нейтральные искусственные примеры. Запуск: ./test.sh
import Foundation

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
    check(md.hasPrefix("# Ход дня — экспорт"), "заголовок Markdown")
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

test("Причёсывание: в запрос попадает только черновик, ключ остаётся в заголовке") {
    let req = try DraftPolish.request(draft: "  кран течёт, звонил сантехнику  ", apiKey: "XAI-SECRET-KEY")
    let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
    check(body["model"] as? String == "grok-4.7", "модель")
    check(body["store"] as? Bool == false, "запрос не сохраняется на сервере")
    let input = body["input"] as! [[String: Any]]
    check(input.count == 2, "system и один user")
    check(input[1]["content"] as? String == "кран течёт, звонил сантехнику", "в user только черновик")
    let raw = String(data: req.httpBody!, encoding: .utf8)!
    check(!raw.contains("XAI-SECRET-KEY"), "ключа нет в теле")
    check(!raw.contains("план"), "в теле нет постороннего дневника")
    check(req.value(forHTTPHeaderField: "Authorization") == "Bearer XAI-SECRET-KEY", "ключ в заголовке")
    check(req.timeoutInterval == 90, "таймаут 90 с")
}

test("Причёсывание: пустой и слишком длинный черновик") {
    expectError("пустой") { _ = try DraftPolish.requestBody(draft: "   \n") }
    expectError("длинный") { _ = try DraftPolish.requestBody(draft: String(repeating: "а", count: 2001)) }
}

test("Причёсывание: ответ — фраза, рассуждение модели отбрасывается") {
    let json = """
    {"output":[
      {"type":"reasoning","encrypted_content":"SECRET-REASONING"},
      {"type":"message","content":[{"type":"output_text","text":"«Позвонил сантехнику, кран больше не течёт.»"}]}
    ]}
    """.data(using: .utf8)!
    let line = try DraftPolish.parse(json)
    check(line == "Позвонил сантехнику, кран больше не течёт.", "фраза без кавычек: \(line)")
    check(!line.contains("SECRET-REASONING"), "рассуждение не попало в черновик")
}

test("Причёсывание: запасные формы ответа и ошибка без текста") {
    let direct = #"{"output_text":"Купил хлеб"}"#.data(using: .utf8)!
    check(try DraftPolish.parse(direct) == "Купил хлеб", "output_text")
    let fenced = #"{"output":[{"content":"```\nЗапись: «Закрыл кран»\nПояснение: готово\n```"}]}"#.data(using: .utf8)!
    check(try DraftPolish.parse(fenced) == "Закрыл кран", "первая строка без подписи: \(try DraftPolish.parse(fenced))")
    expectError("пустой output") { _ = try DraftPolish.parse(#"{"output":[]}"#.data(using: .utf8)!) }
    let err = #"{"error":{"message":"Incorrect API key"}}"#.data(using: .utf8)!
    check(DraftPolish.errorMessage(from: err) == "Incorrect API key", "текст ошибки API")
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
test("Документ: будущая версия 4 отвергается как неподдерживаемая") {
    let v4 = #"{"format":"daylog","version":4,"entries":[],"notes":[]}"#.data(using: .utf8)!
    let err = expectError("v4 не поддерживается") { _ = try DiaryJSON.decode(v4) }
    check((err as? DiaryError) == .unsupportedFormat("версия 4, приложение понимает версию до 3"), "сообщение про версию: \(String(describing: err))")
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

print("\nПроверок: \(checks), ошибок: \(failures)")
exit(failures == 0 ? 0 : 1)

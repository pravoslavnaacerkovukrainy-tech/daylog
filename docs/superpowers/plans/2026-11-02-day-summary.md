# «Итог дня» Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить одноразовый спокойный «Итог дня» — резюме записей текущего дня через xAI, по явному нажатию, ничего не сохраняя.

**Architecture:** Новый чистый Core-модуль `DaySummary` (+ `DaySummaryClient`) зеркалит `DraftPolish`/`NotesChat`: Responses API, `store:false`, переиспользует `XAIResponses.extractText` и `DraftPolishError`. `AppState` получает `summarizeDay()`/`clearDaySummary()` и состояние `daySummary`/`summaryBusy` (по образцу `sendChat`). UI — пункт меню «День», тихая кнопка в колонке дня и лёгкий sheet; новый `AppMode` не вводится.

**Tech Stack:** Swift (Command Line Tools, без Xcode), SwiftUI/AppKit, xAI Responses API (`grok-4.7`). Сборка `build.sh`, тесты `test.sh` (самодельный DSL `test`/`check`, без XCTest).

**Spec:** `docs/superpowers/specs/2026-11-02-day-summary-design.md`

## Global Constraints

- Платформа: macOS 14+, только Swift из Command Line Tools (полный Xcode не требуется).
- Модель `grok-4.7`; endpoint `https://api.x.ai/v1/responses`; payload содержит `store: false`; `timeoutInterval = 90`.
- `maxContextCharacters = 120_000` (как в `NotesChat`).
- Шрифты только системные (SF); цвета только из `Theme` (`ink`/`quiet`/`accent`/`rail`/`field`/`pane`/`canvas`). Весь UI-текст — по-русски.
- Не вводить новых типов ошибок — только `DraftPolishError`. Не вводить новый `AppMode`.
- Итог НЕ пишется в `entries.json` и никуда локально; модель данных не меняется.
- В xAI уходят только записи выбранного дня; план (`DayPlan`) и другие дни не отправляются.
- Иконка кнопки — нейтральный SF Symbol (не `sparkles`).
- Сборка: `bash build.sh`; тесты: `bash test.sh`.

## Review Focus

- Пустой день → сеть не трогается: `DaySummary.buildInput([])` бросает `DraftPolishError.empty` (тест в Task 1); guard в `AppState.summarizeDay` — ручная проверка (Task 2).
- Запись с непустым «на чём остановился» даёт отдельную строку контекста, с пустым/`nil` — не даёт (тест в Task 1).
- Ответ Responses API с блоком `reasoning` → он пропускается, берётся текст (тест в Task 1).
- Контекст больше `maxContextCharacters` → `DraftPolishError.contextTooLarge(count)` (тест в Task 1).
- Многострочный текст записи переносится с отступом и не ломает формат строк (тест в Task 1).

---

### Task 1: Core-модуль `DaySummary` + самотест

**Files:**
- Create: `Sources/Core/DaySummary.swift`
- Test: `Tests/SelfTest/main.swift` (дописать блок тестов перед финальным выводом счётчика)

**Interfaces:**
- Consumes: `DiaryEntry` (`text`, `context: String?`, `timestamp`), `DiaryFormat.time(_:)`, `XAIResponses.extractText(_:cleanOutput:)` и `XAIResponses.stripCodeFence(_:)`, `DraftPolishError` (`.empty`, `.contextTooLarge(Int)`, `.badResponse`, `.http(Int,String)`, `.noKey`), `DraftPolish.errorMessage(from:)`.
- Produces:
  - `DaySummary.model: String`, `.endpoint: URL`, `.maxContextCharacters: Int`, `.systemPrompt: String`
  - `DaySummary.buildDayText(_ entries: [DiaryEntry]) -> String`
  - `DaySummary.buildInput(entries: [DiaryEntry]) throws -> [[String: Any]]`
  - `DaySummary.requestBody(entries: [DiaryEntry]) throws -> Data`
  - `DaySummary.request(entries: [DiaryEntry], apiKey: String) throws -> URLRequest`
  - `DaySummary.parse(_ data: Data) throws -> String`
  - `DaySummaryClient(session: URLSession = .shared).summarize(entries: [DiaryEntry], apiKey: String) async throws -> String`

- [ ] **Step 1: Написать падающие тесты в `Tests/SelfTest/main.swift`**

Дописать перед итоговым `print`/`exit` по счётчику. Использовать существующий DSL (`test`, `check`, `expectError`, хелпер `date`). Для фикстуры ответа собрать `Data` из словаря вида Responses API.

```swift
test("DaySummary: buildDayText — время, текст, контекст") {
    let e1 = DiaryEntry(text: "Завтрак", context: nil,
                        timestamp: date(2030, 3, 10, 9, 30),
                        createdAt: date(2030, 3, 10, 9, 30), updatedAt: date(2030, 3, 10, 9, 30))
    let e2 = DiaryEntry(text: "Правил отчёт", context: "остановился на разделе 2",
                        timestamp: date(2030, 3, 10, 14, 5),
                        createdAt: date(2030, 3, 10, 14, 5), updatedAt: date(2030, 3, 10, 14, 5))
    let text = DaySummary.buildDayText([e1, e2])
    check(text.contains("09:30"), "есть время первой записи")
    check(text.contains("Завтрак"), "есть текст первой записи")
    check(text.contains("остановился на разделе 2"), "есть контекст второй записи")
    // У записи без контекста строки «на чём остановился» быть не должно для её времени.
    let firstBlock = text.components(separatedBy: "14:05").first ?? ""
    check(!firstBlock.lowercased().contains("на чём остановился"), "у записи без контекста нет строки контекста")
}

test("DaySummary: buildDayText — многострочный текст с отступом") {
    let e = DiaryEntry(text: "Строка один\nСтрока два", context: nil,
                       timestamp: date(2030, 3, 10, 8, 0),
                       createdAt: date(2030, 3, 10, 8, 0), updatedAt: date(2030, 3, 10, 8, 0))
    let text = DaySummary.buildDayText([e])
    check(text.contains("Строка один"), "первая строка на месте")
    check(text.contains("Строка два"), "вторая строка на месте")
    check(!text.contains("08:00") || text.components(separatedBy: "\n").count >= 2, "многострочность сохранена")
}

test("DaySummary: пустой день → .empty, сети нет") {
    let err = expectError("buildInput([]) бросает") { _ = try DaySummary.buildInput(entries: []) }
    check((err as? DraftPolishError) == .empty, "именно .empty")
}

test("DaySummary: слишком большой контекст → .contextTooLarge") {
    let big = String(repeating: "я", count: DaySummary.maxContextCharacters + 10)
    let e = DiaryEntry(text: big, context: nil, timestamp: date(2030, 3, 10, 8, 0),
                       createdAt: date(2030, 3, 10, 8, 0), updatedAt: date(2030, 3, 10, 8, 0))
    let err = expectError("buildInput большой день бросает") { _ = try DaySummary.buildInput(entries: [e]) }
    if case .contextTooLarge = (err as? DraftPolishError) { check(true, "именно .contextTooLarge") }
    else { check(false, "ожидался .contextTooLarge, получено \(String(describing: err))") }
}

test("DaySummary: requestBody — store:false и роли") {
    let e = DiaryEntry(text: "Дело", context: nil, timestamp: date(2030, 3, 10, 8, 0),
                       createdAt: date(2030, 3, 10, 8, 0), updatedAt: date(2030, 3, 10, 8, 0))
    let data = try DaySummary.requestBody(entries: [e])
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    check((json["store"] as? Bool) == false, "store:false")
    check((json["model"] as? String) == DaySummary.model, "модель grok-4.7")
    let input = json["input"] as! [[String: Any]]
    check(input.first?["role"] as? String == "system", "первый — system")
    check(input.last?["role"] as? String == "user", "последний — user")
}

test("DaySummary: parse — пропускает reasoning, берёт текст") {
    let fixture: [String: Any] = ["output": [
        ["type": "reasoning", "content": "размышления"],
        ["type": "message", "content": [["type": "output_text", "text": "Спокойный итог дня."]]],
    ]]
    let data = try JSONSerialization.data(withJSONObject: fixture)
    let out = try DaySummary.parse(data)
    check(out == "Спокойный итог дня.", "извлечён именно текст сообщения, получено: \(out)")
}
```

- [ ] **Step 2: Запустить тесты — убедиться, что падают**

Run: `bash test.sh`
Expected: FAIL/ошибка компиляции — `DaySummary` не существует.

- [ ] **Step 3: Реализовать `Sources/Core/DaySummary.swift`**

Повторить структуру `DraftPolish`/`NotesChat`. Константы и системный промпт — из Global Constraints и спека. `buildDayText`: для каждой записи `"\(DiaryFormat.time(e.timestamp)) — \(e.text)"`; многострочный `text` переносить с отступом (как в `exportMarkdown`: `replacingOccurrences(of: "\n", with: "\n  ")`); если `context` непустой — добавить строку `"  на чём остановился: \(context)"`. Записи разделять пустой строкой. `buildInput`: guard пустого текста дня → `.empty`; `count > maxContextCharacters` → `.contextTooLarge(count)`; иначе system+user. `requestBody`/`request`/`parse`/`DaySummaryClient` — как у соседей (в `parse` использовать `XAIResponses.extractText` с чисткой `stripCodeFence`; в клиенте ловить `URLError.cancelled → CancellationError`, не-2xx → `.http`).

Точную формулировку `systemPrompt` взять из спека (секция «Системный промпт»), в стиле `DraftPolish.systemPrompt`.

- [ ] **Step 4: Запустить тесты — убедиться, что проходят**

Run: `bash test.sh`
Expected: все строки `ok`, итог без `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/DaySummary.swift Tests/SelfTest/main.swift
git commit -m "feat(core): итог дня — модуль DaySummary и самотесты"
```

---

### Task 2: Интеграция в `AppState`

**Files:**
- Modify: `Sources/App/AppState.swift`

**Interfaces:**
- Consumes: `DaySummaryClient.summarize(entries:apiKey:)` (Task 1), `XAIKeyStore.load()`, существующие `dayEntries`, `showError(_:)`, `showDraftStatus(_:)`.
- Produces:
  - `AppState.daySummary: String?` (`@Published private(set)`)
  - `AppState.summaryBusy: Bool` (`@Published private(set)`)
  - `AppState.summarizeDay()`
  - `AppState.clearDaySummary()`

Автоматических unit-тестов нет (метод делает сеть + Keychain + `@MainActor`; существующий самотест покрывает только Core/`DiaryStore`). Проверка — сборкой и ручным дымовым прогоном в Task 3.

- [ ] **Step 1: Добавить состояние и методы в `AppState`**

Рядом с чат-состоянием (`chatMessages`/`chatBusy`/`chatTask`) добавить `@Published private(set) var daySummary: String?`, `@Published private(set) var summaryBusy = false`, `private var summaryTask: Task<Void, Never>?`.

`summarizeDay()` — по образцу `sendChat` (AppState.swift:350):
1. `guard !summaryBusy else { return }`.
2. `let snapshot = dayEntries`; если `snapshot.isEmpty` → `showDraftStatus("За этот день записей нет — нечего подытоживать.")`, `return` (сети нет).
3. `summaryBusy = true`; `summaryTask = Task { @MainActor in … }`.
4. Внутри: `guard let key = XAIKeyStore.load() else { showError(DraftPolishError.noKey.localizedDescription); summaryBusy = false; return }`.
5. `do { let text = try await DaySummaryClient().summarize(entries: snapshot, apiKey: key); if Task.isCancelled { return }; daySummary = text }`
   `catch is CancellationError { }`
   `catch { if Task.isCancelled { return }; showError(error.localizedDescription) }`; в конце `summaryBusy = false`.

`clearDaySummary()`: `summaryTask?.cancel(); summaryBusy = false; daySummary = nil`.

- [ ] **Step 2: Закрывать итог при смене дня**

В `go(to:)` (AppState.swift:108) добавить вызов, сбрасывающий открытый итог, чтобы он не «прилипал» к другому дню: `summaryTask?.cancel(); summaryBusy = false; daySummary = nil` (или вызвать `clearDaySummary()`), после установки `selectedDay`/`searchText`.

- [ ] **Step 3: Собрать**

Run: `bash build.sh`
Expected: сборка и строгая проверка подписи проходят без ошибок.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/AppState.swift
git commit -m "feat(state): итог дня — summarizeDay/clearDaySummary"
```

---

### Task 3: UI (меню «День», кнопка дня, sheet) + документация

**Files:**
- Modify: `Sources/App/DaylogApp.swift:76-100` (меню «День»)
- Modify: `Sources/App/Views.swift` (ContentView: toolbar/колонка дня + sheet; новый приватный `DaySummarySheet`)
- Modify: `README.md` (разделы «Что умеет» и «Приватность»)
- Modify: `DESIGN.md` (одна строка в описании, что итог — одноразовый, не метрика)

**Interfaces:**
- Consumes: `state.summarizeDay()`, `state.clearDaySummary()`, `state.daySummary`, `state.summaryBusy`, `state.dayEntries`, `state.selectedDay`, `Theme`, `DiaryFormat`.
- Produces: пункт меню «Итог дня…» (⌥⌘I); действие в колонке дня; sheet с текстом итога, кнопками «Скопировать» и «Закрыть».

Проверка — сборкой и ручным дымовым прогоном (автотестов для UI в проекте нет).

- [ ] **Step 1: Пункт меню «День» → «Итог дня…»**

В `CommandMenu("День")` (DaylogApp.swift:76) после блока «Спросить ИИ» (перед `Divider()`/«Показать или скрыть план») добавить:
```swift
Button("Итог дня…") {
    state.mode = .day
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "main")
    state.summarizeDay()
}
.keyboardShortcut("i", modifiers: [.command, .option])
.disabled(state.dayEntries.isEmpty || state.summaryBusy)
```

- [ ] **Step 2: Тихая кнопка в колонке дня**

В `mainColumn` (Views.swift:170) добавить рядом с заголовком дня/композером тихую кнопку действия (стиль `.borderless`, `Theme.accent`, нейтральный SF Symbol — например `doc.plaintext`, НЕ `sparkles`), вызывающую `state.summarizeDay()`, с `.help("Спокойный итог дня через xAI (⌥⌘I)")` и `.disabled(state.dayEntries.isEmpty || state.summaryBusy || state.isBlocked)`. Не показывать в режиме поиска (`state.isSearching`).

- [ ] **Step 3: `DaySummarySheet` и его показ**

Добавить приватный `struct DaySummarySheet` (по образцу `PolishConfirmSheet`, Views.swift:1447): заголовок «Итог за \(DiaryFormat.shortDate(selectedDay))» (`Theme.ink`); при `busy` — `ProgressView` с подписью; иначе текст итога (`.body`, `Theme.ink`, `.textSelection(.enabled)`, в рамке `Theme.field`/`Theme.rail`); кнопки «Скопировать» (в `NSPasteboard.general`: `clearContents()` + `setString(_:forType:.string)`) и «Закрыть». Ширина ~460.

В `ContentView.body` добавить `.sheet`, показываемый когда `state.daySummary != nil || state.summaryBusy`, с биндингом, который при закрытии вызывает `state.clearDaySummary()` (как сделано для `polishPreview`, Views.swift:111). Содержимое: `DaySummarySheet(summary: state.daySummary, busy: state.summaryBusy, day: state.selectedDay, onClose: state.clearDaySummary)`.

- [ ] **Step 4: Документация**

README «Что умеет»: добавить пункт «**Итог дня** — одной кнопкой спокойное резюме прожитого дня (2–4 фразы) через xAI; одноразовое, ничего не сохраняется». README «Приватность»: добавить, что «Итог дня», как и «Причесать», ходит в сеть только по кнопке, отправляет только записи выбранного дня (без плана и других дней), с `store:false`, и не сохраняется ни на диск, ни на стороне xAI. DESIGN.md: одна строка, что итог — одноразовый и не является метрикой.

- [ ] **Step 5: Собрать и прогнать дымовой сценарий**

Run: `bash build.sh && bash test.sh`
Expected: сборка и тесты проходят. Ручной дым (на машине с ключом xAI): открыть день с записями → «Итог дня…» → появляется sheet со спиннером, затем текст; «Скопировать» кладёт текст в буфер; «Закрыть» убирает итог; на пустом дне пункт меню и кнопка неактивны; смена дня при открытом итоге закрывает его.

- [ ] **Step 6: Commit**

```bash
git add Sources/App/DaylogApp.swift Sources/App/Views.swift README.md DESIGN.md
git commit -m "feat(ui): итог дня — меню, кнопка и sheet; документация"
```

---

## Self-Review

- **Spec coverage:** Core-модуль и промпт → Task 1; данные/guard/snapshot/ошибки → Task 1 (чистое) + Task 2 (состояние); UI (меню/кнопка/sheet, «Скопировать», нет «вставить записью», нет нового режима) → Task 3; приватность/README/DESIGN → Task 3; тесты без сети → Task 1. «Что НЕ делаем в v1» соблюдается (нет persist, нет плана в запросе, нет новых ошибок/режима).
- **Review Focus:** все пять пунктов покрыты тестами Task 1; guard пустого дня дополнительно живёт в `AppState` (ручная проверка Task 3 Step 5).
- **Типы/имена:** `daySummary`, `summaryBusy`, `summarizeDay`, `clearDaySummary`, `DaySummary.*`, `DaySummaryClient.summarize` одинаковы во всех задачах.
- **Пропорция:** план соразмерен спеку; код-блоки — только тесты (которые задают точные значения) и короткие сигнатуры; тела функций отданы исполнителю.

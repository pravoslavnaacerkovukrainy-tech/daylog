# Чат по заметкам — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить в «Ход дня» чат вопрос-ответ по заметкам: пользователь спрашивает, ИИ отвечает по содержимому всех заметок и показывает заметки-источники.

**Architecture:** Новый `NotesChat` (Core) собирает запрос из пронумерованных заметок + истории диалога + вопроса, зовёт xAI (grok-4.7, `store:false`), парсит ответ и номера источников. Диалог эфемерный — живёт в `AppState`, в файл не пишется. UI — третий режим тулбара «Спросить».

**Tech Stack:** Swift 5, SwiftUI + AppKit, swiftc без Xcode. Переиспользуются `XAIResponses`, `DraftPolishError`, стиль `NotePolishClient`.

**Spec:** `docs/superpowers/specs/2026-11-02-notes-chat-design.md`

**Исполнитель:** код задач пишет kimi CLI (модель Kimi K3); Claude Code проверяет (RED→GREEN / сборка) и коммитит.

## Global Constraints

- macOS 14+, подпись (локальная идентичность или ad-hoc fallback) — `build.sh` не менять.
- Провайдер ИИ: xAI Responses API, модель `grok-4.7`, `store:false`, ключ только из `XAIKeyStore` (Keychain).
- Чат НЕ сохраняется на диск: `entries.json` (документ v3) не трогаем; `ChatMessage` нигде не сериализуется.
- Весь новый код ядра (`Sources/Core/*`) компилируется и в `build.sh` (маска `Sources/Core/*.swift`), и в `test.sh` (список файлов — дополнять).
- Контекст в запрос: ВСЕ заметки (пронумерованы) + история диалога + вопрос; бюджет `maxContextCharacters = 120_000`.
- Язык интерфейса/промптов — русский; тип ошибок xAI — существующий `DraftPolishError` (+ новый кейс `contextTooLarge`).

## Review Focus

- **Номер источника вне диапазона** (модель указала `⟦источники: 5⟧` при 3 заметках): не должно падать — невалидные номера отбрасываются. → тест `resolveSources` в Task 2.
- **Нет строки источников** в ответе: `parse` отдаёт пустой список и полный текст как ответ, ничего не теряя. → тест `parse` в Task 2.
- **Заметки не влезают в бюджет**: `buildInput` бросает `contextTooLarge(n)`, не обрезает молча. → тест в Task 1.
- **Пустой вопрос**: `buildInput` бросает `empty`; UI не отправляет. → тест в Task 1 + guard в Task 3.
- **Ответ только из строки источников** (пустой текст ответа): `parse` бросает `badResponse`, а не пустой ответ. → тест `parse` в Task 2.

---

### Task 1: `ChatMessage`, ошибка `contextTooLarge`, сборка контекста `NotesChat`

**Files:**
- Create: `Sources/Core/NotesChat.swift` (тип `ChatMessage`, enum-кейс не здесь; сборка контекста)
- Modify: `Sources/Core/DiaryCore.swift` или `DraftPolish.swift` — добавить `case contextTooLarge(Int)` в `DraftPolishError` (enum живёт в `DraftPolish.swift`)
- Test: `Tests/SelfTest/main.swift`

**Interfaces:**
- Produces:
  - `struct ChatMessage: Identifiable, Equatable { enum Role { case user, assistant }; let id: UUID; let role: Role; var text: String; var sourceNoteIDs: [UUID]; let timestamp: Date }` c `init(id: UUID = UUID(), role: Role, text: String, sourceNoteIDs: [UUID] = [], timestamp: Date = Date())`
  - `DraftPolishError.contextTooLarge(Int)` с `errorDescription`
  - `enum NotesChat`: `static let model = "grok-4.7"`, `endpoint`, `maxContextCharacters = 120_000`, `systemPrompt: String`
  - `NotesChat.numberedNotes(_ notes: [DiaryNote]) -> String`
  - `NotesChat.buildInput(notes: [DiaryNote], history: [ChatMessage], question: String) throws -> [[String: Any]]`
  - `NotesChat.requestBody(notes:history:question:) throws -> Data`, `NotesChat.request(notes:history:question:apiKey:) throws -> URLRequest`

- [ ] **Step 1: Написать падающие тесты**

```swift
test("NotesChat: нумерация заметок с 1, пустой заголовок, порядок") {
    let a = DiaryNote(title: "Первая", body: "тело1", createdAt: Date(), updatedAt: Date())
    let b = DiaryNote(title: "", body: "тело2", createdAt: Date(), updatedAt: Date())
    let s = NotesChat.numberedNotes([a, b])
    check(s.contains("[1] Первая"), "первая под номером 1")
    check(s.contains("[2] Без заголовка"), "пустой заголовок → Без заголовка: \(s)")
    check(s.range(of: "[1]")!.lowerBound < s.range(of: "[2]")!.lowerBound, "порядок сохранён")
}
test("NotesChat: buildInput — система+история+вопрос; пустой вопрос → ошибка") {
    let note = DiaryNote(title: "T", body: "B", createdAt: Date(), updatedAt: Date())
    let hist = [ChatMessage(role: .user, text: "привет"), ChatMessage(role: .assistant, text: "да")]
    let input = try NotesChat.buildInput(notes: [note], history: hist, question: "что по T?")
    check(input.first?["role"] as? String == "system", "первое — system")
    check(input.count == 4, "system + 2 истории + вопрос: \(input.count)")
    check(input.last?["content"] as? String == "что по T?", "последний — вопрос")
    expectError("пустой вопрос") { _ = try NotesChat.buildInput(notes: [note], history: [], question: "  ") }
}
test("NotesChat: переразмер контекста → contextTooLarge") {
    let big = DiaryNote(title: "x", body: String(repeating: "а", count: 130_000),
                        createdAt: Date(), updatedAt: Date())
    let err = expectError("слишком много") { _ = try NotesChat.buildInput(notes: [big], history: [], question: "?") }
    if case .contextTooLarge = (err as? DraftPolishError) {} else { check(false, "ожидался contextTooLarge: \(String(describing: err))") }
}
```

- [ ] **Step 2: Запустить — убедиться, что падает** · `bash test.sh` → FAIL (нет `NotesChat`/`ChatMessage`).
- [ ] **Step 3: Реализовать** `ChatMessage`, `DraftPolishError.contextTooLarge(Int)` (+ текст), `NotesChat` (константы, системный промпт из спеки, `numberedNotes`, `buildInput` с проверкой бюджета и пустого вопроса, `requestBody`/`request` по образцу `NotePolish`). История → сообщения `{"role": .user→"user"/.assistant→"assistant", "content": text}`.
- [ ] **Step 4: Запустить — убедиться, что проходит** · `bash test.sh` → PASS (прежние тоже зелёные).
- [ ] **Step 5: Commit** · `git add -A && git commit -m "feat(core): NotesChat — контекст запроса и ChatMessage"`

---

### Task 2: Разбор ответа и источников — `NotesChat.parse`, `resolveSources`, `NotesChatClient`

**Files:**
- Modify: `Sources/Core/NotesChat.swift`
- Modify: `test.sh` (добавить `Sources/Core/NotesChat.swift` в компиляцию)
- Test: `Tests/SelfTest/main.swift`

**Interfaces:**
- Consumes: `XAIResponses.extractText` (Task 3 заметочника), `DraftPolishError`, `ChatMessage` (Task 1).
- Produces:
  - `NotesChat.parse(_ data: Data) throws -> (answer: String, sources: [Int])`
  - `NotesChat.resolveSources(_ numbers: [Int], noteCount: Int) -> [Int]` (оставляет 1…noteCount, дедуп, порядок)
  - `struct NotesChatClient { init(session: URLSession = .shared); func ask(notes: [DiaryNote], history: [ChatMessage], question: String, apiKey: String) async throws -> (answer: String, sources: [Int]) }`
- `parse`: `extractText` → найти последнюю строку-маркер `⟦источники: …⟧` (фолбэк `[источники: …]`), извлечь целые (кроме «нет» → пусто); `answer` = текст без строки, trim; пусто → `badResponse`; нет строки → `([], весь текст)`.

- [ ] **Step 1: Написать падающие тесты**

```swift
test("NotesChat.parse: ответ + источники, 'нет', отсутствие строки, пустой") {
    let withSrc = #"{"output_text":"Ответ про кран.\n⟦источники: 1, 3⟧"}"#.data(using: .utf8)!
    let r = try NotesChat.parse(withSrc)
    check(r.answer == "Ответ про кран." && r.sources == [1, 3], "ответ без строки, источники [1,3]: \(r)")
    let none = #"{"output_text":"Не нашёл в заметках.\n⟦источники: нет⟧"}"#.data(using: .utf8)!
    check(try NotesChat.parse(none).sources.isEmpty, "'нет' → пусто")
    let noLine = #"{"output_text":"Просто ответ"}"#.data(using: .utf8)!
    let r2 = try NotesChat.parse(noLine)
    check(r2.sources.isEmpty && r2.answer == "Просто ответ", "нет строки → фолбэк")
    expectError("пустой ответ") { _ = try NotesChat.parse(#"{"output_text":"⟦источники: 1⟧"}"#.data(using: .utf8)!) }
}
test("NotesChat.resolveSources: отбрасывает вне диапазона, дедуп, порядок") {
    check(NotesChat.resolveSources([1, 3, 5, 3], noteCount: 3) == [1, 3], "5 вне, дубль 3 убран")
    check(NotesChat.resolveSources([0, -1, 2], noteCount: 2) == [2], "0/отриц. отброшены")
}
```

- [ ] **Step 2: Запустить — убедиться, что падает** · `bash test.sh` → FAIL.
- [ ] **Step 3: Реализовать** `parse`, `resolveSources`, `NotesChatClient.ask` (как `NotePolishClient`: trim ключа → `noKey`; `URLError.cancelled → CancellationError`; не 2xx → `http`; иначе `parse`). Добавить `Sources/Core/NotesChat.swift` в `test.sh`.
- [ ] **Step 4: Запустить — убедиться, что проходит** · `bash test.sh` → PASS.
- [ ] **Step 5: Commit** · `git add -A && git commit -m "feat(core): разбор ответа и источников NotesChat"`

---

### Task 3: Оркестрация чата в `AppState`

**Files:**
- Modify: `Sources/App/AppState.swift`

**Interfaces:**
- Consumes: `NotesChatClient`, `ChatMessage`, `NotesChat.resolveSources` (Task 1–2), `store.notes`, `XAIKeyStore`.
- Produces (на `AppState`):
  - `@Published var chatMessages: [ChatMessage] = []`
  - `@Published private(set) var chatBusy: Bool = false`
  - `func sendChat(_ question: String)` — добавляет user-сообщение; `chatTask` зовёт `NotesChatClient().ask(notes: store.notes, history: <предыдущие>, question:, apiKey:)`; номера → `store.notes[n-1].id` через `resolveSources`; добавляет assistant-сообщение с `sourceNoteIDs`; `contextTooLarge` → служебное сообщение-предупреждение в ленте; `noKey`/прочее → `showError`; отмена не показывается.
  - `func clearChat()` — `chatTask?.cancel(); chatMessages = []`
  - `func openSource(_ id: UUID)` — `mode = .notes; selectedNoteID = id`
  - `AppMode` расширить `case ask`

**Verification:** модуль App не покрыт SelfTest — проверяется компиляцией `build.sh`.

- [ ] **Step 1: Реализовать** перечисленное по образцу polish-потока заметок (токен занятости, `Task`, отмена; `saved`/`showError`). Маппинг источников — только валидные (`resolveSources`), затем `store.notes[n-1].id`.
- [ ] **Step 2: Собрать** · `bash build.sh` → «Готово.».
- [ ] **Step 3: Прогон ядра** · `bash test.sh` → PASS (ядро не затронуто регрессом).
- [ ] **Step 4: Commit** · `git add -A && git commit -m "feat(app): оркестрация чата по заметкам в AppState"`

---

### Task 4: Интерфейс режима «Спросить»

**Files:**
- Modify: `Sources/App/Views.swift` (тулбарный переключатель на 3 сегмента; `AskView`; пузырь сообщения; чипы-источников)
- Modify: `Sources/App/DaylogApp.swift` (команда «Спросить ИИ», при желании пункт MenuBarExtra)

**Interfaces:**
- Consumes: `state.mode == .ask`, `state.chatMessages`, `state.chatBusy`, `sendChat`, `clearChat`, `openSource` (Task 3).
- Produces: режим «Спросить» — лента сообщений (автоскролл), под ответом чипы-источники (заголовки заметок; тап → `openSource`), поле ввода + «Спросить» (⌘↩) + «Очистить», индикатор при `chatBusy`, пустое состояние и подсказка при отсутствии заметок/ключа.

**Verification:** UI вручную (сборка + запуск с `DAYLOG_DATA_DIR`).

- [ ] **Step 1: Реализовать** переключатель режима на три сегмента (День/Заметки/Спросить, binding `state.mode`), `AskView` и подкомпоненты по токенам `DESIGN.md` и стилю существующих вью. Команда «Спросить ИИ» → `mode = .ask` + фокус ввода.
- [ ] **Step 2: Собрать** · `bash build.sh` → «Готово.».
- [ ] **Step 3: Ручная проверка** на тестовых данных:
  `DAYLOG_DATA_DIR=/tmp/daylog-chat-demo` с парой заметок → задать вопрос (нужен ключ) → ответ приходит, под ним чипы-источники, тап открывает заметку; «Очистить» чистит; пустой ввод не отправляется; переключение режимов.
- [ ] **Step 4: Commit** · `git add -A && git commit -m "feat(app): интерфейс режима «Спросить» (чат по заметкам)"`

---

### Task 5: Итоговая проверка, README, установка

**Files:** `README.md`

- [ ] **Step 1: Полный прогон тестов** · `bash test.sh` → «ошибок: 0».
- [ ] **Step 2: Чистая сборка** · `bash build.sh` → проверенный результат, подпись валидна.
- [ ] **Step 3: README** — добавить «Спросить» в возможности (чат по заметкам со ссылками на источники; все заметки уходят в xAI по запросу).
- [ ] **Step 4: Установить** в `~/Applications/Ход дня.app` (`ditto --norsrc --noextattr --noacl build/Daylog.app ~/Applications/"Ход дня.app"`), проверить запуск.
- [ ] **Step 5: Commit** · `git add -A && git commit -m "docs: режим «Спросить» в README; релиз"`

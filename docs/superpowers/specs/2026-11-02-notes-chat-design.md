# Чат по заметкам (вопрос-ответ ИИ) — дизайн

Дата: 2026-11-02
Статус: согласован, ожидает вычитки перед планом реализации
Реализация: код пишет kimi CLI (модель Kimi K3); проверяет/коммитит Claude Code.

## Цель и контекст

«Ход дня» (Daylog, SwiftUI, swiftc без Xcode) уже имеет заметочник (документ v3,
`DiaryNote`, интеграция с xAI через `NotePolish`/`DraftPolish`/`XAIResponses`).

Этот этап (**Feature A**) добавляет **чат-вопрос-ответ по заметкам** (как в Mem.ai):
пользователь задаёт вопрос в окне ввода, ИИ отвечает, опираясь на содержимое заметок,
и показывает, на какие заметки опирался.

Отдельная будущая фича (**Feature B**, не в этом спеке) — «анализ дня ИИ»; скорее всего
это и есть отложенный анти-СДВГ-механизм. Разбирается отдельным циклом после A.

## Решения (зафиксированы с пользователем)

- Контекст: **все заметки сразу** (заголовок + тело) + история диалога + новый вопрос.
  При росте объёма позже перейдём на отбор релевантных — сейчас YAGNI.
- Взаимодействие: **диалог** (многоходовый чат), а не один вопрос-ответ.
- Ответ **ссылается на заметки-источники** (кликабельно → открыть заметку).
- История чата **НЕ сохраняется** на диск: живёт только в памяти, пока открыто приложение.
- Модель и провайдер — те же, что у заметок: **grok-4.7**, xAI Responses API, `store:false`,
  ключ из `XAIKeyStore` (Keychain). Отдельного ключа/провайдера нет.
- Если все заметки не влезают в бюджет контекста — **честно предупредить**, не обрезать молча.
- Явно вне объёма (YAGNI): сохранение истории, retrieval/эмбеддинги, стриминг ответа,
  экспорт чата, несколько независимых бесед.

## 1. Данные диалога (эфемерные, только в памяти)

Новый тип в **Core** (`NotesChat.buildInput` принимает историю `[ChatMessage]` и покрыт
тестами ядра, поэтому тип должен быть виден в Core; хранению на диск это не обязывает —
`ChatMessage` нигде не сериализуется):

```swift
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    var sourceNoteIDs: [UUID]   // только для assistant; заметки-источники
    let timestamp: Date
}
```

В `AppState`:
- `@Published var chatMessages: [ChatMessage] = []` — лента; НЕ пишется в `DiaryStore`/файл.
- `@Published private(set) var chatBusy: Bool`
- приватная `chatTask: Task<…>?` для отмены.
- `func clearChat()` — очистка ленты.
- Документ данных (`entries.json`, v3) НЕ меняется.

## 2. Ядро — `NotesChat.swift` (Sources/Core, рядом с `NotePolish`)

Чистый, тестируемый, без UI. Переиспользует `XAIResponses.extractText` и стиль клиента
`NotePolishClient`.

- Константы: `model = "grok-4.7"`, `endpoint = https://api.x.ai/v1/responses`,
  `maxContextCharacters = 120_000` (бюджет суммарного текста пронумерованных заметок).
- Системный промпт (суть): «Ты отвечаешь на вопросы пользователя, опираясь ТОЛЬКО на его
  заметки ниже. Если ответа в заметках нет — честно скажи об этом. Заметки пронумерованы.
  В КОНЦЕ ответа на отдельной строке укажи номера использованных заметок в формате
  `⟦источники: 1, 3⟧`, либо `⟦источники: нет⟧`, если не опирался ни на одну. Язык ответа —
  как у вопроса. Ничего не выдумывай сверх заметок.»
- `numberedNotes(_ notes: [DiaryNote]) -> String` — `"[1] <title|Без заголовка>\n<body>\n\n[2] …"`.
  Соответствие «номер → note.id» строится в том же порядке (массив заметок как есть, порядок UI).
- `buildInput(notes:history:question:) throws -> [[String: Any]]`:
  - проверка бюджета: если `numberedNotes(notes).count > maxContextCharacters` → `throw
    DraftPolishError.contextTooLarge(count)` (новый кейс в существующем enum ошибок xAI).
  - сообщения: `system` (промпт + «Заметки:\n» + numberedNotes), затем история
    (`role: user|assistant` с `text`), затем `user` с вопросом.
  - пустой вопрос → `DraftPolishError.empty`.
- `requestBody(notes:history:question:) throws -> Data` — payload `{model, store:false, input: buildInput(...)}`.
- `request(...) -> URLRequest` — как `NotePolish.request` (Bearer, timeout 90, JSON).
- `parse(_ data: Data) throws -> (answer: String, sources: [Int])`:
  1. `text = try XAIResponses.extractText(data)`.
  2. Найти последнюю строку вида `⟦источники: …⟧` (регистронезависимо, допускать `[источники: …]`
     и латинские скобки как фолбэк). Извлечь из неё целые числа (кроме случая «нет»).
  3. `answer` — текст без этой строки (trim). Если `answer` пуст → `throw badResponse`.
  4. Нет строки источников → `sources = []`, `answer = весь текст`.
- `NotesChatError`/новый кейс: расширить `DraftPolishError` на `case contextTooLarge(Int)` с
  понятным `errorDescription` («Заметок слишком много для одного запроса (N знаков)…»).
- `NotesChatClient`:
  ```swift
  struct NotesChatClient {
      init(session: URLSession = .shared)
      func ask(notes: [DiaryNote], history: [ChatMessage], question: String, apiKey: String)
          async throws -> (answer: String, sources: [Int])
  }
  ```
  как `NotePolishClient`: trim ключа → `noKey`; `URLError.cancelled → CancellationError`;
  не 2xx → `DraftPolishError.http(code, message)`; иначе `NotesChat.parse`.

## 3. AppState — оркестрация

- `func sendChat(question:)`:
  - тримминг; пусто → игнор.
  - добавить `ChatMessage(.user, question)` в `chatMessages`.
  - `chatBusy = true`; `chatTask = Task { … }`:
    - `guard let key = XAIKeyStore.load() else { showError(noKey…); chatBusy=false; return }`.
    - `do { let (answer, nums) = try await NotesChatClient().ask(notes: store.notes,
      history: <prior messages>, question:); map nums → note.id по порядку store.notes;
      добавить ChatMessage(.assistant, answer, sourceNoteIDs); } catch contextTooLarge
      { добавить служебное сообщение-предупреждение } catch { showError } `.
    - `chatBusy = false`.
  - отмена: при `clearChat()` или уходе — `chatTask?.cancel()`.
- Маппинг источников: номера 1-based → `store.notes[n-1].id` (с проверкой границ).
- `openSource(_ id: UUID)`: `mode = .notes; selectedNoteID = id`.

## 4. UI — третий режим «Спросить»

- `AppMode` расширяется: `case day, notes, ask`. Тулбарный `Picker` — три сегмента
  «День / Заметки / Спросить».
- `AskView`:
  - Лента (`ScrollView` + `ScrollViewReader`, автоскролл вниз): пузыри сообщений —
    вопрос пользователя и ответ ИИ (стиль по токенам `DESIGN.md`). Под ответом —
    ряд **чипов-источников** с заголовками заметок; тап → `state.openSource(id)`.
  - Низ: многострочное поле ввода + кнопка «Спросить» (⌘↩ отправляет), «Очистить» рядом.
    При `chatBusy` — индикатор, ввод заблокирован.
  - Пустое состояние: подсказка «Спросите что-нибудь о своих заметках…»; если заметок нет —
    «Сначала создайте заметки, чтобы по ним спрашивать».
  - Нет ключа — подсказка про «День → Ключ xAI…» (через `showError`).
- Команда/меню (минимально): пункт «Спросить ИИ» переключает в `.ask` и фокусирует ввод.

## 5. Ошибки, лимиты, приватность

- В запрос уходят ВСЕ заметки — заложено явно; это осознанный компромисс приватности
  (как «Оформить», но объёмнее). `store:false`.
- Нет ключа → подсказка. `contextTooLarge` → предупреждение в ленте (не отправляем).
  HTTP/битый ответ → показываем. Отмена задачи не показывается как ошибка.
- Заблокированное хранилище не мешает чату (чат читает `store.notes` из памяти), но при
  блокировке заметок может не быть — тогда обычная подсказка про отсутствие заметок.

## 6. Тесты (Sources/Core, через test.sh; NotesChat.swift добавить в компиляцию)

- `numberedNotes`: нумерация с 1, пустой заголовок → «Без заголовка», порядок сохранён.
- `buildInput`: содержит system с заметками, историю (роли), вопрос; пустой вопрос → `empty`.
- Бюджет: заметки суммарно больше `maxContextCharacters` → `contextTooLarge(n)`.
- `parse`: `⟦источники: 1, 3⟧` → sources `[1,3]`, answer без строки; `⟦источники: нет⟧` → `[]`;
  нет строки → `[]`, answer = весь текст; пустой ответ → `badResponse`; латинские скобки — фолбэк.
- `XAIResponses`/`DraftPolishError.contextTooLarge` — корректный текст ошибки.

UI (`AskView`, `AppState.sendChat`) — проверяется сборкой `build.sh` и ручным запуском
(SelfTest покрывает только ядро).

## 7. Сборка

Новый `Sources/Core/NotesChat.swift` подхватывается `build.sh` (маска) автоматически;
в `test.sh` список файлов пополнить вручную. `ChatMessage` в слое App (или Core) —
если в Core и нужен тестам, тоже добавить в `test.sh`.

## Открытые мелочи (решить в плане)

- Точное имя режима: «Спросить» (принято); ярлык команды.
- Формат строки источников: `⟦источники: …⟧` основной, `[источники: …]` — фолбэк парсера.
- `ChatMessage` — в App или Core (если тестируем `buildInput` с историей, удобнее Core).
  Решение по умолчанию: **Core** (чтобы `NotesChat.buildInput` и тесты его видели).

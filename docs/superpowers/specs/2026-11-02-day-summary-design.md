# «Итог дня» — дизайн

Дата: 2026-11-02. Статус: согласовано, готово к плану реализации.
Процесс: скилл `superpowers:brainstorming` (классификация → вопросы → секционный дизайн → spec).

## Что это

Одноразовое спокойное резюме прожитого дня в 2–4 фразах, по явному нажатию,
через xAI (Grok). Помощник при СДВГ: вечером «подвести черту» и спокойно
перечитать день своими же словами, без листания ленты.

Это **не** метрика, **не** оценка продуктивности и **не** список невыполненного.

## Границы (против брифа `DESIGN.md`)

- Никаких серий, счётчиков, графиков, напоминаний, упрёков «не успел».
- Итог **одноразовый**: не пишется в `entries.json` и ничего не оседает на
  стороне xAI (`store: false`). Закрыл окно итога — итог исчез.
- Только **текущий открытый день** (`selectedDay`).
- Сеть используется **только по явному нажатию**, как кнопка «Причесать».

Сохранение итога в день — осознанно отложено (YAGNI). Если позже понадобится —
это аддитивное необязательное поле дня с версионированием формата, отдельной
задачей. В v1 модель данных не меняется.

## Данные, уходящие в xAI (приватность)

- Отправляются **только записи выбранного дня** — `store.entriesOnDay(selectedDay)`.
  Для каждой записи: время `HH:mm`, текст, и поле «на чём остановился»
  (`context`), если оно непустое.
- **План (`DayPlan`) не отправляется.** Намерения ≠ прожитое; это убирает риск
  скатиться в упрёк о невыполненном.
- Запрос работает по **снимку** записей (`let snapshot = dayEntries` в момент
  вызова), как `notesSnapshot` в чате — правки/удаления во время запроса не
  влияют на результат.
- **Пустой день** (снимок пуст после очистки) → сеть **не трогаем**; мягкий
  статус «За этот день записей нет — нечего подытоживать.»
- Лимит контекста `maxContextCharacters = 120_000` (как в `NotesChat`) →
  `DraftPolishError.contextTooLarge`.

## Компонент 1 — Core: `Sources/Core/DaySummary.swift`

Чистый, тестируемый, без UI. Зеркалит `DraftPolish` и `NotesChat`.

```
public enum DaySummary {
    public static let model = "grok-4.7"
    public static let endpoint = URL(string: "https://api.x.ai/v1/responses")!
    public static let maxContextCharacters = 120_000
    public static let systemPrompt: String
    public static func buildDayText(_ entries: [DiaryEntry]) -> String
    public static func buildInput(entries: [DiaryEntry]) throws -> [[String: Any]]
    public static func requestBody(entries: [DiaryEntry]) throws -> Data
    public static func request(entries: [DiaryEntry], apiKey: String) throws -> URLRequest
    public static func parse(_ data: Data) throws -> String
}

public struct DaySummaryClient {
    public var session: URLSession = .shared
    public func summarize(entries: [DiaryEntry], apiKey: String) async throws -> String
}
```

Детали:

- **Переиспользование:** `XAIResponses.extractText` для разбора ответа,
  `DraftPolishError` для ошибок (`empty`, `contextTooLarge`, `badResponse`,
  `http`, `noKey`), `DraftPolish.errorMessage(from:)` для текста ошибки HTTP,
  `XAIResponses.stripCodeFence` в `parse`. Новые типы ошибок не вводим.
- **`buildDayText`** — для каждой записи строка вида
  `HH:mm — <текст>` и, если `context` непустой, вторая строка
  `  на чём остановился: <context>`. Записи уже отсортированы по времени в
  `DiaryStore`. Многострочный текст записи переносится с отступом.
- **`buildInput`** — guard: если текст дня пуст → `DraftPolishError.empty`;
  если `count > maxContextCharacters` → `.contextTooLarge(count)`. Иначе
  `[["role":"system","content": systemPrompt], ["role":"user","content": dayText]]`.
- **`requestBody`** — payload `{model, store:false, input}` через
  `JSONSerialization`, как у соседей.
- **`request`** — POST, `timeoutInterval = 90`, заголовки Content-Type и
  `Authorization: Bearer`.
- **`parse`** — `XAIResponses.extractText` + лёгкая чистка ограды кода.
  Маркеров-источников (как в `NotesChat`) здесь нет.
- **`summarize`** — trim ключа → `.noKey` если пуст; `session.data(for:)`;
  `URLError.cancelled → CancellationError`; не-2xx → `.http(code, message)`;
  иначе `parse`.

### Системный промпт (ru)

Смысл (точная формулировка — при реализации, в одном стиле с `DraftPolish`):

> Ты подводишь спокойный итог одного прожитого дня по записям дневника ниже.
> Верни 2–4 коротких фразы на языке записей. Сохрани факты, имена и числа.
> Не оценивай, не хвали, не давай советов и мотивации; не перечисляй, чего не
> сделано. Ничего не выдумывай сверх записей. Если в записях есть «на чём
> остановился», можно мягко напомнить, к чему стоит вернуться. Без кавычек,
> списков заголовков и пояснений.

## Компонент 2 — AppState

Новое состояние и один метод; по образцу `sendChat`/`polishNote`.

```
@Published private(set) var daySummary: String?
@Published private(set) var summaryBusy: Bool = false
private var summaryTask: Task<Void, Never>?

func summarizeDay()        // триггер
func clearDaySummary()     // закрытие окна итога
```

- `summarizeDay()`:
  1. `guard !summaryBusy`.
  2. snapshot `let snapshot = dayEntries`; если пуст → `showDraftStatus(...)`
     («За этот день записей нет…»), сети нет, выходим.
  3. `summaryBusy = true`; `summaryTask = Task { @MainActor in … }`.
  4. Внутри: `guard let key = XAIKeyStore.load()` иначе
     `showError(DraftPolishError.noKey.localizedDescription)` и сброс busy.
  5. `try await DaySummaryClient().summarize(entries: snapshot, apiKey: key)`;
     при `Task.isCancelled` после ответа — молча выйти.
  6. Успех → `daySummary = text`. `CancellationError` — молча.
     `contextTooLarge` и прочее → `showError`. В конце `summaryBusy = false`.
- `clearDaySummary()`: `summaryTask?.cancel()`, `summaryBusy = false`,
  `daySummary = nil`.
- Смена дня (`go(to:)`) закрывает открытый итог: вызвать `clearDaySummary()`
  там, где уместно, чтобы итог не «прилипал» к другому дню.

## Компонент 3 — UI (Views + меню)

- **Триггеры:**
  - Пункт меню **«День» → «Итог дня…»**, хоткей **⌥⌘I**. Неактивен, если день
    пуст или `summaryBusy`.
  - Тихая кнопка-действие в колонке дня (SF Symbol **нейтральный**, не
    `sparkles` — чтобы не кричать «ИИ»; кандидат — `text.alignleft` /
    `doc.plaintext`; выбрать при реализации). Неактивна на пустом дне.
- **Показ:** лёгкий **sheet** над днём (не новый `AppMode` — итог легче и
  одноразовее «Спросить»). Содержимое:
  - тихий заголовок «Итог за `<дата>`» (`DiaryFormat.shortDate`/`day`);
  - при `summaryBusy` — `ProgressView` с подписью;
  - текст итога телом (`body`, цвет `ink`, выделяемый/копируемый);
  - кнопки **«Скопировать»** (в `NSPasteboard`) и **«Закрыть»**
    (вызывает `clearDaySummary`).
  - Sheet показывается, когда `daySummary != nil || summaryBusy`.
- **Стиль:** строго по `DESIGN.md` — системный SF, токены `ink`/`quiet`/`pane`,
  без карточек-украшений, спокойно. Нет кнопки «вставить записью» (сознательно).

## Обработка ошибок

- Нет ключа → `DraftPolishError.noKey` (как везде): «Нет ключа xAI…».
- Пустой день → не ошибка, мягкий статус, без сети.
- Слишком много текста → `.contextTooLarge` (сообщение уже есть в enum).
- HTTP/сеть → `showError` с сообщением xAI.
- Отмена (смена дня / закрытие / новый запрос) → молча.

## Тестирование — `Tests/SelfTest/main.swift`

Только чистые проверки, **без сети и без доступа к данным пользователя**
(гоняются во временном каталоге, как уже заведено):

1. `buildDayText` — порядок, формат `HH:mm — текст`, строка «на чём
   остановился» только при непустом `context`, перенос многострочного текста.
2. `buildInput`/`requestBody` — форма payload (`store:false`, роли system/user),
   системный промпт присутствует.
3. `parse` — извлечение текста из фикстуры ответа Responses API (с пропуском
   блока `reasoning`), снятие ограды кода.
4. Guard пустого дня → `DraftPolishError.empty` из `buildInput`.
5. `contextTooLarge` — на искусственно большом дне.

`build.sh`/`test.sh` уже компилируют все файлы в `Sources/` — отдельной
настройки сборки не требуется.

## Что НЕ делаем в v1

- Не сохраняем итог (ни в день, ни отдельным файлом).
- Не отправляем план и другие дни.
- Не добавляем кнопку «вставить итог записью».
- Не вводим новых типов ошибок и нового `AppMode`.

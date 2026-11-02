// Markdown для заметок: чистый Foundation, без сети, без HTML/WebKit.
// Тело заметки хранится как сырой Markdown; здесь только разбор для просмотра.
import Foundation

/// Пункт списка. Списки хранятся плоско, вложенность — через `level` (0 — верхний уровень).
public struct MarkdownListItem: Equatable {
    public var level: Int
    public var ordered: Bool
    /// Отображаемый номер для нумерованного пункта (последовательная нумерация на уровне), иначе nil.
    public var number: Int?
    /// nil — обычный пункт; false — `[ ]`; true — `[x]`. Только для чтения.
    public var task: Bool?
    /// Текст пункта (строчный Markdown), продолжения строк соединены через "\n".
    public var text: String

    public init(level: Int, ordered: Bool, number: Int?, task: Bool?, text: String) {
        self.level = level
        self.ordered = ordered
        self.number = number
        self.task = task
        self.text = text
    }
}

public enum MarkdownBlock: Equatable {
    /// ATX-заголовок `#`…`######`. Текст — строчный Markdown.
    case heading(level: Int, text: String)
    /// Абзац; переносы строк внутри сохранены ("\n").
    case paragraph(String)
    /// Огороженный код ``` или ~~~. Содержимое — буквально. `closed == false` — ограда не закрыта
    /// (тогда код идёт до конца текста, ничего не теряется).
    case code(language: String?, code: String, closed: Bool)
    case list([MarkdownListItem])
    case quote([MarkdownBlock])
    case rule
    /// GFM-таблица: показывается как литеральный текст строк, без раскладки по ячейкам.
    case table([String])
}

public enum NoteMarkdown {
    public static let maxQuoteDepth = 8
    public static let maxListDepth = 8

    // MARK: - Блоки

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        return parseBlocks(lines[...], depth: 0)
    }

    static func parseBlocks(_ lines: ArraySlice<String>, depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i]
            if isBlank(line) { flush(); i += 1; continue }

            if let fence = fenceOpening(line) {
                flush()
                var body: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.endIndex {
                    if isFenceClosing(lines[j], fence) { closed = true; break }
                    body.append(stripIndent(lines[j], upTo: fence.indent))
                    j += 1
                }
                blocks.append(.code(language: fence.language, code: body.joined(separator: "\n"), closed: closed))
                i = closed ? j + 1 : j
                continue
            }
            if let h = heading(line) { flush(); blocks.append(h); i += 1; continue }
            if isRule(line) { flush(); blocks.append(.rule); i += 1; continue }
            if quoteContent(line) != nil {
                flush()
                var inner: [String] = []
                var j = i
                while j < lines.endIndex, let c = quoteContent(lines[j]) { inner.append(c); j += 1 }
                if depth < maxQuoteDepth {
                    blocks.append(.quote(parseBlocks(inner[...], depth: depth + 1)))
                } else {
                    blocks.append(.paragraph(inner.joined(separator: "\n")))
                }
                i = j
                continue
            }
            if isTableStart(lines, at: i) {
                flush()
                var rows: [String] = []
                var j = i
                while j < lines.endIndex, !isBlank(lines[j]), lines[j].contains("|") { rows.append(lines[j]); j += 1 }
                blocks.append(.table(rows))
                i = j
                continue
            }
            if let marker = listMarker(line), paragraph.isEmpty || marker.canInterruptParagraph {
                flush()
                let (items, next) = parseList(lines, from: i)
                blocks.append(.list(items))
                i = max(next, i + 1)
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    // MARK: Огороженный код

    struct Fence {
        let char: Character
        let count: Int
        let indent: Int
        let language: String?
    }

    static func fenceOpening(_ line: String) -> Fence? {
        let indent = line.prefix(while: isSpaceOrTab).count
        let rest = line.dropFirst(indent)
        guard let c = rest.first, c == "`" || c == "~" else { return nil }
        let run = rest.prefix(while: { $0 == c }).count
        guard run >= 3 else { return nil }
        let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if c == "`" && info.contains("`") { return nil }   // это строчный код, не ограда
        let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        return Fence(char: c, count: run, indent: indent, language: language)
    }

    static func isFenceClosing(_ line: String, _ fence: Fence) -> Bool {
        let rest = line.drop(while: isSpaceOrTab)
        let run = rest.prefix(while: { $0 == fence.char }).count
        guard run >= fence.count else { return false }
        return rest.dropFirst(run).allSatisfy(isSpaceOrTab)
    }

    static func stripIndent(_ line: String, upTo n: Int) -> String {
        guard n > 0 else { return line }
        var dropped = 0
        var idx = line.startIndex
        while dropped < n, idx < line.endIndex, isSpaceOrTab(line[idx]) {
            idx = line.index(after: idx)
            dropped += 1
        }
        return String(line[idx...])
    }

    // MARK: Заголовки, линии, цитаты, таблицы

    static func heading(_ line: String) -> MarkdownBlock? {
        let lead = line.prefix(while: { $0 == " " }).count
        guard lead <= 3 else { return nil }
        let rest = line.dropFirst(lead)
        let hashes = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let after = rest.dropFirst(hashes)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Закрывающие решётки «## Заголовок ##».
        if text.allSatisfy({ $0 == "#" }) {
            text = ""
        } else if let r = text.range(of: #"\s#+$"#, options: .regularExpression) {
            text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: hashes, text: text)
    }

    static func isRule(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        let chars = line.filter { !isSpaceOrTab($0) }
        guard chars.count >= 3, let first = chars.first, first == "-" || first == "*" || first == "_" else { return false }
        return chars.allSatisfy { $0 == first }
    }

    static func quoteContent(_ line: String) -> String? {
        let lead = line.prefix(while: { $0 == " " }).count
        guard lead <= 3 else { return nil }
        var rest = line.dropFirst(lead)
        guard rest.first == ">" else { return nil }
        rest = rest.dropFirst()
        if let f = rest.first, isSpaceOrTab(f) { rest = rest.dropFirst() }
        return String(rest)
    }

    static func isTableStart(_ lines: ArraySlice<String>, at i: Int) -> Bool {
        guard i + 1 < lines.endIndex, lines[i].contains("|") else { return false }
        return isTableDelimiter(lines[i + 1])
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        let allowed: Set<Character> = ["|", "-", ":", " ", "\t"]
        guard t.contains("|"), t.contains("-"), t.allSatisfy({ allowed.contains($0) }) else { return false }
        let cells = t.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy { $0.contains("-") }
    }

    // MARK: Списки

    struct ListMarker {
        let indent: Int
        let ordered: Bool
        let number: Int?
        let content: String
        /// Как в CommonMark: нумерованный список прерывает абзац только с «1.».
        var canInterruptParagraph: Bool { !ordered || number == 1 }
    }

    static func listMarker(_ line: String) -> ListMarker? {
        var indent = 0
        for ch in line {
            if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 } else { break }
        }
        let rest = line.drop(while: isSpaceOrTab)
        guard let c = rest.first else { return nil }
        if c == "-" || c == "*" || c == "+" {
            let after = rest.dropFirst()
            guard after.isEmpty || isSpaceOrTab(after.first!) else { return nil }
            return ListMarker(indent: indent, ordered: false, number: nil, content: String(after.drop(while: isSpaceOrTab)))
        }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...9).contains(digits.count) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let d = afterDigits.first, d == "." || d == ")" else { return nil }
        let after = afterDigits.dropFirst()
        guard after.isEmpty || isSpaceOrTab(after.first!) else { return nil }
        return ListMarker(indent: indent, ordered: true, number: Int(digits), content: String(after.drop(while: isSpaceOrTab)))
    }

    static func parseList(_ lines: ArraySlice<String>, from start: Int) -> ([MarkdownListItem], Int) {
        var items: [MarkdownListItem] = []
        var indents: [Int] = []
        var counters: [Int: Int] = [:]
        var i = start

        while i < lines.endIndex {
            let line = lines[i]
            if isBlank(line) {
                // Пустая строка продолжает список, только если дальше снова пункт.
                var j = i + 1
                while j < lines.endIndex, isBlank(lines[j]) { j += 1 }
                if j < lines.endIndex, listMarker(lines[j]) != nil, !isRule(lines[j]) { i = j; continue }
                break
            }
            if isRule(line) || fenceOpening(line) != nil || heading(line) != nil
                || quoteContent(line) != nil || isTableStart(lines, at: i) {
                break
            }
            if let m = listMarker(line) {
                if indents.isEmpty {
                    indents = [m.indent]
                } else if m.indent > indents[indents.count - 1] + 1 {
                    if indents.count < maxListDepth { indents.append(m.indent) }
                } else {
                    while indents.count > 1, m.indent < indents[indents.count - 1] - 1 { indents.removeLast() }
                }
                let level = indents.count - 1
                for key in counters.keys where key > level { counters[key] = nil }

                var number: Int? = nil
                if m.ordered {
                    let n = counters[level].map { $0 + 1 } ?? (m.number ?? 1)
                    counters[level] = n
                    number = n
                } else {
                    counters[level] = nil
                }

                let (task, text) = splitTask(m.content)
                items.append(MarkdownListItem(level: level, ordered: m.ordered, number: number, task: task, text: text))
                i += 1
                continue
            }
            // Ленивое продолжение текста пункта.
            guard !items.isEmpty else { break }
            items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
            i += 1
        }
        return (items, i)
    }

    static func splitTask(_ content: String) -> (Bool?, String) {
        for (prefix, done) in [("[ ]", false), ("[x]", true), ("[X]", true)] where content.hasPrefix(prefix) {
            let rest = content.dropFirst(prefix.count)
            if rest.isEmpty { return (done, "") }
            if let f = rest.first, isSpaceOrTab(f) { return (done, String(rest.drop(while: isSpaceOrTab))) }
        }
        return (nil, content)
    }

    // MARK: - Строчная разметка

    /// Строчный Markdown → AttributedString (жирный, курсив, зачёркнутый, `код`, ссылки).
    /// HTML и картинки остаются литеральным текстом; небезопасные ссылки снимаются.
    /// Никогда не бросает: при ошибке разбора — исходный текст как есть.
    public static func inline(_ text: String) -> AttributedString {
        let prepared = escapeUnsafeInline(text)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: prepared, options: options) else {
            return AttributedString(text)
        }
        if parsed.characters.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AttributedString(text)
        }
        var result = AttributedString()
        for (link, range) in parsed.runs[\.link] {
            var piece = AttributedString(parsed[range])
            if let link, !isSafeLink(link) { piece.link = nil }
            result += piece
        }
        return result
    }

    /// Открывать можно только http/https с непустым хостом. file:, javascript:, data:,
    /// mailto:, собственные схемы и относительные ссылки — нет.
    public static func isSafeLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Экранирует `<` (кроме автоссылок `<http(s)://…>`) и `![` перед разбором, чтобы HTML и картинки
    /// показывались буквально. Содержимое `код`-спанов и уже экранированные символы не трогаются.
    public static func escapeUnsafeInline(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count + 8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                out.append(c)
                if i + 1 < chars.count { out.append(chars[i + 1]) }
                i += 2
                continue
            }
            if c == "`" {
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                var j = i + n
                var close: Int? = nil
                while j < chars.count {
                    if chars[j] == "`" {
                        var m = 0
                        while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                        if m == n { close = j; break }
                        j += m
                    } else {
                        j += 1
                    }
                }
                let end = close.map { $0 + n } ?? (i + n)
                out.append(contentsOf: chars[i..<end])
                i = end
                continue
            }
            if c == "<" {
                if let end = autolinkEnd(chars, from: i) {
                    out.append(contentsOf: chars[i...end])
                    i = end + 1
                } else {
                    out.append("\\<")
                    i += 1
                }
                continue
            }
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[" {
                out.append("!\\[")
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    static func autolinkEnd(_ chars: [Character], from start: Int) -> Int? {
        var j = start + 1
        var body = ""
        while j < chars.count {
            let ch = chars[j]
            if ch == ">" { break }
            if ch == "<" || ch.isWhitespace { return nil }
            body.append(ch)
            j += 1
        }
        guard j < chars.count else { return nil }
        let lower = body.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard let url = URL(string: body), isSafeLink(url) else { return nil }
        return j
    }

    // MARK: - Утилиты

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func isSpaceOrTab(_ c: Character) -> Bool { c == " " || c == "\t" }
}

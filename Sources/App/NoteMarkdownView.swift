import SwiftUI

/// Просмотр тела заметки как Markdown. Только чтение: ничего не сохраняет, не грузит из сети,
/// не исполняет HTML. Ссылки открываются только по клику и только http/https.
struct NoteMarkdownView: View {
    let source: String

    var body: some View {
        let blocks = NoteMarkdown.parse(source)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if blocks.isEmpty {
                    Text("Пока нечего показать — текст заметки пуст.")
                        .font(.callout)
                        .foregroundStyle(Theme.quiet)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { pair in
                        NoteMarkdownBlockView(block: pair.element)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rail, lineWidth: 1))
        .tint(Theme.accent)
        .environment(\.openURL, OpenURLAction { url in
            NoteMarkdown.isSafeLink(url) ? .systemAction : .discarded
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Просмотр заметки")
    }
}

struct NoteMarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(NoteMarkdown.inline(text))
                .font(Self.headingFont(level))
                .foregroundStyle(level == 6 ? Theme.quiet : Theme.ink)
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

        case let .paragraph(text):
            Text(NoteMarkdown.inline(text))
                .font(.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .code(language, code, _):
            NoteMarkdownCodeView(label: language, code: code)

        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    NoteMarkdownListRow(item: pair.element)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .quote(inner):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(inner.enumerated()), id: \.offset) { pair in
                    NoteMarkdownBlockView(block: pair.element)
                }
            }
            .padding(.leading, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.rail)
                    .frame(width: 3)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Цитата")

        case .rule:
            Rectangle()
                .fill(Theme.rail)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityLabel("Разделитель")

        case let .table(rows):
            NoteMarkdownCodeView(label: "Таблица (показана как текст)", code: rows.joined(separator: "\n"))
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .bold)
        case 2: return .system(size: 19, weight: .semibold)
        case 3: return .system(size: 16, weight: .semibold)
        case 4: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

struct NoteMarkdownListRow: View {
    let item: MarkdownListItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if item.ordered || item.task == nil {
                Text(verbatim: marker)
                    .foregroundStyle(Theme.quiet)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
            }
            if let done = item.task {
                Image(systemName: done ? "checkmark.square" : "square")
                    .foregroundStyle(done ? Theme.accent : Theme.quiet)
                    .accessibilityLabel(done ? "Выполнено" : "Не выполнено")
            }
            Text(NoteMarkdown.inline(item.text))
                .font(.body)
                .foregroundStyle(item.task == true ? Theme.quiet : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(min(item.level, 6)) * 18)
    }

    private var marker: String {
        if item.ordered { return "\(item.number ?? 1)." }
        switch item.level % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪︎"
        }
    }
}

/// Код и таблицы: буквальный текст (`Text(verbatim:)`), моноширинный, с горизонтальной прокруткой.
struct NoteMarkdownCodeView: View {
    let label: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label, !label.isEmpty {
                Text(verbatim: label)
                    .font(.caption)
                    .foregroundStyle(Theme.quiet)
            }
            ScrollView(.horizontal) {
                Text(verbatim: code.isEmpty ? " " : code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rail, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

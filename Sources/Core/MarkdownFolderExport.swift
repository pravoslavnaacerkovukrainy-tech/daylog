import Foundation

public struct MarkdownFolderExportResult: Equatable {
    public let folderURL: URL
    public let readmeURL: URL
    public let archiveURL: URL
    public let daysDirectoryURL: URL
    public let notesDirectoryURL: URL
}

public enum MarkdownFolderExport {
    public static func export(store: DiaryStore,
                             parentDirectory: URL,
                             now: Date = Date(),
                             calendar: Calendar = .current) throws -> MarkdownFolderExportResult {
        if let reason = store.blockReason { throw DiaryError.storeBlocked(reason) }

        let fm = FileManager.default
        let parent = parentDirectory.standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw DiaryError.writeFailed("выбранная папка не существует: \(parent.path)")
        }

        let staging = parent.appendingPathComponent(".daylog-export-\(UUID().uuidString)", isDirectory: true)
        let finalName = finalDirectoryName(now: now)
        let finalURL = parent.appendingPathComponent(finalName, isDirectory: true)
        var ownsStaging = false
        let cleanupStaging = { if ownsStaging { try? fm.removeItem(at: staging) } }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            ownsStaging = true
            let daysDirectory = staging.appendingPathComponent("Дни", isDirectory: true)
            let notesDirectory = staging.appendingPathComponent("Заметки", isDirectory: true)
            try fm.createDirectory(at: daysDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

            let archiveURL = staging.appendingPathComponent("Архив.json")
            let readmeURL = staging.appendingPathComponent("README.md")

            let archiveData = try store.exportJSON(now: now)
            try archiveData.write(to: archiveURL, options: .withoutOverwriting)

            let foldersByID = Dictionary(uniqueKeysWithValues: store.noteFolders.map { ($0.id, $0) })
            let folderPaths = foldersByID.mapValues { folder in
                NoteFolder.path(to: folder.id, in: foldersByID)
            }
            let readmeData = Data(readmeText(store: store, folderPaths: folderPaths, now: now, calendar: calendar).utf8)
            try readmeData.write(to: readmeURL, options: .withoutOverwriting)
            if store.hasOrganizerData {
                try Data(store.organizerMarkdown(calendar: calendar).utf8)
                    .write(to: staging.appendingPathComponent("Органайзер.md"), options: .withoutOverwriting)
            }

            let dayKeys = sortedDayKeys(store: store, calendar: calendar)
            for (offset, key) in dayKeys.enumerated() {
                let filename = safeDayFilename(for: key, sortedIndex: offset, calendar: calendar)
                let fileURL = daysDirectory.appendingPathComponent(filename)
                let body = dayMarkdownFile(store: store, key: key, calendar: calendar)
                try Data(body.utf8).write(to: fileURL, options: .withoutOverwriting)
            }

            var folderURLs: [UUID: URL] = [:]
            for (id, path) in folderPaths {
                let folderURL = path.reduce(notesDirectory) { directory, folder in
                    directory.appendingPathComponent(noteFolderDirectoryName(folder), isDirectory: true)
                }
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
                folderURLs[id] = folderURL
            }
            for note in store.sortedNotes() {
                let filename = "\(note.id.uuidString).md"
                let directory = note.folderID.flatMap { folderURLs[$0] } ?? notesDirectory
                let fileURL = directory.appendingPathComponent(filename)
                let body = noteMarkdownFile(note: note, calendar: calendar)
                try Data(body.utf8).write(to: fileURL, options: .withoutOverwriting)
            }

            try fm.moveItem(at: staging, to: finalURL)
            ownsStaging = false

            return MarkdownFolderExportResult(
                folderURL: finalURL,
                readmeURL: finalURL.appendingPathComponent("README.md"),
                archiveURL: finalURL.appendingPathComponent("Архив.json"),
                daysDirectoryURL: finalURL.appendingPathComponent("Дни"),
                notesDirectoryURL: finalURL.appendingPathComponent("Заметки")
            )
        } catch {
            cleanupStaging()
            throw error
        }
    }
}

public extension DiaryStore {
    func exportMarkdownFolder(parentDirectory: URL, now: Date = Date(), calendar: Calendar = .current) throws -> MarkdownFolderExportResult {
        try MarkdownFolderExport.export(store: self, parentDirectory: parentDirectory, now: now, calendar: calendar)
    }
}

private func finalDirectoryName(now: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = formatter.string(from: now)
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: ".", with: "-")
    return "daylog-export-\(stamp)-\(UUID().uuidString)"
}

private func sortedDayKeys(store: DiaryStore, calendar: Calendar) -> [String] {
    let set = Set(store.entries.map { DiaryDay.key($0.timestamp, calendar: calendar) })
        .union(store.plans.map(\.day).filter { !$0.isEmpty })
    return set.sorted()
}

private func readmeText(store: DiaryStore, folderPaths: [UUID: [NoteFolder]], now: Date, calendar: Calendar) -> String {
    let timeZone = calendar.timeZone
    let tzName = timeZone.identifier.isEmpty ? "UTC" : timeZone.identifier
    let offset = offsetString(for: timeZone, at: now)
    let dayKeys = sortedDayKeys(store: store, calendar: calendar)
    let totalDays = dayKeys.count
    let totalPlans = store.plans.count
    let totalNotes = store.notes.count
    let exportStamp = formattedDateTime(now, calendar: calendar)
    var out = [
        "# Хаос Дня — экспорт",
        "",
        "Экспортировано: \(exportStamp) (\(tzName), UTC\(offset))",
        "Временная зона: \(tzName)",
        "Записей: \(store.entries.count); Планов: \(totalPlans); Заметок: \(totalNotes); Дней: \(totalDays)",
        "",
        "Этот каталог создан внутри выбранной папки и содержит только экспорт дневника для чтения в ChatGPT, Obsidian и других редакторах.",
        "Полный архив сохраняется в [Архив.json](Архив.json): это схема-совместимый JSON, который точно соответствует содержимому текущего хранилища.",
        "Markdown — для чтения, JSON — полный архив без потерь. Несохранённые черновики не включены.",
        "",
        "## Содержимое",
        "",
        "### Дни",
    ].joined(separator: "\n")

    if dayKeys.isEmpty {
        out += "\n- Пустой экспорт: записей и планов за этот период нет.\n"
    } else {
        for (offset, key) in dayKeys.enumerated() {
            let fileName = safeDayFilename(for: key, sortedIndex: offset, calendar: calendar)
            let label = dayReadmeLabel(for: key, calendar: calendar)
            out += "\n- [\(markdownLinkLabel(label))](Дни/\(fileName))"
        }
    }

    out += "\n\n### Заметки\n"
    let folderLinks = folderPaths.mapValues { $0.map(noteFolderDirectoryName).joined(separator: "/") + "/" }
    if !store.noteFolders.isEmpty {
        out += "\nПапки\n"
        for folder in store.noteFolders {
            guard let path = folderPaths[folder.id], let link = folderLinks[folder.id] else { continue }
            let label = path.map(\.name).joined(separator: " › ")
            out += "- [\(markdownLinkLabel(label))](Заметки/\(link))\n"
        }
        out += "\n"
    }
    if store.notes.isEmpty {
        out += "- В этом экспорте заметок нет.\n"
    } else {
        for note in store.sortedNotes() {
            let fileName = "\(note.id.uuidString).md"
            let label = note.title.isEmpty ? "Без заголовка" : note.title
            let prefix = note.folderID.flatMap { folderLinks[$0] } ?? ""
            out += "\n- [\(markdownLinkLabel(label))](Заметки/\(prefix)\(fileName))"
        }
    }

    out += "\n\n### Архив\n- [Архив.json](Архив.json) — полный JSON-архив дневника.\n"
    if store.hasOrganizerData { out += "\n- [Органайзер](Органайзер.md) — проекты, задачи, сроки и ожидания.\n" }
    return out + "\n"
}

private func noteFolderDirectoryName(_ folder: NoteFolder) -> String {
    let stem = folder.name.unicodeScalars.prefix(40).map {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "-"
    }.joined()
    return "\(stem)-\(folder.id.uuidString)"
}

private func dayMarkdownFile(store: DiaryStore, key: String, calendar: Calendar) -> String {
    let validDate = strictDayDate(key, calendar: calendar)
    let dateText = validDate.map { formattedDayDate($0, calendar: calendar) } ?? "неверная дата"
    let timezone = calendar.timeZone.identifier.isEmpty ? "UTC" : calendar.timeZone.identifier
    var out = "# \(normalizeMarkdownTitle(key)) — \(dateText)\n\n"
    out += "- Временная зона: \(timezone)\n"
    out += "- Дата: \(normalizeMarkdownText(key))\n"
    if validDate == nil {
        out += "- Состояние: дата не распознана, исходный ключ сохранён как есть.\n"
    }

    let dayPlans = DiaryStore.sortedPlans(store.plans.filter { $0.day == key })
    let dayEntries = DiaryStore.sorted(store.entries.filter { DiaryDay.key($0.timestamp, calendar: calendar) == key })

    if !dayPlans.isEmpty {
        out += "\n## План\n"
        for p in dayPlans {
            let prefix = p.completedAt == nil ? "- [ ] " : "- [x] "
            for line in markdownIndentedLines(p.text, prefix: prefix) {
                out += "\(line)\n"
            }
            if let completedAt = p.completedAt {
                let stamp = formattedDateTime(completedAt, calendar: calendar)
                out += "  Выполнено: \(stamp)\n"
            }
        }
    }

    if !dayEntries.isEmpty {
        if !dayPlans.isEmpty { out += "\n" }
        out += "## Записи\n"
        for e in dayEntries {
            let timeText = formattedTime(e.timestamp, calendar: calendar)
            let bodyText = markdownIndentedLines(e.text, prefix: "- \(timeText) — ")
            out += bodyText.joined(separator: "\n") + "\n"
            if let context = e.context {
                out += markdownIndentedLines(context, prefix: "  - На чём остановился: ", continuation: "    ")
                    .joined(separator: "\n") + "\n"
            }
        }
    }

    if dayPlans.isEmpty && dayEntries.isEmpty {
        out += "\nПустой день: в этом дне нет ни записей, ни пунктов плана.\n"
    }

    return out + "\n"
}

private func noteMarkdownFile(note: DiaryNote, calendar: Calendar) -> String {
    let title = note.title.isEmpty ? "Без заголовка" : note.title
    let safeTitle = normalizeMarkdownTitle(title)
    let created = formattedDateTime(note.createdAt, calendar: calendar)
    let updated = formattedDateTime(note.updatedAt, calendar: calendar)
    let pinned = note.pinned ? "да" : "нет"
    let header = "# \(safeTitle)\n\n"
    let metadata = [
        "- ID: \(note.id.uuidString)",
        "- Заголовок: \(normalizeMarkdownText(title))",
        "- Создано: \(created)",
        "- Обновлено: \(updated)",
        "- Закреплено: \(pinned)"
    ].joined(separator: "\n") + "\n\n"
    return header + metadata + note.body
}

private func markdownIndentedLines(_ text: String, prefix: String = "", continuation: String = "  ") -> [String] {
    let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let parts = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty else { return [prefix] }
    var result: [String] = []
    for (idx, part) in parts.enumerated() {
        let rendered = "\(idx == 0 ? prefix : continuation)\(markdownInlineText(part))"
        result.append(rendered)
    }
    return result
}

private func normalizeMarkdownText(_ text: String) -> String {
    markdownInlineText(text
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " "))
}

private func normalizeMarkdownTitle(_ text: String) -> String {
    normalizeMarkdownText(text)
}

private func dayReadmeLabel(for key: String, calendar: Calendar) -> String {
    if strictDayDate(key, calendar: calendar) != nil {
        return key
    }
    return "Неверная дата: \(key)"
}

private func markdownLinkLabel(_ text: String) -> String {
    normalizeMarkdownText(text)
}

private func safeDayFilename(for key: String, sortedIndex: Int, calendar: Calendar) -> String {
    if strictDayDate(key, calendar: calendar) != nil {
        return "\(key).md"
    }
    return "invalid-day-\(sortedIndex).md"
}

private func strictDayDate(_ key: String, calendar: Calendar) -> Date? {
    guard key.utf8.count == 10,
          key.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
          let date = DiaryDay.date(key, calendar: calendar),
          DiaryDay.key(date, calendar: calendar) == key else { return nil }
    return date
}

private func formattedDateTime(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "d MMMM yyyy, HH:mm"
    return formatter.string(from: date)
}

private func formattedDayDate(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "EEEE, d MMMM yyyy"
    return formatter.string(from: date)
}

private func formattedTime(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func offsetString(for timeZone: TimeZone, at date: Date) -> String {
    let seconds = timeZone.secondsFromGMT(for: date)
    let mins = abs(seconds / 60)
    let hours = mins / 60
    let minutes = mins % 60
    return String(format: "%@%02d:%02d", seconds >= 0 ? "+" : "-", hours, minutes)
}

func markdownInlineText(_ text: String) -> String {
    var out = text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\\", with: "\\\\")
    for character in ["*", "_", "[", "]", "(", ")", "#", "`", "~", "!", "|"] {
        out = out.replacingOccurrences(of: character, with: "\\" + character)
    }
    return out
}

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Окно можно закрыть — приложение остаётся в строке меню.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Устанавливается из SwiftUI (openWindow), чтобы Dock мог заново открыть закрытое окно.
    static var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let open = AppDelegate.openMainWindow {
            open()
            return false
        }
        return true
    }
}

@main
struct DaylogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Хаос Дня", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified)
        .commands { DaylogCommands(state: state) }

        MenuBarExtra("Хаос Дня", systemImage: "clock") {
            MenuBarContent()
                .environmentObject(state)
        }
    }
}

struct DaylogCommands: Commands {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    private func show(_ mode: AppMode) {
        state.mode = mode
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Дела") { show(.organizer) }
                .keyboardShortcut("1")
            Button("Дневник") { show(.day) }
                .keyboardShortcut("2")
            Button("Заметки") { show(.notes) }
                .keyboardShortcut("3")
            Button("Спросить") {
                show(.ask)
                NotificationCenter.default.post(name: .daylogAskFocus, object: state)
            }
                .keyboardShortcut("4")
            Divider()
        }
        CommandGroup(replacing: .newItem) {
            Button("Новая запись") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                state.requestFocus(.add)
            }
                .keyboardShortcut("n")
            // Отдельная быстрая запись хаоса: ⌃⌘N не совпадает с ⌘N, ⇧⌘N, ⌥⌘N и системными сочетаниями.
            Button("Записать в место хаоса") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                state.requestChaosCapture()
            }
                .keyboardShortcut("n", modifiers: [.command, .control])
            Button("Новая задача") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                state.requestNewTask()
            }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(state.isBlocked)
            Button("Новая заметка") {
                state.mode = .notes
                state.selectedNoteID = nil
                state.noteSearchText = ""
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                NotificationCenter.default.post(name: .daylogNewNote, object: state)
            }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(after: .importExport) {
            Button("Экспорт в JSON…") { state.exportJSON() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Экспорт в Markdown…") { state.exportMarkdown() }
            Button("Экспорт в папку Markdown…") { state.exportMarkdownFolder() }
            Divider()
            Button("Показать файл данных в Finder") { state.revealDataFile() }
        }
        CommandMenu("День") {
            Button("Сегодня") { state.goToday() }
                .keyboardShortcut("t")
            Button("Предыдущий день") { state.goPrev() }
                .keyboardShortcut("[")
            Button("Следующий день") { state.goNext() }
                .keyboardShortcut("]")
            Divider()
            Button("Найти по всем дням") { state.requestFocus(.search) }
                .keyboardShortcut("f")
            Divider()
            Button("Спросить ИИ") {
                state.mode = .ask
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                NotificationCenter.default.post(name: .daylogAskFocus, object: state)
            }
            Button("Итог дня…") {
                state.mode = .day
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                state.summarizeDay()
            }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(state.dayEntries.isEmpty || state.summaryBusy || state.isBlocked || state.isSearching)
            Divider()
            Button("Причесать черновик") { state.requestPolish() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
            Button("Ключ QwenCloud…") { state.keySheetIntent = .settings }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Новая запись…") {
            showWindow()
            state.requestFocus(.add)
        }
        Button("Записать в место хаоса…") {
            showWindow()
            state.requestChaosCapture()
        }
        Button("Новая задача…") {
            showWindow()
            state.requestNewTask()
        }
        .disabled(state.isBlocked)
        Button("Новая заметка…") {
            state.mode = .notes
            state.selectedNoteID = nil
            state.noteSearchText = ""
            showWindow()
            NotificationCenter.default.post(name: .daylogNewNote, object: state)
        }
        Button("Открыть «Хаос Дня»") {
            showWindow()
        }
        Divider()
        Button("Экспорт в Markdown…") {
            showWindow()
            state.exportMarkdown()
        }
        Button("Экспорт в папку Markdown…") {
            showWindow()
            state.exportMarkdownFolder()
        }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

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
        Window("Ход дня", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified)
        .commands { DaylogCommands(state: state) }

        MenuBarExtra("Ход дня", systemImage: "clock") {
            MenuBarContent()
                .environmentObject(state)
        }
    }
}

struct DaylogCommands: Commands {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новая запись") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                state.requestFocus(.add)
            }
                .keyboardShortcut("n")
            Button("Новый пункт плана") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                state.requestFocus(.plan)
            }
                .keyboardShortcut("n", modifiers: [.command, .shift])
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
            Button("Показать или скрыть план") { state.showPlan.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Причесать черновик") { state.requestPolish() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
            Button("Ключ xAI…") { state.keySheetIntent = .settings }
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
        Button("Новый пункт плана…") {
            showWindow()
            state.requestFocus(.plan)
        }
        Button("Новая заметка…") {
            state.mode = .notes
            state.selectedNoteID = nil
            state.noteSearchText = ""
            showWindow()
            NotificationCenter.default.post(name: .daylogNewNote, object: state)
        }
        Button("Открыть «Ход дня»") {
            showWindow()
        }
        Divider()
        Button("Экспорт в Markdown…") {
            showWindow()
            state.exportMarkdown()
        }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

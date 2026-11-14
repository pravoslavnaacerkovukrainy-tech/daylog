import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: LaunchConfig
    private var windowController: WebWindowController?

    init(config: LaunchConfig) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let wc = WebWindowController(config: config)
        windowController = wc
        wc.showWindow(nil)
        wc.loadHome()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    // MARK: - Меню

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Хаос Дня Веб"

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О программе «\(appName)»",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть «\(appName)»", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Скрыть остальные",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Показать все", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить «\(appName)»", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: appName, to: main)

        // Правка: без этих пунктов ⌘C/⌘V/⌘A не работают в полях веб-формы.
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: "Правка", to: main)

        let view = NSMenu(title: "Вид")
        view.addItem(withTitle: "Обновить страницу", action: #selector(WebWindowController.reloadPage(_:)), keyEquivalent: "r")
        view.addItem(withTitle: "На главную", action: #selector(WebWindowController.goHome(_:)), keyEquivalent: "H")
        view.addItem(.separator())
        view.addItem(withTitle: "Назад", action: #selector(WebWindowController.goBack(_:)), keyEquivalent: "[")
        view.addItem(withTitle: "Вперёд", action: #selector(WebWindowController.goForward(_:)), keyEquivalent: "]")
        view.addItem(.separator())
        view.addItem(withTitle: "Фактический размер", action: #selector(WebWindowController.zoomReset(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Увеличить", action: #selector(WebWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Уменьшить", action: #selector(WebWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Полноэкранный режим",
                                      action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(view, title: "Вид", to: main)

        let window = NSMenu(title: "Окно")
        window.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Масштаб", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, title: "Окно", to: main)
        NSApp.windowsMenu = window
        return main
    }

    private func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}

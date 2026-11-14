import AppKit
import WebKit

/// Единственное окно: WKWebView со штатным веб-интерфейсом. JS-моста нет (ни messageHandlers,
/// ни user scripts), TLS проверяет система — обработчика challenge нет.
final class WebWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Постоянный профиль WebKit только этого приложения (cookies, localStorage, IndexedDB).
    /// Меняйте идентификатор, лишь если нужен чистый профиль: старые данные станут недоступны.
    static let profileID = UUID(uuidString: "6C1D5E2A-9B47-4F0E-8A3C-D21E7B5F9A04")!

    private let config: LaunchConfig
    private let webView: WKWebView
    private let errorView = ErrorOverlayView()
    private var titleObservation: NSKeyValueObservation?
    private var lastFailedURL: URL?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    init(config: LaunchConfig) {
        self.config = config

        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = config.persistentProfile
            ? WKWebsiteDataStore(forIdentifier: Self.profileID)
            : .nonPersistent()
        wkConfig.preferences.javaScriptCanOpenWindowsAutomatically = false
        wkConfig.preferences.isElementFullscreenEnabled = true
        wkConfig.limitsNavigationsToAppBoundDomains = false
        webView = WKWebView(frame: .zero, configuration: wkConfig)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if CHAOS_WEB_DEBUG
        webView.isInspectable = true
        #endif

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 400)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Хаос Дня Веб"
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.retry() }
        container.addSubview(webView)
        container.addSubview(errorView)
        for v in [webView, errorView] as [NSView] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window.contentView = container
        window.center()
        window.setFrameAutosaveName("ChaosDayWebMain")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self, let title = wv.title, !title.isEmpty else { return }
            self.window?.title = title
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func loadHome() {
        hideError()
        webView.load(URLRequest(url: config.home))
    }

    // MARK: - Команды меню (через responder chain)

    @objc func reloadPage(_ sender: Any?) {
        if !errorView.isHidden || webView.url == nil { retry() } else { webView.reload() }
    }
    @objc func goHome(_ sender: Any?) { loadHome() }
    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func zoomReset(_ sender: Any?) { webView.pageZoom = 1 }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return webView.canGoBack
        case #selector(goForward(_:)): return webView.canGoForward
        default: return true
        }
    }

    // MARK: - Ошибка и повтор

    private func retry() {
        hideError()
        let target = lastFailedURL ?? webView.url ?? config.home
        lastFailedURL = nil
        webView.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    private func showError(_ error: Error, url: URL?) {
        let ns = error as NSError
        // Отмена и перевод навигации в загрузку файла — не ошибки для пользователя.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        lastFailedURL = url ?? (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
        errorView.message = ns.localizedDescription
        errorView.isHidden = false
        #if CHAOS_WEB_DEBUG
        if config.smokeTest {
            smokeReport("FAIL \(ns.domain) \(ns.code) overlay=\(errorView.isHidden ? "hidden" : "shown")")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        #endif
    }

    private func hideError() { errorView.isHidden = true }

    fileprivate func smokeReport(_ line: String) {
        #if CHAOS_WEB_DEBUG
        guard config.smokeTest else { return }
        print("SMOKE \(line)")
        fflush(stdout)
        #endif
    }

    #if CHAOS_WEB_DEBUG
    fileprivate func smokeAfterLoad() {
        guard config.smokeTest else { return }
        // Заголовок окна приходит через KVO чуть позже didFinish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            smokeReport("LOADED \(webView.url?.absoluteString ?? "-") title=\(window?.title ?? "")")
            NSApp.terminate(nil)
        }
    }
    #endif

    // MARK: - Загрузки

    fileprivate func attach(_ download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKNavigationDelegate

extension WebWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel, preferences) }

        if action.shouldPerformDownload {
            return decisionHandler(WebPolicy.allowsDownload(url: url, home: config.home) ? .download : .cancel, preferences)
        }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let userInitiated = action.navigationType == .linkActivated || action.navigationType == .formSubmitted
        switch WebPolicy.decide(url: url, home: config.home, isMainFrame: isMainFrame, userInitiated: userInitiated) {
        case .allow:
            decisionHandler(.allow, preferences)
        case .openExternal:
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel, preferences)
        case .block:
            decisionHandler(.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = response.response as? HTTPURLResponse
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !response.canShowMIMEType || disposition.hasPrefix("attachment") {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        attach(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        attach(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideError()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideError()
        #if CHAOS_WEB_DEBUG
        smokeAfterLoad()
        #endif
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, url: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, url: webView.url)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension WebWindowController: WKUIDelegate {
    /// target=_blank и window.open: свой origin открываем в этом же окне, внешние http(s) — в браузере.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        switch WebPolicy.decide(url: url, home: config.home, isMainFrame: true, userInitiated: true) {
        case .allow: webView.load(action.request)
        case .openExternal: NSWorkspace.shared.open(url)
        case .block: break
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// <input type="file">: например, импорт в веб-интерфейсе.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}

// MARK: - WKDownloadDelegate

extension WebWindowController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = WebPolicy.sanitizedFilename(suggestedFilename)
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let url = panel.url else { return completionHandler(nil) }
            // NSSavePanel уже спросил о замене; WKDownload требует, чтобы файла не было.
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            self?.downloadDestinations[ObjectIdentifier(download)] = url
            completionHandler(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        let allowed = request.url.map { WebPolicy.isSameOrigin($0, as: config.home) } ?? false
        decisionHandler(allowed ? .allow : .cancel)
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let dest = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        let alert = NSAlert()
        alert.messageText = "Не удалось сохранить файл"
        alert.informativeText = [dest?.lastPathComponent, ns.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        present(alert) { _ in }
    }
}

// MARK: - Экран недоступности

final class ErrorOverlayView: NSView {
    var onRetry: (() -> Void)?
    var message: String {
        get { detail.stringValue }
        set { detail.stringValue = newValue }
    }
    private let detail = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Сайт недоступен")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        detail.alignment = .center
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 420
        let hint = NSTextField(labelWithString: "Проверьте подключение к интернету и повторите.")
        hint.textColor = .secondaryLabelColor
        let button = NSButton(title: "Повторить", target: self, action: #selector(retryTapped))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, detail, hint, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // Клики не должны проходить к веб-странице под экраном ошибки.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : (super.hitTest(point) ?? self)
    }

    @objc private func retryTapped() { onRetry?() }
}

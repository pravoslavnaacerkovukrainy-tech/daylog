import Foundation

/// Чистая логика навигации без WebKit: что открывать в окне, что отдать системному браузеру,
/// что заблокировать. Вынесена отдельно, чтобы самопроверка шла без UI.
enum WebPolicy {
    /// Рабочий сайт. В release-сборке другого адреса нет.
    static let productionURL = URL(string: "https://day.osintradar.net/")!

    enum Decision: Equatable {
        case allow          // грузить в окне приложения
        case openExternal   // отдать системному браузеру
        case block          // отменить без действий
    }

    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    /// Тот же scheme+host+port, что и у стартового адреса.
    static func isSameOrigin(_ url: URL, as home: URL) -> Bool {
        guard let a = Origin(url), let b = Origin(home) else { return false }
        return a == b
    }

    /// `blob:https://host/uuid`: такой URL создаёт страница нашего origin, например при экспорте.
    static func isOwnBlob(_ url: URL, home: URL) -> Bool {
        guard url.scheme?.lowercased() == "blob" else { return false }
        let inner = String(url.absoluteString.dropFirst("blob:".count))
        guard let innerURL = URL(string: inner) else { return false }
        return isSameOrigin(innerURL, as: home)
    }

    /// Решение по навигации.
    /// - isMainFrame: навигация верхнего окна (а не iframe).
    /// - userInitiated: переход по ссылке, отправка формы или window.open/target=_blank.
    ///   Перенаправления и скрипты внешний браузер сами не открывают.
    static func decide(url: URL, home: URL, isMainFrame: Bool, userInitiated: Bool) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        if isSameOrigin(url, as: home) { return .allow }
        if isOwnBlob(url, home: home) { return .allow }
        if scheme == "about" {
            // about:blank/about:srcdoc нужны служебным iframe страницы, а не верхнему окну.
            let s = url.absoluteString.lowercased()
            return (!isMainFrame && (s == "about:blank" || s == "about:srcdoc")) ? .allow : .block
        }
        if scheme == "http" || scheme == "https" {
            return (isMainFrame && userInitiated) ? .openExternal : .block
        }
        return .block   // file:, javascript:, mailto:, data:, свои схемы и прочее
    }

    /// Для data: URL с атрибутом download разрешена только загрузка, не отображение.
    static func allowsDownload(url: URL, home: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return isSameOrigin(url, as: home) || isOwnBlob(url, home: home) || scheme == "data"
    }

    /// Безопасное имя для диалога сохранения: только последний компонент пути, без управляющих символов.
    static func sanitizedFilename(_ suggested: String?) -> String {
        let raw = (suggested ?? "").replacingOccurrences(of: "\\", with: "/")
        let last = raw.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":"
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "download" }
        return cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
    }

    #if CHAOS_WEB_DEBUG
    /// Только debug-сборка: адрес на loopback (127.0.0.1, ::1, localhost) для локальной проверки.
    static func debugLoopbackURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let o = Origin(url) else { return nil }
        let loopback: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]
        return loopback.contains(o.host) ? url : nil
    }
    #endif
}

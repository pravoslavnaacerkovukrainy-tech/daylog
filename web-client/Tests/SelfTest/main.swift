import Foundation

// Самопроверка WebPolicy без сети и UI.
var failures = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("  ok  \(name)") } else { failures += 1; print("  FAIL \(name) (строка \(line))") }
}
func u(_ s: String) -> URL { URL(string: s)! }

let home = WebPolicy.productionURL
func d(_ s: String, main: Bool = true, user: Bool = true) -> WebPolicy.Decision {
    WebPolicy.decide(url: u(s), home: home, isMainFrame: main, userInitiated: user)
}

print("→ Origin")
check(home.absoluteString == "https://day.osintradar.net/", "рабочий адрес")
check(WebPolicy.isSameOrigin(u("https://day.osintradar.net/login?x=1"), as: home), "путь и запрос того же origin")
check(WebPolicy.isSameOrigin(u("https://DAY.osintradar.net:443/"), as: home), "регистр хоста и явный порт 443")
check(!WebPolicy.isSameOrigin(u("http://day.osintradar.net/"), as: home), "http не равен https")
check(!WebPolicy.isSameOrigin(u("https://day.osintradar.net:8443/"), as: home), "другой порт")
check(!WebPolicy.isSameOrigin(u("https://evil.day.osintradar.net/"), as: home), "поддомен")
check(!WebPolicy.isSameOrigin(u("https://day.osintradar.net.evil.com/"), as: home), "суффикс-подделка")
check(!WebPolicy.isSameOrigin(u("https://osintradar.net/"), as: home), "родительский домен")

print("→ Решения навигации")
check(d("https://day.osintradar.net/app") == .allow, "свой origin")
check(d("https://day.osintradar.net/app", main: false, user: false) == .allow, "свой origin в iframe")
check(d("https://example.com/") == .openExternal, "внешний https по клику — браузер")
check(d("http://example.com/") == .openExternal, "внешний http по клику — браузер")
check(d("https://example.com/", user: false) == .block, "внешний редирект/скрипт — блок")
check(d("https://example.com/", main: false) == .block, "внешний iframe — блок")
check(d("http://day.osintradar.net/") == .openExternal, "понижение до http не грузится в окне")
for s in ["file:///etc/passwd", "javascript:alert(1)", "mailto:a@b.c", "tel:123",
          "data:text/html,hi", "ftp://example.com/", "chaosday://x", "about:blank"] {
    check(d(s) == .block, "блок \(s)")
}
check(d("about:blank", main: false) == .allow, "about:blank в служебном iframe")
check(d("blob:https://day.osintradar.net/1234-5678") == .allow, "свой blob")
check(d("blob:https://example.com/1234") == .block, "чужой blob")

print("→ Загрузки")
check(WebPolicy.allowsDownload(url: u("https://day.osintradar.net/export.zip"), home: home), "свой файл")
check(WebPolicy.allowsDownload(url: u("blob:https://day.osintradar.net/abc"), home: home), "свой blob")
check(WebPolicy.allowsDownload(url: u("data:text/plain,hi"), home: home), "data: с атрибутом download")
check(!WebPolicy.allowsDownload(url: u("https://example.com/x.zip"), home: home), "чужой файл")
check(!WebPolicy.allowsDownload(url: u("file:///etc/hosts"), home: home), "file:")

print("→ Имя файла")
check(WebPolicy.sanitizedFilename("Хаос-экспорт.json") == "Хаос-экспорт.json", "кириллица сохраняется")
check(WebPolicy.sanitizedFilename("../../.ssh/id") == "id", "путь отбрасывается")
check(WebPolicy.sanitizedFilename("a\\b\\c.txt") == "c.txt", "обратные слеши")
check(WebPolicy.sanitizedFilename(".zshrc") == "_zshrc", "скрытый файл")
check(WebPolicy.sanitizedFilename("x\u{0}y\n.txt") == "xy.txt", "управляющие символы")
check(WebPolicy.sanitizedFilename("") == "download", "пустое имя")
check(WebPolicy.sanitizedFilename(nil) == "download", "нет имени")
check(WebPolicy.sanitizedFilename("..") == "download", "..")

#if CHAOS_WEB_DEBUG
print("→ Debug loopback")
check(WebPolicy.debugLoopbackURL("http://127.0.0.1:8123/") != nil, "127.0.0.1")
check(WebPolicy.debugLoopbackURL("http://localhost:8123/") != nil, "localhost")
check(WebPolicy.debugLoopbackURL("http://[::1]:8123/") != nil, "::1")
check(WebPolicy.debugLoopbackURL("https://day.osintradar.net/") == nil, "не loopback")
check(WebPolicy.debugLoopbackURL("http://127.0.0.1.evil.com/") == nil, "подделка loopback")
check(WebPolicy.debugLoopbackURL("file:///tmp/x.html") == nil, "file:")
#endif

print(failures == 0 ? "Все проверки пройдены" : "Провалено: \(failures)")
exit(failures == 0 ? 0 : 1)

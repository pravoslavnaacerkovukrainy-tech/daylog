import AppKit

/// Параметры запуска. В release всегда рабочий сайт и постоянный профиль приложения.
struct LaunchConfig {
    var home: URL = WebPolicy.productionURL
    var persistentProfile = true
    var smokeTest = false   // только debug: загрузить страницу, вывести итог и выйти

    static func fromArguments(_ args: [String]) -> LaunchConfig {
        var config = LaunchConfig()
        #if CHAOS_WEB_DEBUG
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--debug-url" where i + 1 < args.count:
                guard let url = WebPolicy.debugLoopbackURL(args[i + 1]) else {
                    FileHandle.standardError.write("--debug-url принимает только loopback-адрес\n".data(using: .utf8)!)
                    exit(64)
                }
                config.home = url
                config.persistentProfile = false   // локальная проверка не трогает профиль приложения
                i += 1
            case "--smoke":
                config.smokeTest = true
            default:
                break
            }
            i += 1
        }
        #endif
        return config
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(config: LaunchConfig.fromArguments(CommandLine.arguments))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

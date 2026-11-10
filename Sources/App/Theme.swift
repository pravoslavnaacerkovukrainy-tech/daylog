import SwiftUI
import AppKit

// MARK: - Theme (токены, см. DESIGN.md)

enum Theme {
    /// Лист ленты дня.
    static let canvas = Color(nsColor: .textBackgroundColor)
    /// Панели и хром.
    static let pane = Color(nsColor: .windowBackgroundColor)
    static let ink = dynamic(0x263747, dark: .labelColor)
    static let quiet = dynamic(0x5E6B78, dark: .secondaryLabelColor)
    static let accent = dynamic(0x2F6690, dark: NSColor(srgbRed: 0.525, green: 0.714, blue: 0.878, alpha: 1))
    static let rail = dynamic(0xDCE5EC, dark: .separatorColor)
    static let field = dynamic(0xF5F8FA, dark: .controlBackgroundColor)
    /// Только «Обещание под угрозой», «Не может ждать» и группа «Под угрозой».
    /// Не для ошибок (они остаются системным красным) и не для украшений.
    static let signal = dynamic(0xA35A00, dark: srgb(0xE0A04A))

    static func dynamic(_ hex: UInt32, dark: NSColor) -> Color {
        let light = srgb(hex)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// Время: главный визуальный ориентир. SF Rounded, полужирный, цифры одной ширины.
    static let timeFont = Font.system(.body, design: .rounded).weight(.semibold).monospacedDigit()
}

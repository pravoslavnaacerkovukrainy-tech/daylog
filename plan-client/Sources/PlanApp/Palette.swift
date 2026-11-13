import SwiftUI

/// Две схемы поверх одной композиции. Тёмная по умолчанию; выбор хранится в ui.json каталога данных.
enum ThemeChoice: String, Codable, CaseIterable, Identifiable {
    case dark, light
    var id: String { rawValue }
    var title: String { self == .dark ? "Тёмная" : "Светлая" }
    var scheme: ColorScheme { self == .dark ? .dark : .light }
}

struct Palette {
    let canvas: Color      // фон редактора
    let panel: Color       // боковая колонка и список
    let raised: Color      // выбранная строка, поля ввода
    let line: Color        // разделители и рамки полей
    let text: Color
    let muted: Color
    let accent: Color      // выбор и основное действие
    let onAccent: Color
    let pending: Color     // сохранено на Mac, ждёт отправки
    let conflict: Color    // конфликт, отказ сервера
    let synced: Color      // подтверждено сервером

    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255, opacity: 1)
    }

    static let dark = Palette(
        canvas: hex(0x15181E), panel: hex(0x1B1F27), raised: hex(0x262C38), line: hex(0x343B49),
        text: hex(0xE4E7EC), muted: hex(0x939CAB), accent: hex(0x79AEDB), onAccent: hex(0x0E1A26),
        pending: hex(0xD9A85B), conflict: hex(0xE58A78), synced: hex(0x7DB89A))

    static let light = Palette(
        canvas: hex(0xF5F7FA), panel: hex(0xE8ECF1), raised: hex(0xFFFFFF), line: hex(0xC9D1DC),
        text: hex(0x18202D), muted: hex(0x556173), accent: hex(0x2F6690), onAccent: hex(0xFFFFFF),
        pending: hex(0x8F5E0A), conflict: hex(0xAE3F2B), synced: hex(0x2A6E4C))

    static func of(_ t: ThemeChoice) -> Palette { t == .dark ? .dark : .light }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.dark }

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Поле ввода в общей манере: заливка raised, рамка line, акцентная рамка в фокусе.
struct FieldChrome: ViewModifier {
    @Environment(\.palette) private var p
    var focused: Bool
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? p.accent : p.line, lineWidth: focused ? 1.5 : 1))
    }
}

extension View {
    func fieldChrome(focused: Bool = false) -> some View { modifier(FieldChrome(focused: focused)) }
}

/// Основная и обычная кнопки. Видимое состояние фокуса даёт система.
struct PlanButtonStyle: ButtonStyle {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(primary ? p.onAccent : p.text)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? p.accent : p.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? Color.clear : p.line))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

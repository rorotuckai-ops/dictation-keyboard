import SwiftUI
import UIKit

/// The v2 palette: cool paper, ink-blue accent for the active state and one primary action.
enum Palette {
    static let background = color(0xF4F4F1, 0x13161B)
    static let surface = color(0xFFFFFF, 0x1E232B)
    static let text = color(0x171A1F, 0xF2F4F8)
    static let secondary = color(0x626873, 0xA4ADB9)
    static let separator = color(0xDDDFE2, 0x353E4B)
    static let keyboard = color(0xE8EBEF, 0x272E38)
    static let insertion = color(0xE5E8EC, 0x343D49)
    static let accent = color(0x2457C5, 0x8CAEFF)
    static let onAccent = color(0xFFFFFF, 0x14213D)
    static let destructive = color(0xBD2839, 0xFF9AA7)

    private static func color(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static let paper = Color(Palette.background)
    static let surface = Color(Palette.surface)
    static let ink = Color(Palette.text)
    static let inkSecondary = Color(Palette.secondary)
    static let rule = Color(Palette.separator)
    static let insertion = Color(Palette.insertion)
    static let accentInk = Color(Palette.accent)
    static let onAccent = Color(Palette.onAccent)
    static let destructiveInk = Color(Palette.destructive)
}

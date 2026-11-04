import AppKit
import SwiftUI

extension Color {
    static let louderBlue = Color(nsColor: .adaptive(light: 0x2F6BFF, dark: 0x5B8CFF))
    static let louderCoral = Color(nsColor: .adaptive(light: 0xFF7A59, dark: 0xFFA58A))
}

private extension NSColor {
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

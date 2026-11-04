import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let isOn: Bool

    var body: some View {
        Image(nsImage: isOn ? MenuBarIcon.on : MenuBarIcon.off)
            .accessibilityLabel(isOn ? "Louder, on" : "Louder, off")
    }
}

@MainActor
enum MenuBarIcon {
    static let on: NSImage = {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Louder")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()

    static let off = dimmed(on, alpha: 0.35)

    nonisolated private static func dimmed(_ base: NSImage, alpha: CGFloat) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        image.isTemplate = true
        return image
    }
}

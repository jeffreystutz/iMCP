import SwiftUI

/// Renders the menu-bar status item glyph for each `MenuBarIconAppearance`.
///
/// `.serverDisabled` and `.askBeforeSending` render the existing `MenuIcon-Off`
/// and `MenuIcon-On` assets exactly as before. `.automaticSendingActive` keeps
/// the same template `MenuIcon-On` glyph — so it still receives macOS's normal
/// light/dark/highlight treatment — and overlays a small, non-template
/// amber/orange accent dot. The base glyph is never tinted and the menu-bar
/// item background is never customized.
struct MenuBarIconView: View {
    let appearance: MenuBarIconAppearance

    private var accessibilityLabel: String {
        switch appearance {
        case .serverDisabled, .askBeforeSending:
            "iMCP"
        case .automaticSendingActive:
            "iMCP — Automatic sending is on"
        }
    }

    var body: some View {
        Group {
            switch appearance {
            case .serverDisabled:
                Image("MenuIcon-Off")
            case .askBeforeSending:
                Image("MenuIcon-On")
            case .automaticSendingActive:
                Image("MenuIcon-On")
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                    }
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

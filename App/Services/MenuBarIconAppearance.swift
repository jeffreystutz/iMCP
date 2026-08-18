import Foundation

/// The menu-bar status item's glyph state, derived from exactly two existing,
/// already-persisted app facts: whether the MCP server is enabled and the
/// global `MessagesSendingMode`.
///
/// This does not introduce a second state machine or persisted value. It is a
/// pure read-only projection of `isEnabled` and `MessagesSendingMode`, used to
/// keep the menu-bar icon and the in-menu automatic-sending status surface in
/// exact agreement about when automatic sending is operationally visible.
///
/// Server-disabled takes precedence over the persisted Sending mode: the
/// automatic indicator never appears while the server is disabled, even
/// though the underlying mode value is untouched and will resume being
/// visible the moment the server is re-enabled.
enum MenuBarIconAppearance: Equatable {
    case serverDisabled
    case askBeforeSending
    case automaticSendingActive

    static func resolve(
        isServerEnabled: Bool,
        sendingMode: MessagesSendingMode
    ) -> MenuBarIconAppearance {
        guard isServerEnabled else { return .serverDisabled }

        switch sendingMode {
        case .askBeforeSending: return .askBeforeSending
        case .sendAutomatically: return .automaticSendingActive
        }
    }

    /// Whether automatic sending should currently be presented as
    /// operationally active — the single condition that gates both the
    /// menu-bar amber accent and the in-menu status/Pause surface.
    var isAutomaticSendingActive: Bool {
        self == .automaticSendingActive
    }
}

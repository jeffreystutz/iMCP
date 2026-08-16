import Foundation

/// The application-owned, global Messages sending mode.
///
/// `.askBeforeSending` (factory default) requires the existing per-send
/// confirmation, presented per `MessagesSendConfirmationMode`. `.sendAutomatically`
/// is an explicit user opt-in that applies equally to every connected MCP client,
/// for every eligible existing-conversation programmatic send; it does not apply
/// to a new recipient, which remains a human-completed `NSSharingService`
/// Messages compose flow regardless of this mode.
///
/// The mode is global: there is no per-client variant, and no distinction by
/// conversation kind (direct/group) or payload kind (text/attachment) — an
/// earlier four-category design was implemented, code-reviewed, and then
/// rejected at manual Settings acceptance for being more control surface than
/// the product needs. This binary mode is the settled replacement.
///
/// No MCP tool argument, prompt, or elicitation response can change this value.
/// Only Settings-owned code in `GeneralSettingsView` reads and writes it.
enum MessagesSendingMode: String, CaseIterable, Identifiable, Sendable {
    case askBeforeSending
    case sendAutomatically

    static let storageKey = "me.mattt.iMCP.messagesSendingMode"
    static let defaultValue = MessagesSendingMode.askBeforeSending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askBeforeSending: "Ask Before Sending"
        case .sendAutomatically: "Send Automatically"
        }
    }

    /// Decodes a stored value, falling back to Ask Before Sending for anything
    /// absent, empty, or no longer recognized — a stale or corrupt value must
    /// never be guessed at, and must never fail open toward automatic sending.
    ///
    /// This type intentionally reads only its own storage key. An earlier,
    /// never-manually-accepted four-category policy persisted under a
    /// different key (`me.mattt.iMCP.messagesAutomaticSendPolicy`); that key is
    /// simply never consulted here, so any categories a developer enabled while
    /// testing that rejected design cannot accidentally resolve to
    /// `.sendAutomatically` now.
    static func decode(_ storedValue: String?) -> MessagesSendingMode {
        storedValue.flatMap(MessagesSendingMode.init(rawValue:)) ?? defaultValue
    }

    static func load(from defaults: UserDefaults = .standard) -> MessagesSendingMode {
        decode(defaults.string(forKey: storageKey))
    }
}

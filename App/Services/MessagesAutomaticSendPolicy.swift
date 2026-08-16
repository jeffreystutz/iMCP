import Foundation

/// One global category of Messages send that iMCP may be allowed to submit without a
/// per-send confirmation.
///
/// A category names a conversation shape plus a payload shape, not a destination or a
/// transport. New-recipient sending has no category here: the current new-recipient path
/// is human-completed `NSSharingService` composition, which this policy does not apply to.
enum MessagesAutomaticSendCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case existingDirectConversationText
    case existingGroupConversationText
    case existingDirectConversationAttachment
    case existingGroupConversationAttachment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .existingDirectConversationText: "Direct conversations — text"
        case .existingGroupConversationText: "Group conversations — text"
        case .existingDirectConversationAttachment: "Direct conversations — attachments"
        case .existingGroupConversationAttachment: "Group conversations — attachments"
        }
    }
}

/// The application-owned, global Messages automatic-send authorization policy.
///
/// This answers "is a per-send confirmation required for this category of Messages
/// send," independent of `MessagesSendConfirmationMode`, which answers "how is that
/// confirmation presented when one is required." A category enabled here may skip
/// presentation entirely; every other invariant — destination resolution, ambiguity
/// failure, revalidation, Automation permission, cancellation before dispatch, privacy
/// redaction, one-dispatch/no-retry, and submitted-not-delivered semantics — is
/// unaffected by this policy and unaffected by this slice, which reads and writes this
/// policy but does not consult it from any send path.
///
/// The policy is global: it applies equally to every connected MCP client. There is no
/// per-client variant. Only Settings/app-owned code may mutate stored state; no MCP tool
/// argument, prompt, or elicitation response can change it, because no MCP tool reads or
/// writes this policy's storage key.
///
/// Every category defaults to confirmation-required. A category absent from storage —
/// including every category on first launch, and any category added to
/// `MessagesAutomaticSendCategory` after a policy value was last saved — is treated as
/// confirmation-required, never guessed to be automatic.
struct MessagesAutomaticSendPolicy: Equatable, Sendable {
    private var automaticCategories: Set<MessagesAutomaticSendCategory>

    static let storageKey = "me.mattt.iMCP.messagesAutomaticSendPolicy"

    static let confirmationRequiredForEverything = MessagesAutomaticSendPolicy(
        automaticCategories: []
    )
    static let defaultValue = confirmationRequiredForEverything

    private init(automaticCategories: Set<MessagesAutomaticSendCategory>) {
        self.automaticCategories = automaticCategories
    }

    func isAutomatic(_ category: MessagesAutomaticSendCategory) -> Bool {
        automaticCategories.contains(category)
    }

    /// True once at least one category no longer requires confirmation. Used to decide
    /// whether a change is the sensitive "off to on" transition that warrants a warning.
    var isAnyCategoryAutomatic: Bool {
        !automaticCategories.isEmpty
    }

    var isEveryCategoryAutomatic: Bool {
        automaticCategories.isSuperset(of: MessagesAutomaticSendCategory.allCases)
    }

    mutating func setAutomatic(_ automatic: Bool, for category: MessagesAutomaticSendCategory) {
        if automatic {
            automaticCategories.insert(category)
        } else {
            automaticCategories.remove(category)
        }
    }

    mutating func allowEverythingAutomatically() {
        automaticCategories = Set(MessagesAutomaticSendCategory.allCases)
    }

    mutating func requireConfirmationForEverything() {
        automaticCategories.removeAll()
    }
}

extension MessagesAutomaticSendPolicy {
    /// Decodes a stored value, falling back to confirmation-required for anything absent,
    /// empty, or no longer decodable — a stale or corrupt value must never be guessed at
    /// or crash, and must never fail open toward automatic sending.
    static func decode(_ storedValue: Data?) -> MessagesAutomaticSendPolicy {
        guard let storedValue, !storedValue.isEmpty else { return .defaultValue }
        guard
            let decoded = try? JSONDecoder().decode(
                Set<MessagesAutomaticSendCategory>.self,
                from: storedValue
            )
        else {
            return .defaultValue
        }
        return MessagesAutomaticSendPolicy(automaticCategories: decoded)
    }

    static func load(from defaults: UserDefaults = .standard) -> MessagesAutomaticSendPolicy {
        decode(defaults.data(forKey: storageKey))
    }

    /// Encodes only the categories currently exempt from confirmation. A category unknown
    /// to a future decoder is simply absent, which decodes safely to confirmation-required.
    func encoded() -> Data {
        (try? JSONEncoder().encode(automaticCategories)) ?? Data()
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(encoded(), forKey: Self.storageKey)
    }
}

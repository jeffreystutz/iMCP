import Foundation

/// Whether the repository could safely compare a supplied handle against the stored
/// participant identities it needed to examine.
///
/// This is a read-data-quality concept, not a send decision. It says nothing about which
/// conversation a later send should use, and it is deliberately unrelated to the internal
/// unique/none/ambiguous/incomplete states the send matcher uses.
enum MessagesLookupCompleteness: String, Encodable, Sendable {
    /// Every stored participant identity relevant to this handle was exactly comparable.
    /// An empty conversation list alongside `complete` means no conversation matched.
    case complete
    /// At least one stored participant identity could plausibly denote this handle but
    /// could not be interpreted exactly under supported normalization rules. Returned
    /// conversations are still exact matches, but others may be missing, so an empty list
    /// alongside `incomplete` is never verified absence.
    case incomplete
}

/// One conversation as conversation-discovery evidence.
///
/// This is deliberately smaller than the `messages_list_chats` record: it carries what an
/// LLM needs to understand who a conversation is with, and no database identifier, message
/// content, attachment path, or history aggregate.
struct MessagesConversationSummary: Encodable, Equatable, Sendable {
    let chatId: String
    let kind: MessagesChatKind
    let displayName: String?
    let participants: [MessagesParticipant]
    let service: String?
    let latestActivity: Date?

    private enum CodingKeys: String, CodingKey {
        case chatId
        case kind
        case displayName
        case participants
        case service
        case latestActivity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chatId, forKey: .chatId)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(participants, forKey: .participants)
        try container.encode(service, forKey: .service)
        try container.encode(latestActivity?.formatted(.iso8601), forKey: .latestActivity)
    }
}

/// Everything found for one supplied handle.
///
/// `truncated` and `lookupCompleteness` answer different questions. `truncated` reports
/// that more safely matched conversations existed than the requested per-handle limit
/// returned. `lookupCompleteness` reports whether the comparison itself was exact.
struct MessagesHandleConversations: Encodable, Equatable, Sendable {
    let handle: String
    let lookupCompleteness: MessagesLookupCompleteness
    let truncated: Bool
    let conversations: [MessagesConversationSummary]
}

struct MessagesConversationSearchResult: Encodable, Equatable, Sendable {
    var metadataAvailability: [String: Bool]
    var results: [MessagesHandleConversations]
}

/// Conversation discovery, separated from the MCP interface that exposes it.
///
/// The operation answers only "which conversations are associated with each of these exact
/// identities". It never ranks people, selects a destination, chooses a contact method, or
/// prepares a send, and it never consults Contacts.
protocol MessagesConversationSearching: Sendable {
    /// Finds conversations for already-normalized exact handles.
    ///
    /// Callers validate and normalize every handle first; the operation performs no country
    /// inference and rewrites nothing. Results preserve the supplied order, including
    /// duplicates.
    func findConversations(
        handles: [String],
        limitPerHandle: Int,
        databasePath: String
    ) throws -> MessagesConversationSearchResult
}

/// Conversation discovery including the Messages service's own read-only database access.
///
/// `MessagesConversationSearching` searches a database path its caller already resolved.
/// This is the complete lookup, and it is what a cross-service reader depends on: it
/// resolves the directory-scoped bookmark exactly as the Messages tools do and then runs
/// that same search, so no second reader ever opens the Messages database its own way or
/// acquires access the Messages service would not have acquired itself.
protocol MessagesConversationLookup {
    func findConversations(
        handles: [String],
        limitPerHandle: Int
    ) async throws -> MessagesConversationSearchResult
}

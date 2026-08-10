import Foundation
import Ontology

/// One contact together with the Messages conversations its own exact identities appear in.
///
/// The contact is the unchanged `contacts_search` record and each identity entry is the
/// unchanged `messages_find_conversations` fact set for that handle. Nothing is added on
/// top: there is no rank, score, confidence, recommended person, chosen contact method,
/// chosen conversation, destination, or transport.
struct ContactConversations: Encodable, Equatable, Sendable {
    let contact: ContactRecord
    let identities: [MessagesHandleConversations]
}

/// One contact search and one conversation search, joined.
struct ContactConversationSearchResult: Encodable, Equatable, Sendable {
    /// The conversation search's own availability dictionary, or `null` when no contact
    /// published an exact identity and Messages was therefore never consulted.
    ///
    /// `null` says that no lookup ran. It never says that a lookup found nothing.
    let metadataAvailability: [String: Bool]?
    let results: [ContactConversations]

    private enum CodingKeys: String, CodingKey {
        case metadataAvailability
        case results
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Encoded explicitly so a lookup that never ran is a visible null rather than an
        // absent key a reader could mistake for an older tool version.
        try container.encode(metadataAvailability, forKey: .metadataAvailability)
        try container.encode(results, forKey: .results)
    }
}

/// Non-private facts about one completed composite lookup.
///
/// Counts are the only diagnosable values. A name, a stored contact value, a handle, a
/// chat identifier, a conversation name, or a result object must never reach a log.
struct ContactConversationSearchTelemetry: Equatable, Sendable {
    let contacts: Int
    let identities: Int
    let conversations: Int
    /// Whether the Messages conversation search ran at all.
    let searchedMessages: Bool
}

enum ContactConversationSearchError: LocalizedError, Equatable, Sendable {
    /// The conversation search returned no result for an identity it was asked about.
    case missingIdentityResult

    var errorDescription: String? {
        switch self {
        case .missingIdentityResult:
            return
                "The Messages conversation search did not answer for every requested contact identity."
        }
    }
}

/// The literal read-only composition behind `contacts_find_conversations`.
///
/// It calls the same two reusable operations the primitive tools call — contact search
/// once, then conversation search once — and joins their outputs mechanically. The result
/// is deliberately reproducible: calling `contacts_search` and `messages_find_conversations`
/// separately and joining them outside the server yields the same facts. This adds
/// packaging, not interpretation, and it never invokes an MCP tool.
struct ContactConversationSearch {
    private let contactSearch: any ContactSearching
    private let conversationLookup: any MessagesConversationLookup

    init(
        contactSearch: any ContactSearching,
        conversationLookup: any MessagesConversationLookup
    ) {
        self.contactSearch = contactSearch
        self.conversationLookup = conversationLookup
    }

    /// The exact Messages identities one contact publishes, phone values before email
    /// values, each in the order the contact record carries it.
    ///
    /// Only the public `ContactRecord` fields are read, so this can never see richer
    /// contact data than `contacts_search` returns: no `CNContact`, no parser state, no
    /// region setting, no label beyond what `phoneNumbers` already carries. Phone identity
    /// comes only from each entry's already-normalized `e164`, never from `person.telephone`
    /// directly — normalizing a local number is a Contacts-side concern this composite does
    /// not repeat. A phone value with no `e164` contributes nothing; a malformed email is
    /// dropped rather than repaired. Repeats collapse to their first occurrence.
    static func identities(of contact: ContactRecord) -> [String] {
        var identities: [String] = []
        var seen: Set<String> = []
        let phoneValues = contact.phoneNumbers.compactMap(\.e164)
        for value in phoneValues + (contact.person.email ?? []) {
            guard let identity = MessagesHandleNormalization.normalize(value) else { continue }
            if seen.insert(identity).inserted { identities.append(identity) }
        }
        return identities
    }

    func search(
        _ query: ContactSearchQuery,
        limitPerIdentity: Int
    ) async throws -> ContactConversationSearchResult {
        let contacts = try await contactSearch.search(query)
        let identitiesByContact = contacts.map(Self.identities(of:))

        // One lookup covers every contact, so an identity two contacts share is searched
        // once and still reported under both of them.
        var handles: [String] = []
        var seen: Set<String> = []
        for identities in identitiesByContact {
            for identity in identities where seen.insert(identity).inserted {
                handles.append(identity)
            }
        }

        guard !handles.isEmpty else {
            // With nothing exact to look up there is no conversation question to ask.
            // Opening Messages anyway, only to report which metadata it could have
            // supplied, would describe a lookup that never happened.
            return ContactConversationSearchResult(
                metadataAvailability: nil,
                results: contacts.map { ContactConversations(contact: $0, identities: []) }
            )
        }

        let found = try await conversationLookup.findConversations(
            handles: handles,
            limitPerHandle: limitPerIdentity
        )

        var conversationsByHandle: [String: MessagesHandleConversations] = [:]
        conversationsByHandle.reserveCapacity(found.results.count)
        for result in found.results { conversationsByHandle[result.handle] = result }

        return ContactConversationSearchResult(
            metadataAvailability: found.metadataAvailability,
            results: try contacts.indices.map { index in
                ContactConversations(
                    contact: contacts[index],
                    identities: try identitiesByContact[index].map { identity in
                        // Evidence that was never returned stays missing. Substituting an
                        // empty conversation list here would read as verified absence.
                        guard let conversations = conversationsByHandle[identity] else {
                            throw ContactConversationSearchError.missingIdentityResult
                        }
                        return conversations
                    }
                )
            }
        )
    }
}

extension ContactConversationSearchResult {
    /// The non-private counts describing this result.
    var telemetry: ContactConversationSearchTelemetry {
        ContactConversationSearchTelemetry(
            contacts: results.count,
            identities: results.reduce(0) { $0 + $1.identities.count },
            conversations: results.reduce(0) {
                $0 + $1.identities.reduce(0) { $0 + $1.conversations.count }
            },
            searchedMessages: metadataAvailability != nil
        )
    }
}

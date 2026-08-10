import Contacts
import Foundation
import JSONSchema
import OSLog
import Ontology
import OrderedCollections

private let log = Logger.service("contacts")

private let contactKeys =
    [
        CNContactTypeKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactBirthdayKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactInstantMessageAddressesKey,
        CNContactSocialProfilesKey,
        CNContactUrlAddressesKey,
        CNContactPostalAddressesKey,
        CNContactRelationsKey,
    ] as [CNKeyDescriptor]

private let contactProperties: OrderedDictionary<String, JSONSchema> = [
    "givenName": .string(),
    "familyName": .string(),
    "organizationName": .string(),
    "jobTitle": .string(),
    "phoneNumbers": .object(
        properties: [
            "mobile": .string(),
            "work": .string(),
            "home": .string(),
        ],
        additionalProperties: true
    ),
    "emailAddresses": .object(
        properties: [
            "work": .string(),
            "home": .string(),
        ],
        additionalProperties: true
    ),
    "postalAddresses": .object(
        properties: [
            "work": .object(
                properties: [
                    "street": .string(),
                    "city": .string(),
                    "state": .string(),
                    "postalCode": .string(),
                    "country": .string(),
                ]
            ),
            "home": .object(
                properties: [
                    "street": .string(),
                    "city": .string(),
                    "state": .string(),
                    "postalCode": .string(),
                    "country": .string(),
                ]
            ),
        ],
        additionalProperties: true
    ),
    "birthday": .object(
        properties: [
            "day": .integer(minimum: 1, maximum: 31),
            "month": .integer(minimum: 1, maximum: 12),
            "year": .integer(),
        ],
        required: ["day", "month"]
    ),
]

/// One contact-discovery request, expressed in the same terms as the public
/// `contacts_search` tool input.
///
/// Each field carries the value exactly as supplied. Normalization belongs to the search
/// operation so every caller — the MCP adapter today, a cross-service reader later —
/// resolves the same criteria to the same contacts.
struct ContactSearchQuery: Equatable, Sendable {
    var name: String?
    var phone: String?
    var email: String?

    init(name: String? = nil, phone: String? = nil, email: String? = nil) {
        self.name = name
        self.phone = phone
        self.email = email
    }
}

enum ContactSearchError: LocalizedError, Equatable, Sendable {
    case noSearchCriteria

    var errorDescription: String? {
        switch self {
        case .noSearchCriteria: "At least one valid search parameter is required"
        }
    }
}

/// Contact discovery, separated from the MCP interface that exposes it.
///
/// The operation answers only "which contacts match these criteria". It does not decide
/// which person the caller meant, and it exposes exactly the facts the public
/// `contacts_search` tool returns, so a later composite reader cannot reason from richer
/// hidden contact data than a client could obtain by calling that tool itself.
protocol ContactSearching: Sendable {
    func search(_ query: ContactSearchQuery) async throws -> [Person]
}

/// Production contact search backed by the user's Contacts database.
///
/// `CNContactStore` is documented as thread-safe, and this type adds no mutable state of
/// its own, so the unchecked conformance describes an invariant the framework already
/// provides.
struct CNContactStoreSearch: ContactSearching, @unchecked Sendable {
    private let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    /// Builds the predicate for a query, or reports that no usable criterion was supplied.
    ///
    /// Several criteria combine with AND. A name or email that is empty once trimmed
    /// contributes no criterion, so supplying only such a value is the same as supplying
    /// nothing. A phone number is passed to Contacts as given.
    static func predicate(for query: ContactSearchQuery) throws -> NSPredicate {
        var predicates: [NSPredicate] = []

        if let name = query.name {
            let normalizedName = name.trimmingCharacters(in: .whitespaces)
            if !normalizedName.isEmpty {
                predicates.append(CNContact.predicateForContacts(matchingName: normalizedName))
            }
        }

        if let phone = query.phone {
            let phoneNumber = CNPhoneNumber(stringValue: phone)
            predicates.append(CNContact.predicateForContacts(matching: phoneNumber))
        }

        if let email = query.email {
            // Normalize email to lowercase
            let normalizedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
            if !normalizedEmail.isEmpty {
                predicates.append(
                    CNContact.predicateForContacts(matchingEmailAddress: normalizedEmail)
                )
            }
        }

        guard !predicates.isEmpty else { throw ContactSearchError.noSearchCriteria }

        // Combine predicates with AND if multiple criteria are provided
        return predicates.count == 1
            ? predicates[0]
            : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    func search(_ query: ContactSearchQuery) async throws -> [Person] {
        let predicate = try Self.predicate(for: query)
        let store = self.store
        let contacts = try await Task(priority: .utility) {
            try store.unifiedContacts(matching: predicate, keysToFetch: contactKeys)
        }.value
        return contacts.compactMap { Person($0) }
    }
}

final class ContactsService: Service {
    private let contactStore = CNContactStore()
    private let contactSearch: any ContactSearching
    private let conversationLookup: any MessagesConversationLookup
    private let conversationSearchLog: @Sendable (ContactConversationSearchTelemetry) -> Void

    static let shared = ContactsService()

    init(
        contactSearch: any ContactSearching = CNContactStoreSearch(),
        conversationLookup: any MessagesConversationLookup = MessageService.shared,
        conversationSearchLog: @escaping @Sendable (ContactConversationSearchTelemetry) -> Void = {
            facts in
            log.notice(
                "Joined contact conversations contacts=\(facts.contacts, privacy: .public) identities=\(facts.identities, privacy: .public) conversations=\(facts.conversations, privacy: .public) searchedMessages=\(facts.searchedMessages, privacy: .public)"
            )
        }
    ) {
        self.contactSearch = contactSearch
        self.conversationLookup = conversationLookup
        self.conversationSearchLog = conversationSearchLog
    }

    private func runContactStore<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await Task(priority: .utility) {
            try operation()
        }.value
    }

    var isActivated: Bool {
        get async {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            return status == .authorized
        }
    }

    func activate() async throws {
        log.debug("Activating contacts service")
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            log.debug("Contacts access authorized")
            return
        case .denied:
            log.error("Contacts access denied")
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access denied"]
            )
        case .restricted:
            log.error("Contacts access restricted")
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access restricted"]
            )
        case .notDetermined:
            log.debug("Requesting contacts access")
            _ = try await contactStore.requestAccess(for: .contacts)
        @unknown default:
            log.error("Unknown contacts authorization status")
            throw NSError(
                domain: "ContactsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown contacts authorization status"]
            )
        }
    }

    var tools: [Tool] {
        Tool(
            name: "contacts_me",
            description:
                "Get contact information about the user, including name, phone number, email, birthday, relations, address, online presence, and occupation. Always run this tool when the user asks a question that requires personal information about themselves.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Who Am I?",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let contact = try await self.runContactStore {
                try self.contactStore.unifiedMeContactWithKeys(toFetch: contactKeys)
            }
            return Person(contact)
        }

        Tool(
            name: "contacts_search",
            description:
                "Search contacts by name, phone number, and/or email",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name to search for"
                    ),
                    "phone": .string(
                        description: "Phone number to search for"
                    ),
                    "email": .string(
                        description: "Email address to search for"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Contacts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var query = ContactSearchQuery()
            if case let .string(name) = arguments["name"] { query.name = name }
            if case let .string(phone) = arguments["phone"] { query.phone = phone }
            if case let .string(email) = arguments["email"] { query.email = email }
            return try await self.contactSearch.search(query)
        }

        Tool(
            name: "contacts_find_conversations",
            description:
                "Search contacts and return, for each matching contact, the existing Messages conversations that contact's own exact phone and email identities appear in. This is exactly contacts_search followed by one messages_find_conversations call over the identities those contacts already publish, joined mechanically, so it returns the same facts you would get by calling both tools yourself. It selects no person, ranks nobody, scores nothing, chooses no contact method, conversation, or destination, and sends nothing. A stored contact value that is not already a strict E.164 phone number or a valid email address is skipped rather than rewritten, no country code is ever inferred, and a contact whose values are all unusable comes back with an empty identities list. Read each identity's lookupCompleteness before concluding it has no conversations. A null metadataAvailability means no contact had an exact identity, so Messages was never consulted; it never means a lookup came back empty. Requires both the Contacts and Messages services to be enabled.",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name to search for"
                    ),
                    "phone": .string(
                        description: "Phone number to search for"
                    ),
                    "email": .string(
                        description: "Email address to search for"
                    ),
                    "limit": .integer(
                        description:
                            "Maximum conversations returned for each exact contact identity, applied independently per identity",
                        default: .int(defaultConversationsPerHandle),
                        minimum: 1,
                        maximum: maximumConversationsPerHandle
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Find Contact Conversations",
                readOnlyHint: true,
                openWorldHint: false
            ),
            requiredServiceIDs: [MessageService.serviceID]
        ) { arguments in
            // The only input this adapter owns is checked before either source is touched,
            // so a malformed request never becomes a contact query or a database read.
            let limit: Int
            if let value = arguments["limit"] {
                guard let requestedLimit = value.intValue,
                    (1 ... maximumConversationsPerHandle).contains(requestedLimit)
                else { throw MessagesConversationSearchError.invalidLimit }
                limit = requestedLimit
            } else {
                limit = defaultConversationsPerHandle
            }

            // The three criteria are read exactly as contacts_search reads them, so both
            // tools resolve the same words to the same contacts. The search operation
            // still rejects a query with no usable criterion.
            var query = ContactSearchQuery()
            if case let .string(name) = arguments["name"] { query.name = name }
            if case let .string(phone) = arguments["phone"] { query.phone = phone }
            if case let .string(email) = arguments["email"] { query.email = email }

            let result = try await ContactConversationSearch(
                contactSearch: self.contactSearch,
                conversationLookup: self.conversationLookup
            ).search(query, limitPerIdentity: limit)
            self.conversationSearchLog(result.telemetry)
            return result
        }

        Tool(
            name: "contacts_update",
            description:
                "Update an existing contact's information. Only provide values for properties that need to be changed; omit any properties that should remain unchanged.",
            inputSchema: .object(
                properties: ([
                    "identifier": .string(
                        description: "Unique identifier of the contact to update"
                    )
                ] as OrderedDictionary).merging(
                    contactProperties,
                    uniquingKeysWith: { new, _ in new }
                ),
                required: ["identifier"]
            ),
            annotations: .init(
                title: "Update Contact",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case let .string(identifier) = arguments["identifier"], !identifier.isEmpty else {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Valid contact identifier required"]
                )
            }

            // Fetch the mutable copy of the contact
            let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
            let contact =
                try await self.runContactStore {
                    try self.contactStore.unifiedContacts(matching: predicate, keysToFetch: contactKeys)
                }
                .first?
                .mutableCopy() as? CNMutableContact

            guard let updatedContact = contact else {
                throw NSError(
                    domain: "ContactsService",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Contact not found with identifier: \(identifier)"
                    ]
                )
            }

            // Update all properties
            updatedContact.populate(from: arguments)

            // Create a save request
            let saveRequest = CNSaveRequest()
            saveRequest.update(updatedContact)

            // Save the changes
            try await self.runContactStore {
                try self.contactStore.execute(saveRequest)
            }

            return Person(updatedContact)
        }

        Tool(
            name: "contacts_create",
            description:
                "Create a new contact with the specified information.",
            inputSchema: .object(
                properties: contactProperties,
                required: ["givenName"]
            ),
            annotations: .init(
                title: "Create Contact",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            // Create and populate a new contact
            let newContact = CNMutableContact()
            newContact.populate(from: arguments)

            // Validate that given name is provided and not empty
            if newContact.givenName.isEmpty {
                throw NSError(
                    domain: "ContactsService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Given name is required"]
                )
            }

            // Create a save request
            let saveRequest = CNSaveRequest()
            saveRequest.add(newContact, toContainerWithIdentifier: nil)

            // Execute the save request
            try await self.runContactStore {
                try self.contactStore.execute(saveRequest)
            }

            return Person(newContact)
        }
    }
}

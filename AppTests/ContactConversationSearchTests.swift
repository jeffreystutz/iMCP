import Contacts
import Foundation
import MCP
import Ontology
import XCTest

@testable import iMCP

private let chatIdentifierTestKey = Data(repeating: 0x5A, count: 32)

/// The literal Contacts + Messages composition behind `contacts_find_conversations`.
///
/// Every contact, handle, conversation, and identifier here is synthetic. The suite never
/// reads the user's Contacts database, never sends, never issues an Apple Event, and only
/// ever opens a temporary fixture database.
final class ContactConversationSearchTests: XCTestCase {

    // MARK: - Contact delegation

    func testAdapterDelegatesTheRawContactQueryExactlyOnce() async throws {
        let searcher = StubContactSearcher()
        let lookup = StubConversationLookup()
        let tool = try compositeTool(searcher: searcher, lookup: lookup)

        _ = try await tool(
            [
                "name": .string("Synthetic Person"),
                // Deliberately raw: the composite forwards what it was given and adds no
                // normalization of its own, exactly as contacts_search does.
                "phone": .string("(555) 010-0001"),
                "email": .string("Person@Example.invalid"),
            ],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
        )

        XCTAssertEqual(
            searcher.queries,
            [
                ContactSearchQuery(
                    name: "Synthetic Person",
                    phone: "(555) 010-0001",
                    email: "Person@Example.invalid"
                )
            ]
        )
    }

    func testAdapterRepresentsOmittedAndNonStringArgumentsAsAbsent() async throws {
        let searcher = StubContactSearcher()
        let tool = try compositeTool(searcher: searcher, lookup: StubConversationLookup())

        _ = try await tool(
            ["name": .string("Synthetic Person"), "phone": .int(5)],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
        )

        XCTAssertEqual(searcher.queries, [ContactSearchQuery(name: "Synthetic Person")])
    }

    func testCriterionFreeSearchPreservesTheContactsError() async throws {
        let searcher = StubContactSearcher()
        let lookup = StubConversationLookup()
        let tool = try compositeTool(searcher: searcher, lookup: lookup)

        do {
            _ = try await tool(
                [:],
                context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
            )
            XCTFail("An empty search should have been rejected")
        } catch let error as ContactSearchError {
            XCTAssertEqual(error, .noSearchCriteria)
            XCTAssertEqual(
                error.localizedDescription,
                "At least one valid search parameter is required"
            )
        }
        XCTAssertTrue(lookup.requests.isEmpty)
    }

    func testInvalidLimitFailsBeforeEitherSourceIsTouched() async throws {
        for (label, limit) in [
            ("below range", Value.int(0)),
            ("above range", Value.int(26)),
            ("not an integer", Value.string("10")),
        ] {
            let searcher = StubContactSearcher(result: [contactRecord(name: "Synthetic Person")])
            let lookup = StubConversationLookup()
            let tool = try compositeTool(searcher: searcher, lookup: lookup)

            do {
                _ = try await tool(
                    ["name": .string("Synthetic"), "limit": limit],
                    context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
                )
                XCTFail("\(label) should have been rejected")
            } catch let error as MessagesConversationSearchError {
                XCTAssertEqual(error, .invalidLimit, label)
            }

            XCTAssertTrue(searcher.queries.isEmpty, "\(label) reached Contacts")
            XCTAssertTrue(lookup.requests.isEmpty, "\(label) reached Messages")
        }
    }

    func testAdapterPassesTheRequestedAndDefaultPerIdentityLimit() async throws {
        let people = [contactRecord(name: "Synthetic One", telephone: ["+15550100001"])]

        let requested = StubConversationLookup()
        _ = try await compositeTool(
            searcher: StubContactSearcher(result: people),
            lookup: requested
        )(
            ["name": .string("Synthetic"), "limit": .int(3)],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
        )
        XCTAssertEqual(requested.requests.map(\.limitPerHandle), [3])

        let defaulted = StubConversationLookup()
        _ = try await compositeTool(
            searcher: StubContactSearcher(result: people),
            lookup: defaulted
        )(
            ["name": .string("Synthetic")],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
        )
        XCTAssertEqual(defaulted.requests.map(\.limitPerHandle), [10])
    }

    // MARK: - Identity extraction

    func testPhoneIdentitiesPrecedeEmailIdentitiesInStoredOrder() {
        let contact = contactRecord(
            name: "Synthetic One",
            telephone: ["+15550100002", "+15550100001"],
            email: ["second@example.invalid", "first@example.invalid"]
        )

        XCTAssertEqual(
            ContactConversationSearch.identities(of: contact),
            [
                "+15550100002",
                "+15550100001",
                "second@example.invalid",
                "first@example.invalid",
            ]
        )
    }

    func testIdentitiesAreNormalizedAndDeduplicatedByFirstOccurrence() {
        let contact = contactRecord(
            name: "Synthetic One",
            telephone: ["+15550100001", " +15550100001 ", "+15550100002"],
            email: ["Person@Example.invalid", "person@example.invalid"]
        )

        XCTAssertEqual(
            ContactConversationSearch.identities(of: contact),
            ["+15550100001", "+15550100002", "person@example.invalid"]
        )
    }

    func testUnusableStoredValuesAreSkippedRatherThanInferred() {
        let contact = contactRecord(
            name: "Synthetic One",
            telephone: ["(555) 010-0001", "555-0100", "5550100001", "+1 555 010 0001", ""],
            email: ["person@invalid", "not an email", "", "@example.invalid"]
        )

        XCTAssertEqual(ContactConversationSearch.identities(of: contact), [])
    }

    func testAContactWithNoStoredValuesYieldsNoIdentities() {
        XCTAssertEqual(
            ContactConversationSearch.identities(of: contactRecord(name: "Synthetic One")),
            []
        )
    }

    func testTheCompositeNeverFallsBackToRawTelephoneWhenNoE164WasPublished() {
        // The raw value looks perfectly valid, but the additive fact says Contacts could not
        // normalize it (as if the effective region rejected it). The composite must trust
        // that and not repeat normalization against the raw value itself.
        let contact = ContactRecord(
            person: {
                var person = Person(name: "Synthetic One")
                person.telephone = ["+15550100001"]
                return person
            }(),
            phoneNumbers: [ContactPhoneNumber(value: "+15550100001", label: nil, e164: nil)]
        )

        XCTAssertEqual(ContactConversationSearch.identities(of: contact), [])
    }

    func testPhoneIdentityComesFromTheAdditiveFactEvenWhenItDiffersFromTheRawValue() {
        // A synthetic stand-in for what real Contacts-side normalization does: the raw
        // stored value is a local format, and the additive fact carries the E.164 result a
        // region-aware normalizer produced for it. The composite must use that result
        // rather than reading or reinterpreting the raw value.
        let contact = ContactRecord(
            person: {
                var person = Person(name: "Synthetic One")
                person.telephone = ["(202) 555-0123"]
                return person
            }(),
            phoneNumbers: [
                ContactPhoneNumber(value: "(202) 555-0123", label: "mobile", e164: "+12025550123")
            ]
        )

        XCTAssertEqual(ContactConversationSearch.identities(of: contact), ["+12025550123"])
    }

    // MARK: - Mechanical join

    func testContactsAreReturnedUnchangedAndInOrder() async throws {
        let people = [
            contactRecord(name: "Synthetic One", telephone: ["+15550100001"]),
            contactRecord(name: "Synthetic Two", email: ["two@example.invalid"]),
            contactRecord(name: "Synthetic Three"),
        ]
        let lookup = StubConversationLookup()

        let result = try await search(people: people, lookup: lookup)

        XCTAssertEqual(result.results.map(\.contact), people)
    }

    func testOneConversationLookupCoversEveryContactAndIdentity() async throws {
        let people = [
            contactRecord(
                name: "Synthetic One",
                telephone: ["+15550100001", "+15550100002"],
                email: ["one@example.invalid"]
            ),
            contactRecord(name: "Synthetic Two", telephone: ["+15550100003"]),
            contactRecord(name: "Synthetic Three", email: ["three@example.invalid"]),
        ]
        let lookup = StubConversationLookup()

        _ = try await search(people: people, lookup: lookup)

        XCTAssertEqual(lookup.requests.count, 1)
        XCTAssertEqual(
            lookup.requests[0].handles,
            [
                "+15550100001",
                "+15550100002",
                "one@example.invalid",
                "+15550100003",
                "three@example.invalid",
            ]
        )
    }

    func testASharedIdentityIsLookedUpOnceAndReportedUnderEveryContact() async throws {
        let shared = "+15550100001"
        let people = [
            contactRecord(name: "Synthetic One", telephone: [shared, "+15550100002"]),
            contactRecord(name: "Synthetic Two", telephone: [shared]),
        ]
        let lookup = StubConversationLookup(
            result: MessagesConversationSearchResult(
                metadataAvailability: ["participants": true],
                results: [
                    handleConversations(shared, conversations: [conversation(chatId: "chat-one")]),
                    handleConversations("+15550100002"),
                ]
            )
        )

        let result = try await search(people: people, lookup: lookup)

        XCTAssertEqual(lookup.requests.count, 1)
        XCTAssertEqual(lookup.requests[0].handles, [shared, "+15550100002"])
        // The identity belongs to both contacts, so neither is collapsed into the other
        // and neither is chosen over the other.
        XCTAssertEqual(result.results.count, 2)
        XCTAssertEqual(result.results[0].identities.map(\.handle), [shared, "+15550100002"])
        XCTAssertEqual(result.results[1].identities.map(\.handle), [shared])
        XCTAssertEqual(result.results[0].identities[0], result.results[1].identities[0])
    }

    func testConversationFactsAreReproducedUnchanged() async throws {
        let complete = handleConversations(
            "+15550100001",
            completeness: .complete,
            truncated: true,
            conversations: [
                conversation(chatId: "chat-newest", kind: .direct, participants: ["+15550100001"]),
                conversation(
                    chatId: "chat-older",
                    kind: .group,
                    displayName: "Group One",
                    participants: ["+15550100001", "+15550100002"],
                    service: "SMS"
                ),
            ]
        )
        let incomplete = handleConversations(
            "one@example.invalid",
            completeness: .incomplete,
            truncated: false
        )
        let availability = ["participants": true, "service": false]
        let lookup = StubConversationLookup(
            result: MessagesConversationSearchResult(
                metadataAvailability: availability,
                results: [complete, incomplete]
            )
        )

        let result = try await search(
            people: [
                contactRecord(
                    name: "Synthetic One",
                    telephone: ["+15550100001"],
                    email: ["one@example.invalid"]
                )
            ],
            lookup: lookup
        )

        XCTAssertEqual(result.metadataAvailability, availability)
        XCTAssertEqual(result.results[0].identities, [complete, incomplete])
    }

    func testNoContactsMeansNoConversationLookup() async throws {
        let lookup = StubConversationLookup()

        let result = try await search(people: [], lookup: lookup)

        XCTAssertTrue(result.results.isEmpty)
        XCTAssertNil(result.metadataAvailability)
        XCTAssertTrue(lookup.requests.isEmpty)
    }

    func testContactsWithoutExactIdentitiesSkipMessagesEntirely() async throws {
        let people = [
            contactRecord(name: "Synthetic One", telephone: ["(555) 010-0001"]),
            contactRecord(name: "Synthetic Two", email: ["person@invalid"]),
        ]
        let lookup = StubConversationLookup()

        let result = try await search(people: people, lookup: lookup)

        XCTAssertTrue(lookup.requests.isEmpty)
        XCTAssertNil(result.metadataAvailability)
        XCTAssertEqual(result.results.map(\.contact), people)
        XCTAssertEqual(result.results.map(\.identities), [[], []])
    }

    // MARK: - Failure semantics

    func testContactsFailureStopsBeforeMessages() async throws {
        let lookup = StubConversationLookup()
        let searcher = StubContactSearcher(failure: SyntheticSourceFailure())

        do {
            _ = try await ContactConversationSearch(
                contactSearch: searcher,
                conversationLookup: lookup
            ).search(ContactSearchQuery(name: "Synthetic"), limitPerIdentity: 10)
            XCTFail("A Contacts failure should have propagated")
        } catch is SyntheticSourceFailure {
        }

        XCTAssertTrue(lookup.requests.isEmpty)
    }

    func testMessagesFailurePropagatesRatherThanBecomingEmptyEvidence() async throws {
        let lookup = StubConversationLookup(
            failure: MessagesChatRepositoryError.queryFailed(stage: "participants-unavailable", code: 1)
        )

        do {
            _ = try await search(
                people: [contactRecord(name: "Synthetic One", telephone: ["+15550100001"])],
                lookup: lookup
            )
            XCTFail("A Messages failure should have propagated")
        } catch let error as MessagesChatRepositoryError {
            XCTAssertEqual(error, .queryFailed(stage: "participants-unavailable", code: 1))
        }
    }

    func testAnUnansweredIdentityIsAFailureRatherThanEmptyEvidence() async throws {
        // A lookup that answers for only one of the two identities it was given must not
        // be rendered as "the other identity has no conversations".
        let lookup = StubConversationLookup(
            result: MessagesConversationSearchResult(
                metadataAvailability: [:],
                results: [handleConversations("+15550100001")]
            )
        )

        do {
            _ = try await search(
                people: [
                    contactRecord(
                        name: "Synthetic One",
                        telephone: ["+15550100001"],
                        email: ["one@example.invalid"]
                    )
                ],
                lookup: lookup
            )
            XCTFail("An unanswered identity should have failed")
        } catch let error as ContactConversationSearchError {
            XCTAssertEqual(error, .missingIdentityResult)
        }
    }

    // MARK: - Public tool contract

    func testToolAdvertisesAReadOnlyCompositeContract() throws {
        let tool = try compositeTool(
            searcher: StubContactSearcher(),
            lookup: StubConversationLookup()
        )

        XCTAssertEqual(tool.name, "contacts_find_conversations")
        XCTAssertEqual(tool.annotations.title, "Find Contact Conversations")
        XCTAssertEqual(tool.annotations.readOnlyHint, true)
        XCTAssertEqual(tool.annotations.openWorldHint, false)
        XCTAssertEqual(tool.requiredServiceIDs, [MessageService.serviceID])

        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema))
                as? [String: Any]
        )
        XCTAssertEqual(
            Set((schema["properties"] as? [String: Any] ?? [:]).keys),
            Set(["name", "phone", "email", "limit"])
        )
        // The three contact criteria stay optional in the schema; the search operation is
        // what rejects a query with no usable criterion.
        XCTAssertNil(schema["required"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        let limit = try XCTUnwrap((schema["properties"] as? [String: Any])?["limit"] as? [String: Any])
        XCTAssertEqual(limit["minimum"] as? Int, 1)
        XCTAssertEqual(limit["maximum"] as? Int, 25)
        XCTAssertEqual(limit["default"] as? Int, 10)
    }

    func testEncodedResultCarriesOnlyContactsIdentitiesAndConversationFacts() async throws {
        let lookup = StubConversationLookup(
            result: MessagesConversationSearchResult(
                metadataAvailability: ["participants": true],
                results: [
                    handleConversations(
                        "+15550100001",
                        conversations: [conversation(chatId: "chat-one")]
                    )
                ]
            )
        )
        let tool = try compositeTool(
            searcher: StubContactSearcher(
                result: [contactRecord(name: "Synthetic One", telephone: ["+15550100001"])]
            ),
            lookup: lookup
        )

        let value = try await tool(
            ["name": .string("Synthetic")],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
        )

        let root = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(Set(root.keys), Set(["metadataAvailability", "results"]))
        let results = try XCTUnwrap(root["results"]?.arrayValue)
        let entry = try XCTUnwrap(results[0].objectValue)
        XCTAssertEqual(Set(entry.keys), Set(["contact", "identities"]))
        let contact = try XCTUnwrap(entry["contact"]?.objectValue)
        XCTAssertNil(contact["person"])
        XCTAssertEqual(contact["@type"]?.stringValue, "Person")
        XCTAssertEqual(contact["givenName"]?.stringValue, "Synthetic")
        XCTAssertEqual(
            contact["telephone"]?.arrayValue?.map(\.stringValue),
            ["+15550100001"]
        )
        XCTAssertNotNil(contact["phoneNumbers"])

        let identity = try XCTUnwrap(entry["identities"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(
            Set(identity.keys),
            Set(["handle", "lookupCompleteness", "truncated", "conversations"])
        )
        XCTAssertEqual(identity["handle"]?.stringValue, "+15550100001")
        XCTAssertEqual(identity["lookupCompleteness"]?.stringValue, "complete")

        // Nothing interpretive may appear anywhere in the encoded result.
        let json = String(
            data: try JSONEncoder().encode(value),
            encoding: .utf8
        )
        let text = try XCTUnwrap(json)
        for forbidden in [
            "rank", "score", "confidence", "recommend", "selected", "destination",
            "transport", "authoriz", "send",
        ] {
            XCTAssertFalse(text.lowercased().contains(forbidden), forbidden)
        }
    }

    func testAnAbsentLookupIsAnExplicitNullRatherThanAMissingKey() async throws {
        let tool = try compositeTool(
            searcher: StubContactSearcher(result: [contactRecord(name: "Synthetic One")]),
            lookup: StubConversationLookup()
        )

        let value = try await tool(
            ["name": .string("Synthetic")],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
        )

        let root = try XCTUnwrap(value.objectValue)
        XCTAssertTrue(root.keys.contains("metadataAvailability"))
        XCTAssertEqual(root["metadataAvailability"], .null)
    }

    // MARK: - Messages access path

    func testCompositeReadsTheRealMessagesPathWithoutSendingOrEliciting() async throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }
        let messages = MessageService(
            sender: NonSendingCompositeStub(),
            conversationSearch: SQLiteMessagesChatRepository(identifierKey: chatIdentifierTestKey),
            chatDatabasePathOverride: fixture.path,
            chatListingLog: { _ in }
        )
        let tool = try compositeTool(
            searcher: StubContactSearcher(
                result: [
                    contactRecord(
                        name: "Synthetic One",
                        telephone: ["+15550100001", "(555) 010-0009"],
                        email: ["person@example.invalid"]
                    )
                ]
            ),
            lookup: messages
        )

        let value = try await tool(
            ["name": .string("Synthetic"), "limit": .int(2)],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
        )

        let entry = try XCTUnwrap(value.objectValue?["results"]?.arrayValue?[0].objectValue)
        let identities = try XCTUnwrap(entry["identities"]?.arrayValue)
        // The locally formatted number never became a handle, so two identities remain.
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities[0].objectValue?["handle"]?.stringValue, "+15550100001")
        XCTAssertEqual(identities[0].objectValue?["truncated"]?.boolValue, true)
        XCTAssertEqual(identities[0].objectValue?["conversations"]?.arrayValue?.count, 2)
        XCTAssertEqual(
            identities[1].objectValue?["handle"]?.stringValue,
            "person@example.invalid"
        )
        XCTAssertNotNil(value.objectValue?["metadataAvailability"]?.objectValue)
    }

    // MARK: - Service enablement gating

    func testCompositeIsAdvertisedOnlyWhileBothServicesAreEnabled() throws {
        let services = gatedServices()

        let both = ServiceRegistry.advertisedTools(
            from: services,
            enabled: EnabledServices([ContactsService.serviceID, MessageService.serviceID])
        )
        XCTAssertTrue(both.map(\.name).contains("contacts_find_conversations"))

        let contactsOnly = ServiceRegistry.advertisedTools(
            from: services,
            enabled: EnabledServices([ContactsService.serviceID])
        )
        XCTAssertFalse(contactsOnly.map(\.name).contains("contacts_find_conversations"))
        // Every other Contacts tool is unaffected by the missing dependency.
        XCTAssertEqual(
            contactsOnly.map(\.name),
            ["contacts_me", "contacts_search", "contacts_update", "contacts_create"]
        )

        let messagesOnly = ServiceRegistry.advertisedTools(
            from: services,
            enabled: EnabledServices([MessageService.serviceID])
        )
        XCTAssertFalse(messagesOnly.map(\.name).contains("contacts_find_conversations"))
        XCTAssertEqual(
            messagesOnly.map(\.name),
            [
                "messages_list_chats", "messages_find_conversations", "messages_fetch",
                "messages_send", "messages_send_attachment",
            ]
        )

        XCTAssertTrue(
            ServiceRegistry.advertisedTools(from: services, enabled: EnabledServices([])).isEmpty
        )
    }

    func testCompositeCannotBeCalledWhileEitherDependencyIsDisabled() async throws {
        let searcher = StubContactSearcher(
            result: [contactRecord(name: "Synthetic One", telephone: ["+15550100001"])]
        )
        let lookup = StubConversationLookup()
        let contacts = compositeService(searcher: searcher, lookup: lookup)
        let arguments: [String: Value] = ["name": .string("Synthetic")]
        let context = ToolCallContext(elicitation: UnsupportedCompositeElicitation())

        // A client that still remembers the tool from an earlier listing gets the same
        // answer as for a tool whose own service is off, and nothing runs.
        let withMessagesDisabled = try await contacts.call(
            tool: "contacts_find_conversations",
            with: arguments,
            context: context,
            enabledServices: EnabledServices([ContactsService.serviceID])
        )
        XCTAssertNil(withMessagesDisabled)
        XCTAssertTrue(searcher.queries.isEmpty)
        XCTAssertTrue(lookup.requests.isEmpty)

        let withBothEnabled = try await contacts.call(
            tool: "contacts_find_conversations",
            with: arguments,
            context: context,
            enabledServices: EnabledServices([ContactsService.serviceID, MessageService.serviceID])
        )
        XCTAssertNotNil(withBothEnabled)
        XCTAssertEqual(searcher.queries.count, 1)
        XCTAssertEqual(lookup.requests.count, 1)
    }

    func testTheCompositeIsNotReachableThroughTheMessagesService() async throws {
        // Contacts owns the tool, so a disabled Contacts service cannot be worked around
        // by a still-enabled Messages service.
        let messages = MessageService(
            sender: NonSendingCompositeStub(),
            conversationSearch: StubConversationSearcher(),
            chatDatabasePathOverride: "/synthetic/chat.db",
            chatListingLog: { _ in }
        )

        let value = try await messages.call(
            tool: "contacts_find_conversations",
            with: ["name": .string("Synthetic")],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation()),
            enabledServices: EnabledServices([ContactsService.serviceID, MessageService.serviceID])
        )

        XCTAssertNil(value)
    }

    func testDisablingMessagesLeavesEveryOtherContactsToolCallable() async throws {
        let searcher = StubContactSearcher(result: [contactRecord(name: "Synthetic One")])
        let contacts = compositeService(searcher: searcher, lookup: StubConversationLookup())

        let value = try await contacts.call(
            tool: "contacts_search",
            with: ["name": .string("Synthetic")],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation()),
            enabledServices: EnabledServices([ContactsService.serviceID])
        )

        XCTAssertNotNil(value)
        XCTAssertEqual(searcher.queries, [ContactSearchQuery(name: "Synthetic")])
    }

    func testOnlyTheCompositeDeclaresAServiceDependency() {
        for service in gatedServices() {
            for tool in service.tools where tool.name != "contacts_find_conversations" {
                XCTAssertTrue(tool.requiredServiceIDs.isEmpty, tool.name)
                XCTAssertTrue(EnabledServices([]).allows(tool), tool.name)
            }
        }
    }

    func testPrimitiveToolContractsAreUnchanged() throws {
        let services = gatedServices()
        let tools = services.flatMap(\.tools)

        let contactSearch = try XCTUnwrap(tools.first { $0.name == "contacts_search" })
        XCTAssertEqual(contactSearch.annotations.title, "Search Contacts")
        XCTAssertEqual(contactSearch.annotations.readOnlyHint, true)
        XCTAssertTrue(
            contactSearch.description.hasPrefix("Search contacts by name, phone number, and/or email")
        )

        let findConversations = try XCTUnwrap(
            tools.first { $0.name == "messages_find_conversations" }
        )
        XCTAssertEqual(findConversations.annotations.title, "Find Messages Conversations")
        XCTAssertEqual(findConversations.annotations.readOnlyHint, true)
        let findSchema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(findConversations.inputSchema))
                as? [String: Any]
        )
        XCTAssertEqual(findSchema["required"] as? [String], ["handles"])

        let listChats = try XCTUnwrap(tools.first { $0.name == "messages_list_chats" })
        XCTAssertEqual(listChats.annotations.title, "List Messages Conversations")
        XCTAssertEqual(listChats.annotations.readOnlyHint, true)

        let send = try XCTUnwrap(tools.first { $0.name == "messages_send" })
        XCTAssertEqual(send.annotations.title, "Send Message")
        XCTAssertEqual(send.annotations.readOnlyHint, false)
        XCTAssertEqual(send.annotations.destructiveHint, false)
        XCTAssertEqual(send.annotations.idempotentHint, false)
        XCTAssertEqual(send.annotations.openWorldHint, true)
    }

    // MARK: - Privacy

    func testLoggedFactsAndErrorsCarryNoPrivateValues() async throws {
        let recorded = LockedTelemetry()
        let contacts = ContactsService(
            contactSearch: StubContactSearcher(
                result: [
                    contactRecord(
                        name: "Synthetic Person",
                        telephone: ["+15550100001"],
                        email: ["person@example.invalid"]
                    )
                ]
            ),
            conversationLookup: StubConversationLookup(
                result: MessagesConversationSearchResult(
                    metadataAvailability: ["participants": true],
                    results: [
                        handleConversations(
                            "+15550100001",
                            conversations: [
                                conversation(
                                    chatId: "chat-one",
                                    displayName: "Group One",
                                    participants: ["+15550100001"]
                                )
                            ]
                        ),
                        handleConversations("person@example.invalid"),
                    ]
                )
            ),
            conversationSearchLog: { recorded.record($0) }
        )
        let tool = try XCTUnwrap(
            contacts.tools.first { $0.name == "contacts_find_conversations" }
        )

        _ = try await tool(
            ["name": .string("Synthetic Person")],
            context: ToolCallContext(elicitation: UnsupportedCompositeElicitation())
        )

        let facts = try XCTUnwrap(recorded.values.first)
        XCTAssertEqual(
            facts,
            ContactConversationSearchTelemetry(
                contacts: 1,
                identities: 2,
                conversations: 1,
                searchedMessages: true
            )
        )
        // The only loggable rendering of a completed lookup is its counts.
        let rendered = String(describing: facts)
        for forbidden in ["Synthetic", "+1555", "@example.invalid", "chat-one", "Group One"] {
            XCTAssertFalse(rendered.contains(forbidden), forbidden)
        }
    }

    func testCompositeErrorsNeverCarryARejectedValue() {
        let descriptions = [
            ContactConversationSearchError.missingIdentityResult.localizedDescription,
            MessagesConversationSearchError.invalidLimit.localizedDescription,
        ]

        for description in descriptions {
            XCTAssertFalse(description.contains("@"))
            XCTAssertFalse(description.contains("+1555"))
            XCTAssertFalse(description.contains("Synthetic"))
        }
    }

    // MARK: - Helpers

    private func search(
        people: [ContactRecord],
        lookup: StubConversationLookup,
        limitPerIdentity: Int = 10
    ) async throws -> ContactConversationSearchResult {
        try await ContactConversationSearch(
            contactSearch: StubContactSearcher(result: people),
            conversationLookup: lookup
        ).search(ContactSearchQuery(name: "Synthetic"), limitPerIdentity: limitPerIdentity)
    }

    private func compositeService(
        searcher: any ContactSearching,
        lookup: any MessagesConversationLookup
    ) -> ContactsService {
        ContactsService(
            contactSearch: searcher,
            conversationLookup: lookup,
            conversationSearchLog: { _ in }
        )
    }

    private func compositeTool(
        searcher: any ContactSearching,
        lookup: any MessagesConversationLookup
    ) throws -> iMCP.Tool {
        try XCTUnwrap(
            compositeService(searcher: searcher, lookup: lookup).tools
                .first { $0.name == "contacts_find_conversations" }
        )
    }

    private func gatedServices() -> [any Service] {
        [
            compositeService(searcher: StubContactSearcher(), lookup: StubConversationLookup()),
            MessageService(
                sender: NonSendingCompositeStub(),
                conversationSearch: StubConversationSearcher(),
                chatDatabasePathOverride: "/synthetic/chat.db",
                chatListingLog: { _ in }
            ),
        ]
    }

    /// Builds a synthetic contact record. `telephone` values become additive phone facts
    /// automatically: a value that is already strict E.164 gets that same value as its
    /// `e164`, matching what a real region-aware normalizer would produce for a number
    /// already in that form; anything else gets `e164: nil`, standing in for a value the
    /// effective region could not parse and validate. Pass `phoneNumbers` explicitly
    /// instead when a test needs a label or an E.164 result that does not match the raw
    /// value verbatim.
    private func contactRecord(
        name: String,
        telephone: [String]? = nil,
        email: [String]? = nil,
        phoneNumbers: [ContactPhoneNumber]? = nil
    ) -> ContactRecord {
        var person = Person(name: name)
        person.telephone = telephone
        person.email = email
        let numbers =
            phoneNumbers
            ?? (telephone ?? []).map { value in
                ContactPhoneNumber(
                    value: value,
                    label: nil,
                    e164: messagesHandleIsE164(value.trimmingCharacters(in: .whitespacesAndNewlines))
                        ? value : nil
                )
            }
        return ContactRecord(person: person, phoneNumbers: numbers)
    }

    private func handleConversations(
        _ handle: String,
        completeness: MessagesLookupCompleteness = .complete,
        truncated: Bool = false,
        conversations: [MessagesConversationSummary] = []
    ) -> MessagesHandleConversations {
        MessagesHandleConversations(
            handle: handle,
            lookupCompleteness: completeness,
            truncated: truncated,
            conversations: conversations
        )
    }

    private func conversation(
        chatId: String,
        kind: MessagesChatKind = .direct,
        displayName: String? = nil,
        participants: [String] = ["+15550100001"],
        service: String? = "iMessage"
    ) -> MessagesConversationSummary {
        MessagesConversationSummary(
            chatId: chatId,
            kind: kind,
            displayName: displayName,
            participants: participants.map {
                MessagesParticipant(
                    handle: $0,
                    originalHandle: nil,
                    canonicalE164: messagesHandleIsE164($0) ? $0 : nil,
                    email: messagesHandleIsEmail($0) ? $0 : nil,
                    service: service,
                    country: nil
                )
            },
            service: service,
            latestActivity: nil
        )
    }
}

private struct SyntheticSourceFailure: Error {}

private final class StubContactSearcher: ContactSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var storedQueries: [ContactSearchQuery] = []
    private let result: [ContactRecord]
    private let failure: (any Error)?

    init(result: [ContactRecord] = [], failure: (any Error)? = nil) {
        self.result = result
        self.failure = failure
    }

    var queries: [ContactSearchQuery] { lock.withLock { storedQueries } }

    func search(_ query: ContactSearchQuery) async throws -> [ContactRecord] {
        // The production operation rejects a criterion-free query before reaching
        // Contacts; the stub reproduces that so the composite observes the same behavior.
        _ = try CNContactStoreSearch.predicate(for: query)
        lock.withLock { storedQueries.append(query) }
        if let failure { throw failure }
        return result
    }
}

private struct RecordedLookup: Equatable {
    let handles: [String]
    let limitPerHandle: Int
}

private final class StubConversationLookup: MessagesConversationLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [RecordedLookup] = []
    private let result: MessagesConversationSearchResult?
    private let failure: (any Error)?

    init(result: MessagesConversationSearchResult? = nil, failure: (any Error)? = nil) {
        self.result = result
        self.failure = failure
    }

    var requests: [RecordedLookup] { lock.withLock { storedRequests } }

    func findConversations(
        handles: [String],
        limitPerHandle: Int
    ) async throws -> MessagesConversationSearchResult {
        lock.withLock {
            storedRequests.append(
                RecordedLookup(handles: handles, limitPerHandle: limitPerHandle)
            )
        }
        if let failure { throw failure }
        if let result { return result }
        // The operation answers for every handle it was asked about.
        return MessagesConversationSearchResult(
            metadataAvailability: ["participants": true],
            results: handles.map {
                MessagesHandleConversations(
                    handle: $0,
                    lookupCompleteness: .complete,
                    truncated: false,
                    conversations: []
                )
            }
        )
    }
}

private struct StubConversationSearcher: MessagesConversationSearching {
    func findConversations(
        handles: [String],
        limitPerHandle: Int,
        databasePath: String
    ) throws -> MessagesConversationSearchResult {
        XCTFail("Tool listing must not search conversations")
        return MessagesConversationSearchResult(metadataAvailability: [:], results: [])
    }
}

private final class LockedTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ContactConversationSearchTelemetry] = []

    var values: [ContactConversationSearchTelemetry] { lock.withLock { stored } }

    func record(_ facts: ContactConversationSearchTelemetry) {
        lock.withLock { stored.append(facts) }
    }
}

private struct NonSendingCompositeStub: MessagesSending {
    func automationAuthorization() -> MessagesAutomationAuthorization {
        XCTFail("Contact conversation discovery must not consult Messages automation")
        return .denied
    }

    func requestAutomationAuthorization() throws {
        XCTFail("Contact conversation discovery must not request automation permission")
    }

    func isChatAddressable(chatGUID: String) throws -> Bool {
        XCTFail("Contact conversation discovery must not send Apple Events")
        return false
    }

    func submit(chatGUID: String, body: String) throws {
        XCTFail("Contact conversation discovery must not dispatch a message")
    }

    func submitChatAttachment(chatGUID: String, attachmentFile: URL) throws {
        XCTFail("Contact conversation discovery must not dispatch an attachment")
    }
}

private struct UnsupportedCompositeElicitation: ElicitationRequester {
    let supportsFormElicitation = false

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        XCTFail("Contact conversation discovery must not elicit")
        throw ElicitationRequestError.formUnsupported
    }
}

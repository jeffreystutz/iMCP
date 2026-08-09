import Foundation
import MCP
import XCTest

@testable import iMCP

private let chatIdentifierTestKey = Data(repeating: 0xA5, count: 32)

/// Conversation discovery over exact handles.
///
/// Every handle, name, and identifier here is synthetic. The suite never opens a real
/// Messages database, never sends, and never touches Contacts.
final class MessagesConversationSearchTests: XCTestCase {

    // MARK: - Direct and group evidence

    func testExactDirectConversationIsFoundForOneE164Handle() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )

        XCTAssertEqual(result.results.count, 1)
        let lookup = result.results[0]
        XCTAssertEqual(lookup.handle, "+15550100001")
        XCTAssertEqual(lookup.lookupCompleteness, .complete)
        XCTAssertFalse(lookup.truncated)
        XCTAssertTrue(lookup.conversations.contains { $0.displayName == "Direct A" })
        let direct = try XCTUnwrap(lookup.conversations.first { $0.displayName == "Direct A" })
        XCTAssertEqual(direct.kind, .direct)
        XCTAssertEqual(direct.participants.map(\.handle), ["+15550100001"])
    }

    func testEmailHandleFindsItsOwnConversations() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["person@example.invalid"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )

        XCTAssertEqual(
            result.results[0].conversations.map(\.displayName),
            ["Direct B", "Group One"]
        )
        XCTAssertEqual(result.results[0].lookupCompleteness, .complete)
    }

    func testMixedHandlesEachGetTheirOwnConversationArray() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100001", "person@example.invalid"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )

        XCTAssertEqual(result.results.map(\.handle), ["+15550100001", "person@example.invalid"])
        XCTAssertEqual(
            result.results[0].conversations.map(\.displayName),
            ["Direct A", "Group One", "Group Two", "Group Three"]
        )
        XCTAssertEqual(
            result.results[1].conversations.map(\.displayName),
            ["Direct B", "Group One"]
        )
        // The group holding both handles is legitimate evidence under each of them.
        let sharedIds = Set(result.results[0].conversations.map(\.chatId))
            .intersection(result.results[1].conversations.map(\.chatId))
        XCTAssertEqual(sharedIds.count, 1)
    }

    func testGroupConversationsAreReturnedWithTheParticipantsNeededForContext() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        let group = try XCTUnwrap(
            result.results[0].conversations.first { $0.displayName == "Group One" }
        )

        XCTAssertEqual(group.kind, .group)
        XCTAssertEqual(
            group.participants.map(\.handle),
            ["+15550100001", "+15550100002", "person@example.invalid"]
        )
        XCTAssertEqual(group.service, "iMessage")
        // The same handle yields both a direct conversation and groups, and no group is
        // ever collapsed into a direct conversation.
        XCTAssertEqual(
            result.results[0].conversations.map(\.kind),
            [.direct, .group, .group, .group]
        )
    }

    func testUnrelatedConversationsAreNeverReturned() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        XCTAssertFalse(
            result.results[0].conversations.contains { $0.displayName == "Unrelated" }
        )
    }

    // MARK: - Ordering and truncation

    func testConversationsAreOrderedNewestFirstUsingIndexSemantics() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }
        let repo = repository()

        let result = try repo.findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        let order = result.results[0].conversations.map(\.chatId)

        // The order matches the conversation index's own ordering of the same chats.
        let index = try repo.listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: nil,
            participants: nil,
            detail: .summary
        )
        let expected = index.chats.map(\.chatId).filter(Set(order).contains)
        XCTAssertEqual(order, expected)
        XCTAssertEqual(
            result.results[0].conversations.compactMap(\.latestActivity),
            result.results[0].conversations.compactMap(\.latestActivity).sorted(by: >)
        )
    }

    func testActivitylessConversationsSortLastByTheIndexTieBreaker() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }
        // Two further conversations for one handle, neither carrying any activity. The
        // index orders those by descending ROWID, and discovery must not reorder them.
        try fixture.execute(
            """
            INSERT INTO chat VALUES
              (9, 'search-quiet-one-guid.example', 'chat-quiet-one.example', NULL, NULL,
               NULL, 'Quiet One', 'iMessage', 0, 0, NULL),
              (10, 'search-quiet-two-guid.example', 'chat-quiet-two.example', NULL, NULL,
               NULL, 'Quiet Two', 'iMessage', 0, 0, NULL);
            INSERT INTO chat_handle_join VALUES (9, 1), (9, 3), (10, 1), (10, 4);
            """
        )

        let result = try repository().findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        XCTAssertEqual(
            result.results[0].conversations.map(\.displayName),
            ["Direct A", "Group One", "Group Two", "Group Three", "Quiet Two", "Quiet One"]
        )
    }

    func testPerHandleLimitIsIndependentAndReportsTruncationOnlyWhenMoreExisted() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100001", "person@example.invalid"],
            limitPerHandle: 2,
            databasePath: fixture.path
        )

        // The busy handle keeps its own two newest conversations and reports truncation.
        XCTAssertEqual(
            result.results[0].conversations.map(\.displayName),
            ["Direct A", "Group One"]
        )
        XCTAssertTrue(result.results[0].truncated)
        // The quieter handle's budget is untouched by the busy one and is not truncated.
        XCTAssertEqual(
            result.results[1].conversations.map(\.displayName),
            ["Direct B", "Group One"]
        )
        XCTAssertFalse(result.results[1].truncated)
    }

    func testTruncationIsFalseWhenTheLimitExactlyMatchesTheMatchCount() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 4,
            databasePath: fixture.path
        )
        XCTAssertEqual(result.results[0].conversations.count, 4)
        XCTAssertFalse(result.results[0].truncated)
    }

    // MARK: - Lookup completeness

    func testStoredLocalPhoneFormatMakesTheLookupIncompleteWithoutRewritingIt() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100009"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        let lookup = result.results[0]

        // "(555) 010-0009" could denote this handle but cannot be compared exactly, so it
        // is neither rewritten nor claimed as a match.
        XCTAssertEqual(lookup.lookupCompleteness, .incomplete)
        XCTAssertFalse(lookup.conversations.contains { $0.displayName == "Local Format" })
        // A conversation that does match exactly is still returned alongside it.
        XCTAssertEqual(lookup.conversations.map(\.displayName), ["Direct C"])
    }

    func testSafelyInterpretableAbsenceIsCompleteWithNoConversations() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15559999999", "absent@example.invalid"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )

        for lookup in result.results {
            XCTAssertEqual(lookup.lookupCompleteness, .complete)
            XCTAssertTrue(lookup.conversations.isEmpty)
            XCTAssertFalse(lookup.truncated)
        }
    }

    func testOneHandlesIncompletenessDoesNotSpreadToOtherHandles() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100009", "+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        XCTAssertEqual(result.results[0].lookupCompleteness, .incomplete)
        XCTAssertEqual(result.results[1].lookupCompleteness, .complete)
    }

    func testUnsupportedParticipantSchemaFailsInsteadOfReportingCompleteAndEmpty() throws {
        let fixture = try ChatDatabaseFixture.unreadableHandles()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try repository().findConversations(
                handles: ["+15550100001"],
                limitPerHandle: 10,
                databasePath: fixture.path
            )
        ) { error in
            XCTAssertEqual(
                (error as? MessagesChatRepositoryError)?.diagnosticStage,
                "participants-unavailable"
            )
        }
    }

    func testMissingConversationIdentityFailsTheOperation() throws {
        let fixture = try ChatDatabaseFixture.withoutSchema()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try repository().findConversations(
                handles: ["+15550100001"],
                limitPerHandle: 10,
                databasePath: fixture.path
            )
        ) { error in
            XCTAssertEqual(
                error as? MessagesChatRepositoryError,
                .minimumSchemaUnavailable
            )
        }
    }

    // MARK: - Public metadata

    func testConversationSummaryExposesOnlyTheOpaquePublicIdentity() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }
        let repo = repository()

        let result = try repo.findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        let index = try repo.listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: nil,
            participants: nil,
            detail: .summary
        )
        let publicIdsByGuid = Dictionary(
            uniqueKeysWithValues: index.chats.map { ($0.chatGuid, $0.chatId) }
        )

        let direct = try XCTUnwrap(
            result.results[0].conversations.first { $0.displayName == "Direct A" }
        )
        XCTAssertEqual(direct.chatId, publicIdsByGuid["search-direct-a-guid.example"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try XCTUnwrap(String(data: try encoder.encode(result), encoding: .utf8))
        for guid in publicIdsByGuid.keys {
            XCTAssertFalse(encoded.contains(guid), "a raw chat GUID reached the public result")
        }
        XCTAssertFalse(encoded.contains("chatGuid"))
        XCTAssertFalse(encoded.contains("chatIdentifier"))
        XCTAssertFalse(encoded.contains("roomName"))
        XCTAssertFalse(encoded.contains("Room One"))
    }

    func testMetadataAvailabilityDescribesOnlyTheReturnedFields() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        let result = try repository().findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        XCTAssertEqual(
            Set(result.metadataAvailability.keys),
            Set(SQLiteMessagesChatRepository.conversationSearchAvailabilityKeys)
        )
        XCTAssertEqual(result.metadataAvailability["service"], true)
        XCTAssertEqual(result.metadataAvailability["latestActivityTimestamp"], true)
        XCTAssertEqual(result.metadataAvailability["participants"], true)
    }

    func testUnsupportedParticipantMetadataIsReportedRatherThanFabricated() throws {
        // This schema has no `uncanonicalized_id`, `service`, or `country` on `handle`, so
        // those participant details are absent rather than invented.
        let fixture = try ChatDatabaseFixture.reduced()
        defer { fixture.remove() }
        try fixture.execute(
            """
            INSERT INTO handle VALUES (1, '+15550100001');
            INSERT INTO chat_handle_join VALUES (1, 1);
            """
        )

        let result = try repository().findConversations(
            handles: ["+15550100001"],
            limitPerHandle: 10,
            databasePath: fixture.path
        )
        let conversation = try XCTUnwrap(result.results[0].conversations.first)
        XCTAssertEqual(conversation.displayName, "Reduced Chat")
        XCTAssertEqual(conversation.service, "iMessage")
        XCTAssertNotNil(conversation.latestActivity)

        let participant = try XCTUnwrap(conversation.participants.first)
        XCTAssertEqual(participant.handle, "+15550100001")
        XCTAssertNil(participant.service)
        XCTAssertNil(participant.country)
        XCTAssertEqual(result.metadataAvailability["participants"], true)
        XCTAssertEqual(result.metadataAvailability["participantService"], false)
        XCTAssertEqual(result.metadataAvailability["participantCountry"], false)
        XCTAssertEqual(result.metadataAvailability["participantOriginalHandle"], false)
    }

    // MARK: - Query shape

    func testQueryCountDoesNotGrowWithTheNumberOfRequestedHandles() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }

        func stages(for handles: [String]) throws -> [String] {
            let observed = LockedStrings()
            _ = try repository(filterPageSize: 4, observer: { observed.append($0) })
                .findConversations(
                    handles: handles,
                    limitPerHandle: 10,
                    databasePath: fixture.path
                )
            return observed.values
        }

        let single = try stages(for: ["+15550100001"])
        let many = try stages(for: [
            "+15550100001", "+15550100002", "+15550100003", "+15550100004",
            "+15550100005", "+15550100009", "person@example.invalid",
            "absent@example.invalid",
        ])

        XCTAssertEqual(single, many)
        // Eight conversations at four rows per page: three header pages, the last empty,
        // and one batched participant query per non-empty page.
        XCTAssertEqual(many.filter { $0 == "chats" }.count, 3)
        XCTAssertEqual(many.filter { $0 == "participants" }.count, 2)
        XCTAssertFalse(many.contains("messages"))
        XCTAssertFalse(many.contains("attachments"))
    }

    func testDuplicateHandlesAreOneUnitOfWorkAndKeepBothOutputPositions() throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }
        let observed = LockedStrings()

        let result = try repository(filterPageSize: 4, observer: { observed.append($0) })
            .findConversations(
                handles: ["+15550100001", "person@example.invalid", "+15550100001"],
                limitPerHandle: 10,
                databasePath: fixture.path
            )

        XCTAssertEqual(
            result.results.map(\.handle),
            ["+15550100001", "person@example.invalid", "+15550100001"]
        )
        XCTAssertEqual(result.results[0], result.results[2])
        XCTAssertEqual(observed.values.filter { $0 == "chats" }.count, 3)
    }

    // MARK: - MCP adapter

    func testToolAdvertisesAReadOnlyConversationSearchContract() throws {
        let tool = try findConversationsTool(searcher: RecordingConversationSearcher())
        XCTAssertEqual(tool.annotations.title, "Find Messages Conversations")
        XCTAssertEqual(tool.annotations.readOnlyHint, true)
        XCTAssertEqual(tool.annotations.openWorldHint, false)

        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema))
                as? [String: Any]
        )
        XCTAssertEqual(
            Set((schema["properties"] as? [String: Any] ?? [:]).keys),
            Set(["handles", "limit"])
        )
        XCTAssertEqual(schema["required"] as? [String], ["handles"])
        let handles = try XCTUnwrap(
            (schema["properties"] as? [String: Any])?["handles"] as? [String: Any]
        )
        XCTAssertEqual(handles["minItems"] as? Int, 1)
        XCTAssertEqual(handles["maxItems"] as? Int, 20)
    }

    func testAdapterNormalizesHandlesAndAppliesTheDefaultPerHandleLimit() async throws {
        let searcher = RecordingConversationSearcher()
        let tool = try findConversationsTool(searcher: searcher)

        _ = try await tool(
            ["handles": .array([.string("+15550100001"), .string(" Person@Example.invalid ")])],
            context: ToolCallContext(elicitation: UnsupportedSearchElicitation())
        )

        XCTAssertEqual(
            searcher.requests,
            [
                RecordedSearch(
                    handles: ["+15550100001", "person@example.invalid"],
                    limitPerHandle: 10,
                    databasePath: "/synthetic/chat.db"
                )
            ]
        )
    }

    func testAdapterRejectsInvalidInputBeforeAnyDatabaseWork() async throws {
        let cases: [(String, [String: Value], MessagesConversationSearchError)] = [
            ("local phone", ["handles": .array([.string("(555) 010-0001")])], .invalidHandles),
            ("malformed email", ["handles": .array([.string("person@invalid")])], .invalidHandles),
            (
                "one bad element among good ones",
                ["handles": .array([.string("+15550100001"), .string("not-a-handle")])],
                .invalidHandles
            ),
            ("non-string element", ["handles": .array([.int(5)])], .invalidHandles),
            ("empty array", ["handles": .array([])], .invalidHandles),
            ("missing handles", [:], .invalidHandles),
            (
                "too many handles",
                [
                    "handles": .array(
                        (1 ... 21).map { .string(String(format: "+1555010%04d", $0)) }
                    )
                ],
                .tooManyHandles
            ),
            (
                "limit below range",
                ["handles": .array([.string("+15550100001")]), "limit": .int(0)],
                .invalidLimit
            ),
            (
                "limit above range",
                ["handles": .array([.string("+15550100001")]), "limit": .int(26)],
                .invalidLimit
            ),
        ]

        for (label, arguments, expected) in cases {
            let searcher = RecordingConversationSearcher()
            let tool = try findConversationsTool(searcher: searcher)
            do {
                _ = try await tool(
                    arguments,
                    context: ToolCallContext(elicitation: UnsupportedSearchElicitation())
                )
                XCTFail("\(label) should have been rejected")
            } catch let error as MessagesConversationSearchError {
                XCTAssertEqual(error, expected, "\(label)")
            }
            XCTAssertTrue(searcher.requests.isEmpty, "\(label) reached the database")
        }
    }

    func testAdapterErrorsNeverCarryTheRejectedHandle() {
        for error in [
            MessagesConversationSearchError.invalidHandles,
            .tooManyHandles,
            .invalidLimit,
        ] {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("@"))
            XCTAssertFalse(description.contains("+1555"))
        }
    }

    func testAdapterReturnsTheOperationsResultUnchanged() async throws {
        let fixture = try ChatDatabaseFixture.conversationSearch()
        defer { fixture.remove() }
        let service = MessageService(
            sender: NonSendingStub(),
            conversationSearch: repository(),
            chatDatabasePathOverride: fixture.path,
            chatListingLog: { _ in }
        )
        let tool = try XCTUnwrap(
            service.tools.first { $0.name == "messages_find_conversations" }
        )

        let value = try await tool(
            [
                "handles": .array([.string("+15550100001")]),
                "limit": .int(2),
            ],
            context: ToolCallContext(elicitation: UnsupportedSearchElicitation())
        )

        let results = try XCTUnwrap(value.objectValue?["results"]?.arrayValue)
        XCTAssertEqual(results.count, 1)
        let lookup = try XCTUnwrap(results[0].objectValue)
        XCTAssertEqual(lookup["handle"]?.stringValue, "+15550100001")
        XCTAssertEqual(lookup["lookupCompleteness"]?.stringValue, "complete")
        XCTAssertEqual(lookup["truncated"]?.boolValue, true)
        let conversations = try XCTUnwrap(lookup["conversations"]?.arrayValue)
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations[0].objectValue?["kind"]?.stringValue, "direct")
        XCTAssertEqual(conversations[1].objectValue?["kind"]?.stringValue, "group")
        XCTAssertNotNil(conversations[0].objectValue?["chatId"]?.stringValue)
    }

    // MARK: - Helpers

    private func repository(
        filterPageSize: Int = SQLiteMessagesChatRepository.defaultFilterPageSize,
        observer: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SQLiteMessagesChatRepository {
        SQLiteMessagesChatRepository(
            identifierKey: chatIdentifierTestKey,
            filterPageSize: filterPageSize,
            queryObserver: observer
        )
    }

    private func findConversationsTool(
        searcher: any MessagesConversationSearching
    ) throws -> iMCP.Tool {
        let service = MessageService(
            sender: NonSendingStub(),
            conversationSearch: searcher,
            chatDatabasePathOverride: "/synthetic/chat.db",
            chatListingLog: { _ in }
        )
        return try XCTUnwrap(service.tools.first { $0.name == "messages_find_conversations" })
    }
}

private struct RecordedSearch: Equatable {
    let handles: [String]
    let limitPerHandle: Int
    let databasePath: String
}

private final class RecordingConversationSearcher: MessagesConversationSearching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRequests: [RecordedSearch] = []
    var requests: [RecordedSearch] { lock.withLock { storedRequests } }

    func findConversations(
        handles: [String],
        limitPerHandle: Int,
        databasePath: String
    ) throws -> MessagesConversationSearchResult {
        lock.withLock {
            storedRequests.append(
                RecordedSearch(
                    handles: handles,
                    limitPerHandle: limitPerHandle,
                    databasePath: databasePath
                )
            )
        }
        return MessagesConversationSearchResult(metadataAvailability: [:], results: [])
    }
}

private struct NonSendingStub: MessagesSending {
    func automationAuthorization() -> MessagesAutomationAuthorization {
        XCTFail("Conversation discovery must not consult Messages automation")
        return .denied
    }

    func requestAutomationAuthorization() throws {
        XCTFail("Conversation discovery must not request automation permission")
    }

    func isChatAddressable(chatGUID: String) throws -> Bool {
        XCTFail("Conversation discovery must not send Apple Events")
        return false
    }

    func submit(recipient: String, body: String) throws {
        XCTFail("Conversation discovery must not dispatch a message")
    }

    func submit(chatGUID: String, body: String) throws {
        XCTFail("Conversation discovery must not dispatch a message")
    }
}

private struct UnsupportedSearchElicitation: ElicitationRequester {
    let supportsFormElicitation = false

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        XCTFail("Conversation discovery must not elicit")
        throw ElicitationRequestError.formUnsupported
    }
}

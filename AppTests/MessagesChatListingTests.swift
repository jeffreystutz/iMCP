import MCP
import SQLite3
import XCTest

@testable import iMCP

private let chatIdentifierTestKey = Data(repeating: 0xA5, count: 32)

final class MessagesChatListingTests: XCTestCase {
    func testSummaryPreservesCoreFieldsAndUsesMembershipParticipants() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let queries = LockedStrings()
        let index = try repository(observer: { queries.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        )

        XCTAssertEqual(index.detail, .summary)
        XCTAssertEqual(index.chats.map(\.displayName), ["Synthetic Group", "Direct Thread"])
        XCTAssertEqual(index.chats.map(\.kind), [.group, .direct])
        XCTAssertEqual(index.chats.map(\.participantCount), [3, 1])
        XCTAssertNil(index.chats[0].full)
        XCTAssertFalse(queries.values.contains("messages"))
        XCTAssertFalse(queries.values.contains("attachments"))

        let group = index.chats[0]
        XCTAssertEqual(group.chatId, group.id)
        XCTAssertEqual(group.chatGuid, "group-guid.example")
        XCTAssertEqual(group.chatIdentifier, "group-identifier.example")
        XCTAssertEqual(group.groupId, "group-id.example")
        XCTAssertEqual(group.originalGroupId, "original-group-id.example")
        XCTAssertEqual(group.roomName, "Synthetic Room")
        XCTAssertEqual(group.service, "iMessage")
        XCTAssertEqual(group.isArchived, true)
        XCTAssertEqual(group.isFiltered, false)
        XCTAssertNotNil(group.lastReadTimestamp)
        XCTAssertNotNil(group.latestActivity)
        XCTAssertEqual(
            group.participants?.map(\.handle),
            ["+15550100001", "local-number", "person@example.invalid"]
        )
        XCTAssertEqual(group.participants?[0].canonicalE164, "+15550100001")
        XCTAssertNil(group.participants?[1].canonicalE164)
        XCTAssertEqual(group.participants?[2].email, "person@example.invalid")
        XCTAssertEqual(group.participants?[0].originalHandle, "(555) 010-0001")
        XCTAssertEqual(group.participants?[0].country, "US")
        XCTAssertEqual(index.metadataAvailability["mentions"], false)
        XCTAssertEqual(index.metadataAvailability["screened"], false)
    }

    func testFullMetadataCountsOnlyUserVisibleBaseMessages() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: .group,
            detail: .full
        )
        let metadata = try XCTUnwrap(index.chats.first?.full)

        XCTAssertEqual(metadata.messageCount, 9)
        XCTAssertEqual(metadata.incomingMessageCount, 6)
        XCTAssertEqual(metadata.outgoingMessageCount, 3)
        XCTAssertEqual(metadata.unreadIncomingCount, 6)
        XCTAssertEqual(metadata.failedOutgoingCount, 1)
        XCTAssertEqual(metadata.reactionEventCount, 2)
        XCTAssertEqual(metadata.reactionAddCount, 1)
        XCTAssertEqual(metadata.reactionRemoveCount, 1)
        XCTAssertEqual(metadata.replyCount, 1)
        XCTAssertEqual(metadata.editedMessageCount, 1)
        XCTAssertEqual(metadata.retractionCount, 1)
        XCTAssertEqual(metadata.expressiveEffectMessageCount, 1)
        XCTAssertEqual(metadata.pluginMessageCount, 1)
        XCTAssertNil(metadata.mentionCount)
        XCTAssertEqual(index.metadataAvailability["mentions"], false)

        XCTAssertEqual(metadata.latestIncomingMessage?.messageGuid, "retracted-message.example")
        XCTAssertEqual(metadata.latestOutgoingMessage?.messageGuid, "failed-message.example")
        XCTAssertEqual(metadata.latestOutgoingMessage?.deliveryState, "failed")
        XCTAssertEqual(metadata.latestActivity?.messageGuid, "system-event.example")
        XCTAssertFalse(metadata.latestActivity?.messageGuid.contains("body") ?? true)
    }

    func testAttachmentAggregatesDeduplicateJoinsAndExposeOnlyCategories() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: .group,
            detail: .full
        )
        let metadata = try XCTUnwrap(index.chats.first?.full)
        XCTAssertEqual(metadata.hasAttachments, true)
        XCTAssertEqual(metadata.attachmentCount, 2)
        XCTAssertEqual(metadata.messagesWithAttachmentsCount, 1)
        XCTAssertEqual(metadata.attachmentCountByMediaCategory, ["image": 1, "other": 1])
        XCTAssertEqual(metadata.stickerAttachmentCount, 1)
        XCTAssertEqual(
            metadata.latestAttachmentTimestamp?.timeIntervalSinceReferenceDate,
            806_281_604
        )

        let data = try JSONEncoder().encode(index)
        let encoded = String(data: data, encoding: .utf8)!
        XCTAssertFalse(encoded.contains("synthetic-private-filename"))
        XCTAssertFalse(encoded.contains("/private/synthetic"))
        XCTAssertFalse(encoded.contains("synthetic message body"))

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let chats = try XCTUnwrap(object["chats"] as? [[String: Any]])
        let group = try XCTUnwrap(chats.first { $0["kind"] as? String == "group" })
        let full = try XCTUnwrap(group["full"] as? [String: Any])
        XCTAssertEqual(full["latestAttachmentTimestamp"] as? String, "2026-07-20T23:06:44Z")
        XCTAssertTrue(group["lastReadTimestamp"] is String)
        XCTAssertTrue(group["latestActivity"] is String)
        XCTAssertTrue(full["latestReplyTimestamp"] is String)
        XCTAssertTrue(full["latestReactionEventTimestamp"] is String)
        XCTAssertTrue(full["latestEditTimestamp"] is String)
        XCTAssertTrue(full["latestRetractionTimestamp"] is String)
        let latestActivity = try XCTUnwrap(full["latestActivity"] as? [String: Any])
        XCTAssertTrue(latestActivity["timestamp"] is String)
    }

    func testDuplicateParticipantsDeduplicateButPhoneAndEmailRemainDistinct() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let group = try XCTUnwrap(
            repository().listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: .group,
                detail: .summary
            ).chats.first
        )
        XCTAssertEqual(group.participants?.count, 3)
        XCTAssertEqual(Set(group.participants?.map(\.handle) ?? []).count, 3)
    }

    func testReducedSchemaDegradesOptionalFieldsAndKeepsCoreListing() throws {
        let fixture = try ChatDatabaseFixture.reduced()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .full
        )
        let chat = try XCTUnwrap(index.chats.first)
        XCTAssertEqual(chat.displayName, "Reduced Chat")
        XCTAssertEqual(chat.participants, [])
        XCTAssertEqual(chat.participantCount, 0)
        XCTAssertNil(chat.roomName)
        XCTAssertNil(chat.isArchived)
        XCTAssertEqual(index.metadataAvailability["roomName"], false)
        XCTAssertEqual(index.metadataAvailability["archived"], false)
        XCTAssertEqual(index.metadataAvailability["attachments"], false)
        XCTAssertEqual(index.metadataAvailability["reactions"], true)
        XCTAssertNil(chat.full?.attachmentCount)
        XCTAssertEqual(chat.full?.reactionEventCount, 0)
        XCTAssertEqual(chat.full?.messageCount, 1)
    }

    func testMessageDateFallbackOrdersVariantWithoutJoinDateColumn() throws {
        let fixture = try ChatDatabaseFixture.reduced()
        defer { fixture.remove() }
        try fixture.execute(
            """
            INSERT INTO chat (ROWID, guid, display_name, service_name)
            VALUES (2, 'newer-guid.example', 'Newer Chat', 'iMessage');
            INSERT INTO message (ROWID, guid, date, is_from_me, is_read,
              is_system_message, is_service_message, is_empty, item_type,
              associated_message_type)
            VALUES (2, 'newer-message.example', 9000000000, 0, 1, 0, 0, 0, 0, 0);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (2, 2);
            """
        )
        let chats = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        ).chats
        XCTAssertEqual(chats.map(\.displayName), ["Newer Chat", "Reduced Chat"])
    }

    func testMissingMembershipMarksParticipantsUnavailableWithoutHistoryFallback() throws {
        let fixture = try ChatDatabaseFixture.identityOnly()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        )
        XCTAssertNil(index.chats.first?.participants)
        XCTAssertNil(index.chats.first?.participantCount)
        XCTAssertNil(index.chats.first?.kind)
        XCTAssertEqual(index.metadataAvailability["participants"], false)
    }

    func testMissingMinimumIdentityFailsWithRedactedError() throws {
        let fixture = try ChatDatabaseFixture.withoutSchema()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try repository().listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: nil,
                detail: .summary
            )
        ) { error in
            XCTAssertEqual(error as? MessagesChatRepositoryError, .minimumSchemaUnavailable)
            XCTAssertEqual(
                error.localizedDescription,
                "The Messages database does not expose a safe conversation identity."
            )
        }
    }

    func testQueryCountIsBoundedAndSummarySkipsFullStages() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let summaryQueries = LockedStrings()
        _ = try repository(observer: { summaryQueries.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        )
        XCTAssertEqual(summaryQueries.values, ["snapshot", "chats", "participants", "snapshot"])

        let fullQueries = LockedStrings()
        _ = try repository(observer: { fullQueries.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 1,
            kind: nil,
            detail: .full
        )
        XCTAssertEqual(
            fullQueries.values,
            ["snapshot", "chats", "participants", "messages", "attachments", "snapshot"]
        )
    }

    func testFullModeRemainsBoundedOnLargeSyntheticHistory() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        try fixture.execute(
            """
            WITH RECURSIVE sequence(value) AS (
              SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 10000
            )
            INSERT INTO message (
              ROWID, guid, date, is_from_me, service, is_delivered, is_sent,
              is_finished, error, is_read, is_system_message, is_service_message,
              is_empty, item_type, associated_message_type
            )
            SELECT 1000 + value, 'bulk-' || value || '.example',
              20000000000 + value, value % 2, 'iMessage', 0, 1, 1, 0, 1, 0, 0, 0, 0, 0
            FROM sequence;
            INSERT INTO chat_message_join (chat_id, message_id, message_date)
            SELECT 1, ROWID, date FROM message WHERE ROWID >= 1001;
            """
        )
        let start = ContinuousClock.now
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 1,
            kind: nil,
            detail: .full
        )
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(index.chats.count, 1)
        XCTAssertEqual(index.chats[0].full?.messageCount, 10001)
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    func testRepositoryDoesNotWriteOrModifySchema() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let schemaVersion = try fixture.scalar("PRAGMA schema_version")
        let messageCount = try fixture.scalar("SELECT COUNT(*) FROM message")
        _ = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .full
        )
        XCTAssertEqual(try fixture.scalar("PRAGMA schema_version"), schemaVersion)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM message"), messageCount)
    }

    func testTimeoutFailsWithStableRedactedCode() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try repository(timeout: 0).listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: nil,
                detail: .summary
            )
        ) { error in
            guard case .queryFailed(let stage, let code) = error as? MessagesChatRepositoryError
            else { return XCTFail("Expected a redacted timeout failure") }
            XCTAssertTrue(["chats-step", "cancelled-or-timeout"].contains(stage))
            XCTAssertEqual(code, SQLITE_INTERRUPT)
        }
    }

    func testIdentifierIsStableAndResolutionRejectsInvalidAndStaleValues() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let codec = MessagesChatIdentifierCodec(keyData: chatIdentifierTestKey)
        let identifier = try codec.create(for: "group-guid.example")
        XCTAssertEqual(identifier, try codec.create(for: "group-guid.example"))
        XCTAssertEqual(
            try repository().resolveChatIdentifier(identifier, databasePath: fixture.path),
            "group-guid.example"
        )
        XCTAssertThrowsError(
            try repository().resolveChatIdentifier("invalid", databasePath: fixture.path)
        ) { XCTAssertEqual($0 as? MessagesChatRepositoryError, .invalidIdentifier) }
        let stale = try codec.create(for: "stale-guid.example")
        XCTAssertThrowsError(try repository().resolveChatIdentifier(stale, databasePath: fixture.path)) {
            XCTAssertEqual($0 as? MessagesChatRepositoryError, .staleIdentifier)
        }
    }

    func testToolDefaultsToSummaryAndValidatesDetail() async throws {
        let recording = RecordingChatRepository()
        let tool = try chatTool(repository: recording)
        _ = try await tool([:], context: ToolCallContext(elicitation: UnsupportedElicitation()))
        _ = try await tool(
            ["limit": .int(100), "kind": .string("group"), "detail": .string("full")],
            context: ToolCallContext(elicitation: UnsupportedElicitation())
        )
        XCTAssertEqual(
            recording.requests,
            [.init(limit: 30, kind: nil, detail: .summary), .init(limit: 100, kind: .group, detail: .full)]
        )

        for arguments: [String: Value] in [
            ["limit": .int(0)], ["limit": .int(101)], ["kind": .string("unknown")],
            ["detail": .string("verbose")],
        ] {
            do {
                _ = try await tool(arguments, context: ToolCallContext(elicitation: UnsupportedElicitation()))
                XCTFail("Expected invalid conversation-index arguments to fail")
            } catch is MessagesChatListingError {}
        }
        XCTAssertEqual(recording.requests.count, 2)
    }

    func testExistingFetchAndSendContractsRemainUnchanged() throws {
        let service = MessageService(
            sender: NonDispatchingSender(),
            chatRepository: RecordingChatRepository(),
            chatDatabasePathOverride: "/synthetic/chat.db"
        )
        let list = try XCTUnwrap(service.tools.first { $0.name == "messages_list_chats" })
        let fetch = try XCTUnwrap(service.tools.first { $0.name == "messages_fetch" })
        let send = try XCTUnwrap(service.tools.first { $0.name == "messages_send" })
        XCTAssertEqual(list.annotations.readOnlyHint, true)
        XCTAssertEqual(fetch.annotations.readOnlyHint, true)
        XCTAssertEqual(send.annotations.readOnlyHint, false)
        XCTAssertEqual(send.annotations.idempotentHint, false)

        let encoder = JSONEncoder()
        let fetchSchema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(fetch.inputSchema)) as? [String: Any]
        )
        let sendSchema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(send.inputSchema)) as? [String: Any]
        )
        XCTAssertEqual(
            Set((fetchSchema["properties"] as? [String: Any] ?? [:]).keys),
            Set(["participants", "start", "end", "query", "limit"])
        )
        XCTAssertEqual(Set((sendSchema["properties"] as? [String: Any] ?? [:]).keys), Set(["recipient", "body"]))
    }

    private func repository(
        timeout: TimeInterval = 5,
        observer: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SQLiteMessagesChatRepository {
        SQLiteMessagesChatRepository(
            identifierKey: chatIdentifierTestKey,
            timeout: timeout,
            queryObserver: observer
        )
    }

    private func chatTool(repository: RecordingChatRepository) throws -> iMCP.Tool {
        let service = MessageService(
            sender: NonDispatchingSender(),
            chatRepository: repository,
            chatDatabasePathOverride: "/synthetic/chat.db",
            chatListingLog: { _ in }
        )
        return try XCTUnwrap(service.tools.first { $0.name == "messages_list_chats" })
    }
}

private struct RecordedRequest: Equatable {
    let limit: Int
    let kind: MessagesChatKind?
    let detail: MessagesChatDetail
}

private final class RecordingChatRepository: MessagesChatListing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [RecordedRequest] = []
    var requests: [RecordedRequest] { lock.withLock { storedRequests } }

    func listChats(
        databasePath: String,
        limit: Int,
        kind: MessagesChatKind?,
        detail: MessagesChatDetail
    ) throws -> MessagesConversationIndex {
        lock.withLock { storedRequests.append(.init(limit: limit, kind: kind, detail: detail)) }
        return MessagesConversationIndex(detail: detail, metadataAvailability: [:], chats: [])
    }

    func resolveChatIdentifier(_ identifier: String, databasePath: String) throws -> String {
        try MessagesChatIdentifierCodec(keyData: chatIdentifierTestKey).validate(identifier)
        return "synthetic-guid.example"
    }
}

private struct NonDispatchingSender: MessagesSending {
    func submit(recipient: String, body: String) throws {
        XCTFail("Conversation indexing must not dispatch a message")
    }
}

private struct UnsupportedElicitation: ElicitationRequester {
    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        throw ElicitationRequestError.formUnsupported
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}

private struct ChatDatabaseFixture {
    let directory: URL
    var path: String { directory.appendingPathComponent("chat.db").path }

    static func withoutSchema() throws -> ChatDatabaseFixture {
        let fixture = ChatDatabaseFixture(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        )
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(fixture.path, &database) == SQLITE_OK, let database else {
            throw MessagesChatRepositoryError.databaseUnavailable(code: SQLITE_CANTOPEN)
        }
        sqlite3_close(database)
        return fixture
    }

    static func identityOnly() throws -> ChatDatabaseFixture {
        let fixture = try withoutSchema()
        try fixture.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT NOT NULL, display_name TEXT);
            INSERT INTO chat VALUES (1, 'identity-only-guid.example', 'Identity Only');
            """
        )
        return fixture
    }

    static func reduced() throws -> ChatDatabaseFixture {
        let fixture = try withoutSchema()
        try fixture.execute(
            """
            CREATE TABLE chat (
              ROWID INTEGER PRIMARY KEY, guid TEXT NOT NULL, display_name TEXT, service_name TEXT
            );
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT NOT NULL);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (
              ROWID INTEGER PRIMARY KEY, guid TEXT NOT NULL, date INTEGER, is_from_me INTEGER,
              is_read INTEGER, is_system_message INTEGER, is_service_message INTEGER,
              is_empty INTEGER, item_type INTEGER, associated_message_type INTEGER
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            INSERT INTO chat VALUES (1, 'reduced-guid.example', 'Reduced Chat', 'iMessage');
            INSERT INTO message VALUES
              (1, 'reduced-message.example', 1000000000, 0, 1, 0, 0, 0, 0, 0);
            INSERT INTO chat_message_join VALUES (1, 1);
            """
        )
        return fixture
    }

    static func full() throws -> ChatDatabaseFixture {
        let fixture = try withoutSchema()
        try fixture.execute(fullSchema)
        try fixture.execute(fullData)
        return fixture
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw MessagesChatRepositoryError.databaseUnavailable(code: SQLITE_CANTOPEN)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MessagesChatRepositoryError.queryFailed(
                stage: "fixture",
                code: sqlite3_extended_errcode(database)
            )
        }
    }

    func scalar(_ sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else { throw MessagesChatRepositoryError.databaseUnavailable(code: SQLITE_CANTOPEN) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw MessagesChatRepositoryError.queryFailed(
                stage: "fixture-scalar",
                code: sqlite3_extended_errcode(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MessagesChatRepositoryError.queryFailed(
                stage: "fixture-scalar",
                code: sqlite3_extended_errcode(database)
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static let fullSchema = """
        CREATE TABLE chat (
          ROWID INTEGER PRIMARY KEY, guid TEXT NOT NULL, chat_identifier TEXT, group_id TEXT,
          original_group_id TEXT, room_name TEXT, display_name TEXT, service_name TEXT,
          is_archived INTEGER, is_filtered INTEGER, last_read_message_timestamp INTEGER
        );
        CREATE TABLE handle (
          ROWID INTEGER PRIMARY KEY, id TEXT NOT NULL, uncanonicalized_id TEXT,
          service TEXT, country TEXT
        );
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE message (
          ROWID INTEGER PRIMARY KEY, guid TEXT NOT NULL, date INTEGER, is_from_me INTEGER,
          service TEXT, is_delivered INTEGER, is_sent INTEGER, is_finished INTEGER,
          error INTEGER, is_read INTEGER, is_system_message INTEGER,
          is_service_message INTEGER, is_empty INTEGER, item_type INTEGER,
          associated_message_type INTEGER, reply_to_guid TEXT, date_edited INTEGER,
          date_retracted INTEGER, expressive_send_style_id TEXT, balloon_bundle_id TEXT
        );
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
        CREATE TABLE attachment (
          ROWID INTEGER PRIMARY KEY, guid TEXT, created_date INTEGER, mime_type TEXT,
          filename TEXT, transfer_name TEXT, is_sticker INTEGER
        );
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        """

    private static let fullData = """
        INSERT INTO chat VALUES
          (1, 'direct-guid.example', 'direct@example.invalid', NULL, NULL, NULL,
           'Direct Thread', 'iMessage', 0, 0, 1000000000),
          (2, 'group-guid.example', 'group-identifier.example', 'group-id.example',
           'original-group-id.example', 'Synthetic Room', 'Synthetic Group',
           'iMessage', 1, 0, 2000000000);
        INSERT INTO handle VALUES
          (1, 'direct@example.invalid', NULL, 'iMessage', NULL),
          (2, '+15550100001', '(555) 010-0001', 'iMessage', 'US'),
          (3, 'person@example.invalid', NULL, 'iMessage', 'US'),
          (4, 'local-number', '5550100002', 'SMS', 'US');
        INSERT INTO chat_handle_join VALUES
          (1, 1), (2, 2), (2, 2), (2, 3), (2, 4);
        INSERT INTO message VALUES
          (1, 'direct-message.example', 1000000000, 0, 'iMessage', 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, NULL, NULL, NULL, NULL, NULL),
          (10, 'incoming-message.example', 2000000000, 0, 'iMessage', 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, NULL, NULL, NULL, NULL, NULL),
          (11, 'outgoing-message.example', 3000000000, 1, 'iMessage', 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, NULL, NULL, NULL, NULL, NULL),
          (12, 'pending-message.example', 4000000000, 1, 'iMessage', 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, NULL, NULL, NULL, NULL, NULL),
          (13, 'failed-message.example', 5000000000, 1, 'iMessage', 0, 0, 1, 7, 1, 0, 0, 0, 0, 0, NULL, NULL, NULL, NULL, NULL),
          (14, 'reaction-add.example', 6000000000, 0, 'iMessage', 0, 0, 1, 0, 1, 0, 0, 0, 0, 2006, NULL, NULL, NULL, NULL, NULL),
          (15, 'reaction-remove.example', 7000000000, 0, 'iMessage', 0, 0, 1, 0, 1, 0, 0, 0, 0, 3006, NULL, NULL, NULL, NULL, NULL),
          (16, 'reply-message.example', 8000000000, 0, 'iMessage', 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 'incoming-message.example', NULL, NULL, NULL, NULL),
          (17, 'edited-message.example', 9000000000, 0, 'iMessage', 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, NULL, 9500000000, NULL, NULL, NULL),
          (18, 'effect-message.example', 10000000000, 0, 'iMessage', 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, NULL, NULL, NULL, 'effect.example', NULL),
          (19, 'plugin-message.example', 11000000000, 0, 'iMessage', 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, NULL, NULL, NULL, NULL, 'plugin.example'),
          (20, 'retracted-message.example', 12000000000, 0, 'iMessage', 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, NULL, NULL, 12500000000, NULL, NULL),
          (21, 'system-event.example', 13000000000, 0, 'iMessage', 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, NULL, NULL, NULL, NULL, NULL);
        INSERT INTO chat_message_join VALUES
          (1, 1, 1000000000),
          (2, 10, 2000000000), (2, 11, 3000000000), (2, 12, 4000000000),
          (2, 13, 5000000000), (2, 14, 6000000000), (2, 15, 7000000000),
          (2, 16, 8000000000), (2, 17, 9000000000), (2, 17, 9000000000),
          (2, 18, 10000000000), (2, 19, 11000000000), (2, 20, 12000000000),
          (2, 21, 13000000000);
        INSERT INTO attachment VALUES
          (1, 'attachment-one.example', 806281603, 'image/png',
           '/private/synthetic-private-filename.png', 'synthetic-private-filename.png', 1),
          (2, 'attachment-two.example', 806281604, NULL,
           '/private/synthetic-private-filename.bin', 'synthetic-private-filename.bin', 0);
        INSERT INTO message_attachment_join VALUES (19, 1), (19, 1), (19, 2);
        """
}

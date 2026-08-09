import Foundation
import SQLite3

@testable import iMCP

/// Records the query stages a repository reported, so tests can assert how much database
/// work a request performed.
final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}

/// A synthetic Messages database. Every value is unmistakably fake; no fixture may contain
/// real handles, names, or message content.
struct ChatDatabaseFixture {
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

    /// Exercises one remote identity observed through several `handle` rows and
    /// relationship rows, alongside a genuine group and a nonmatchable stored handle.
    static func participantIdentity() throws -> ChatDatabaseFixture {
        let fixture = try withoutSchema()
        try fixture.execute(fullSchema)
        try fixture.execute(
            """
            INSERT INTO chat VALUES
              (1, 'case-guid.example', 'person@example.invalid', NULL, NULL, NULL,
               'Case Duplicate', 'iMessage', 0, 0, NULL),
              (2, 'e164-guid.example', '+15550100001', NULL, NULL, NULL,
               'E164 Duplicate', 'SMS', 0, 0, NULL),
              (3, 'metadata-guid.example', 'meta@example.invalid', NULL, NULL, NULL,
               'Metadata Duplicate', 'iMessage', 0, 0, NULL),
              (4, 'group-guid.example', 'chat123', NULL, NULL, 'Group Room',
               'Real Group', 'iMessage', 0, 0, NULL),
              (5, 'relationship-guid.example', '+15550100002', NULL, NULL, NULL,
               'Relationship Duplicate', 'iMessage', 0, 0, NULL),
              (6, 'shortcode-guid.example', 'SHORTCODE', NULL, NULL, NULL,
               'Short Code', 'SMS', 0, 0, NULL),
              (7, 'local-format-guid.example', '(555) 010-0009', NULL, NULL, NULL,
               'Local Format', 'SMS', 0, 0, NULL);

            INSERT INTO handle VALUES
              (1, 'Person@Example.invalid', 'Person@Example.invalid', 'iMessage', 'us'),
              (2, 'person@example.invalid', NULL, 'SMS', 'ca'),
              (3, '+15550100001', '+15550100001', 'SMS', 'us'),
              (4, '+15550100001', '(555) 010-0001', 'iMessage', 'us'),
              (5, 'meta@example.invalid', 'meta@example.invalid', 'iMessage', 'us'),
              (6, 'meta@example.invalid', 'META@example.invalid', 'SMS', 'gb'),
              (7, 'first@example.invalid', NULL, 'iMessage', 'us'),
              (8, 'second@example.invalid', NULL, 'iMessage', 'us'),
              (9, '+15550100002', NULL, 'iMessage', 'us'),
              (10, 'SHORTCODE', NULL, 'SMS', 'us'),
              (11, '(555) 010-0009', NULL, 'SMS', 'us');

            INSERT INTO chat_handle_join VALUES
              (1, 1), (1, 2),
              (2, 3), (2, 4),
              (3, 5), (3, 6),
              (4, 7), (4, 8),
              (5, 9), (5, 9), (5, 9),
              (6, 10),
              (7, 11);
            """
        )
        return fixture
    }

    /// Identities that SQL text folding would classify differently from Swift, plus ordered
    /// data for exercising internal filtered paging.
    ///
    /// With no message-join rows every `latestActivity` is null, so ordering is `ROWID`
    /// descending: 8, 7, 6, 5, 4, 3, 2, 1.
    static func identityAndPaging() throws -> ChatDatabaseFixture {
        let fixture = try withoutSchema()
        try fixture.execute(fullSchema)
        try fixture.execute(
            """
            INSERT INTO chat VALUES
              (1, 'tail-direct-guid.example', 'tail', NULL, NULL, NULL,
               'Tail Direct', 'SMS', 0, 0, NULL),
              (2, 'case-group-guid.example', 'casegroup', NULL, NULL, NULL,
               'Case Group', 'SMS', 0, 0, NULL),
              (3, 'whitespace-direct-guid.example', 'whitespace', NULL, NULL, NULL,
               'Whitespace Direct', 'SMS', 0, 0, NULL),
              (4, 'email-case-guid.example', 'emailcase', NULL, NULL, NULL,
               'Email Case Direct', 'iMessage', 0, 0, NULL),
              (5, 'filler-direct-a-guid.example', 'fillera', NULL, NULL, NULL,
               'Filler A', 'SMS', 0, 0, NULL),
              (6, 'filler-direct-b-guid.example', 'fillerb', NULL, NULL, NULL,
               'Filler B', 'SMS', 0, 0, NULL),
              (7, 'filler-direct-c-guid.example', 'fillerc', NULL, NULL, NULL,
               'Filler C', 'SMS', 0, 0, NULL),
              (8, 'filler-direct-d-guid.example', 'fillerd', NULL, NULL, NULL,
               'Filler D', 'SMS', 0, 0, NULL);

            INSERT INTO handle VALUES
              -- Two case-distinct non-email handles: one identity in SQL, two in Swift.
              (1, 'BOT', NULL, 'SMS', 'us'),
              (2, 'bot', NULL, 'SMS', 'us'),
              -- Tab and newline padding that SQLite TRIM would not strip, spelled with
              -- char() so reformatting cannot alter the stored bytes.
              (3, ' padded ', NULL, 'SMS', 'us'),
              (4, char(9) || 'padded' || char(10), NULL, 'SMS', 'us'),
              -- Case-different emails: one identity in both.
              (5, 'Person@example.invalid', NULL, 'iMessage', 'us'),
              (6, 'person@example.invalid', NULL, 'iMessage', 'us'),
              (7, 'filler-a@example.invalid', NULL, 'SMS', 'us'),
              (8, 'filler-b@example.invalid', NULL, 'SMS', 'us'),
              (9, 'filler-c@example.invalid', NULL, 'SMS', 'us'),
              (10, 'filler-d@example.invalid', NULL, 'SMS', 'us'),
              (11, 'tail@example.invalid', NULL, 'SMS', 'us');

            INSERT INTO chat_handle_join VALUES
              (2, 1), (2, 2),
              (3, 3), (3, 4),
              (4, 5), (4, 6),
              (5, 7), (6, 8), (7, 9), (8, 10),
              (1, 11);
            """
        )
        return fixture
    }

    /// Conversations for exercising handle-oriented discovery: one handle present in a
    /// direct thread and three groups, a second handle sharing one of those groups, an
    /// unrelated conversation, and a stored phone number kept in a local format that cannot
    /// be compared exactly against E.164.
    ///
    /// Activity descends Direct B, Direct A, Group One, Group Two, Group Three, Local
    /// Format, Direct C; Unrelated has no activity and sorts last by `ROWID`. Only
    /// `chat_message_join.message_date` establishes that order, so no `message` rows are
    /// needed and no message query runs.
    static func conversationSearch() throws -> ChatDatabaseFixture {
        let fixture = try withoutSchema()
        try fixture.execute(fullSchema)
        try fixture.execute(
            """
            INSERT INTO chat VALUES
              (1, 'search-direct-a-guid.example', '+15550100001', NULL, NULL, NULL,
               'Direct A', 'iMessage', 0, 0, NULL),
              (2, 'search-group-one-guid.example', 'chat-group-one.example', NULL, NULL,
               'Room One', 'Group One', 'iMessage', 0, 0, NULL),
              (3, 'search-group-two-guid.example', 'chat-group-two.example', NULL, NULL,
               NULL, 'Group Two', 'iMessage', 0, 0, NULL),
              (4, 'search-direct-b-guid.example', 'person@example.invalid', NULL, NULL, NULL,
               'Direct B', 'iMessage', 0, 0, NULL),
              (5, 'search-group-three-guid.example', 'chat-group-three.example', NULL, NULL,
               NULL, 'Group Three', 'SMS', 0, 0, NULL),
              (6, 'search-local-format-guid.example', '(555) 010-0009', NULL, NULL, NULL,
               'Local Format', 'SMS', 0, 0, NULL),
              (7, 'search-unrelated-guid.example', '+15550100005', NULL, NULL, NULL,
               'Unrelated', 'iMessage', 0, 0, NULL),
              (8, 'search-direct-c-guid.example', '+15550100009', NULL, NULL, NULL,
               'Direct C', 'SMS', 0, 0, NULL);

            INSERT INTO handle VALUES
              (1, '+15550100001', '(555) 010-0001', 'iMessage', 'US'),
              (2, 'person@example.invalid', NULL, 'iMessage', 'US'),
              (3, '+15550100002', NULL, 'iMessage', 'US'),
              (4, '+15550100003', NULL, 'iMessage', 'US'),
              (5, '+15550100004', NULL, 'SMS', 'US'),
              (6, '(555) 010-0009', NULL, 'SMS', 'US'),
              (7, '+15550100005', NULL, 'iMessage', 'US'),
              (8, '+15550100009', NULL, 'SMS', 'US');

            INSERT INTO chat_handle_join VALUES
              (1, 1),
              (2, 1), (2, 2), (2, 3),
              (3, 1), (3, 4),
              (4, 2),
              (5, 1), (5, 5),
              (6, 6),
              (7, 7),
              (8, 8);

            INSERT INTO chat_message_join VALUES
              (1, 101, 5000000000),
              (2, 102, 4000000000),
              (3, 103, 3000000000),
              (4, 104, 6000000000),
              (5, 105, 2000000000),
              (6, 106, 1000000000),
              (8, 108, 500000000);
            """
        )
        return fixture
    }

    /// Relationship rows exist but `handle.id` does not, so no readable remote handle text
    /// is available and participant identity cannot be derived at all.
    static func unreadableHandles() throws -> ChatDatabaseFixture {
        let fixture = try withoutSchema()
        try fixture.execute(
            """
            CREATE TABLE chat (
              ROWID INTEGER PRIMARY KEY, guid TEXT NOT NULL, chat_identifier TEXT,
              display_name TEXT, service_name TEXT
            );
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, service TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES
              (1, 'unreadable-guid.example', 'unreadable', 'Unreadable Handles', 'SMS');
            INSERT INTO handle VALUES (1, 'SMS'), (2, 'SMS');
            -- Two handle rows and a duplicate relationship row. None of these may become a
            -- participant count.
            INSERT INTO chat_handle_join VALUES (1, 1), (1, 2), (1, 2);
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

import CryptoKit
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MessagesChatKind: String, Codable, Sendable {
    case direct
    case group
}

enum MessagesChatDetail: String, Codable, Sendable {
    case summary
    case full
}

/// One remote participant, keyed by its normalized identity.
///
/// Several `handle` rows can describe the same remote identity — duplicate relationship
/// rows, differing letter case in an email, or the same handle observed on more than one
/// service. Those collapse into a single participant. `handle` is the normalized identity;
/// `originalHandle`, `service`, and `country` expose the lexicographically first observed
/// value so output is deterministic, and the plural fields appear only when more than one
/// distinct value was observed for that identity.
struct MessagesParticipant: Encodable, Equatable, Hashable, Sendable {
    let handle: String
    let originalHandle: String?
    let canonicalE164: String?
    let email: String?
    let service: String?
    let country: String?
    var originalHandles: [String]?
    var services: [String]?
    var countries: [String]?
}

struct MessagesActivityRecord: Encodable, Equatable, Sendable {
    let messageGuid: String
    let timestamp: Date
    let direction: String
    let service: String?
    let hasAttachments: Bool
    let deliveryState: String?

    private enum CodingKeys: String, CodingKey {
        case messageGuid
        case timestamp
        case direction
        case service
        case hasAttachments
        case deliveryState
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageGuid, forKey: .messageGuid)
        try container.encode(timestamp.formatted(.iso8601), forKey: .timestamp)
        try container.encode(direction, forKey: .direction)
        try container.encode(service, forKey: .service)
        try container.encode(hasAttachments, forKey: .hasAttachments)
        try container.encode(deliveryState, forKey: .deliveryState)
    }
}

struct MessagesChatFullMetadata: Encodable, Equatable, Sendable {
    var latestActivity: MessagesActivityRecord?
    var latestIncomingMessage: MessagesActivityRecord?
    var latestOutgoingMessage: MessagesActivityRecord?
    var messageCount: Int?
    var incomingMessageCount: Int?
    var outgoingMessageCount: Int?
    var unreadIncomingCount: Int?
    var failedOutgoingCount: Int?
    var hasAttachments: Bool?
    var attachmentCount: Int?
    var messagesWithAttachmentsCount: Int?
    var latestAttachmentTimestamp: Date?
    var attachmentCountByMediaCategory: [String: Int]?
    var stickerAttachmentCount: Int?
    var replyCount: Int?
    var latestReplyTimestamp: Date?
    var reactionEventCount: Int?
    var reactionAddCount: Int?
    var reactionRemoveCount: Int?
    var latestReactionEventTimestamp: Date?
    var editedMessageCount: Int?
    var latestEditTimestamp: Date?
    var retractionCount: Int?
    var latestRetractionTimestamp: Date?
    var mentionCount: Int?
    var expressiveEffectMessageCount: Int?
    var pluginMessageCount: Int?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case latestActivity
        case latestIncomingMessage
        case latestOutgoingMessage
        case messageCount
        case incomingMessageCount
        case outgoingMessageCount
        case unreadIncomingCount
        case failedOutgoingCount
        case hasAttachments
        case attachmentCount
        case messagesWithAttachmentsCount
        case latestAttachmentTimestamp
        case attachmentCountByMediaCategory
        case stickerAttachmentCount
        case replyCount
        case latestReplyTimestamp
        case reactionEventCount
        case reactionAddCount
        case reactionRemoveCount
        case latestReactionEventTimestamp
        case editedMessageCount
        case latestEditTimestamp
        case retractionCount
        case latestRetractionTimestamp
        case mentionCount
        case expressiveEffectMessageCount
        case pluginMessageCount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latestActivity, forKey: .latestActivity)
        try container.encode(latestIncomingMessage, forKey: .latestIncomingMessage)
        try container.encode(latestOutgoingMessage, forKey: .latestOutgoingMessage)
        try container.encode(messageCount, forKey: .messageCount)
        try container.encode(incomingMessageCount, forKey: .incomingMessageCount)
        try container.encode(outgoingMessageCount, forKey: .outgoingMessageCount)
        try container.encode(unreadIncomingCount, forKey: .unreadIncomingCount)
        try container.encode(failedOutgoingCount, forKey: .failedOutgoingCount)
        try container.encode(hasAttachments, forKey: .hasAttachments)
        try container.encode(attachmentCount, forKey: .attachmentCount)
        try container.encode(messagesWithAttachmentsCount, forKey: .messagesWithAttachmentsCount)
        try container.encode(
            latestAttachmentTimestamp?.formatted(.iso8601),
            forKey: .latestAttachmentTimestamp
        )
        try container.encode(
            attachmentCountByMediaCategory,
            forKey: .attachmentCountByMediaCategory
        )
        try container.encode(stickerAttachmentCount, forKey: .stickerAttachmentCount)
        try container.encode(replyCount, forKey: .replyCount)
        try container.encode(
            latestReplyTimestamp?.formatted(.iso8601),
            forKey: .latestReplyTimestamp
        )
        try container.encode(reactionEventCount, forKey: .reactionEventCount)
        try container.encode(reactionAddCount, forKey: .reactionAddCount)
        try container.encode(reactionRemoveCount, forKey: .reactionRemoveCount)
        try container.encode(
            latestReactionEventTimestamp?.formatted(.iso8601),
            forKey: .latestReactionEventTimestamp
        )
        try container.encode(editedMessageCount, forKey: .editedMessageCount)
        try container.encode(
            latestEditTimestamp?.formatted(.iso8601),
            forKey: .latestEditTimestamp
        )
        try container.encode(retractionCount, forKey: .retractionCount)
        try container.encode(
            latestRetractionTimestamp?.formatted(.iso8601),
            forKey: .latestRetractionTimestamp
        )
        try container.encode(mentionCount, forKey: .mentionCount)
        try container.encode(
            expressiveEffectMessageCount,
            forKey: .expressiveEffectMessageCount
        )
        try container.encode(pluginMessageCount, forKey: .pluginMessageCount)
    }
}

struct MessagesChat: Encodable, Equatable, Sendable {
    let id: String
    let chatId: String
    let chatGuid: String
    let chatIdentifier: String?
    let groupId: String?
    let originalGroupId: String?
    let roomName: String?
    let displayName: String?
    let kind: MessagesChatKind?
    let participantCount: Int?
    let participants: [MessagesParticipant]?
    let service: String?
    let isArchived: Bool?
    let isFiltered: Bool?
    let lastReadTimestamp: Date?
    let latestActivity: Date?
    var full: MessagesChatFullMetadata?

    private enum CodingKeys: String, CodingKey {
        case id
        case chatId
        case chatGuid
        case chatIdentifier
        case groupId
        case originalGroupId
        case roomName
        case displayName
        case kind
        case participantCount
        case participants
        case service
        case isArchived
        case isFiltered
        case lastReadTimestamp
        case latestActivity
        case full
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(chatId, forKey: .chatId)
        try container.encode(chatGuid, forKey: .chatGuid)
        try container.encode(chatIdentifier, forKey: .chatIdentifier)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(originalGroupId, forKey: .originalGroupId)
        try container.encode(roomName, forKey: .roomName)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kind, forKey: .kind)
        try container.encode(participantCount, forKey: .participantCount)
        try container.encode(participants, forKey: .participants)
        try container.encode(service, forKey: .service)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(isFiltered, forKey: .isFiltered)
        try container.encode(
            lastReadTimestamp?.formatted(.iso8601),
            forKey: .lastReadTimestamp
        )
        try container.encode(
            latestActivity?.formatted(.iso8601),
            forKey: .latestActivity
        )
        try container.encodeIfPresent(full, forKey: .full)
    }
}

struct MessagesConversationIndex: Encodable, Equatable, Sendable {
    let detail: MessagesChatDetail
    var metadataAvailability: [String: Bool]
    var chats: [MessagesChat]
}

struct MessagesResolvedChatDestination: Equatable, Sendable {
    let chatGuid: String
    let displayName: String?
    let roomName: String?
    let kind: MessagesChatKind
    let participantCount: Int
    let participantHandles: [String]
    let service: String?
}

enum MessagesConversationMatch: Equatable, Sendable {
    case none
    case unique(publicChatID: String, destination: MessagesResolvedChatDestination)
    case ambiguous
    case incomplete
}

/// The single definition of remote-handle identity used for counting participants and for
/// classifying a conversation as direct or group.
///
/// Every stored handle that carries a value yields exactly one identity, so a handle that
/// is neither E.164 nor an email is still a participant rather than being silently dropped.
/// No country code is inferred and no value is reinterpreted as another identity.
enum MessagesHandleIdentity {
    static func identity(_ handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.wholeMatch(of: /^\+[1-9][0-9]{1,14}$/) != nil { return trimmed }
        if trimmed.wholeMatch(of: /^[^\s@]+@[^\s@]+\.[^\s@]+$/) != nil {
            return trimmed.lowercased()
        }
        return trimmed
    }
}

/// The stricter identity rule used only for send matching.
///
/// Matching a destination must not act on a handle it cannot exactly compare, so anything
/// that is not valid E.164 or a syntactically valid email yields `nil`. Callers treat that
/// as incomplete membership rather than ignoring the participant.
enum MessagesHandleNormalization {
    static func normalize(_ handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.wholeMatch(of: /^\+[1-9][0-9]{1,14}$/) != nil { return trimmed }
        if trimmed.wholeMatch(of: /^[^\s@]+@[^\s@]+\.[^\s@]+$/) != nil {
            return trimmed.lowercased()
        }
        return nil
    }
}

func messagesHandleIsE164(_ value: String) -> Bool {
    value.range(of: #"^\+[1-9][0-9]{1,14}$"#, options: .regularExpression) != nil
}

func messagesHandleIsEmail(_ value: String) -> Bool {
    value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
}

/// Accumulates every stored observation of one remote identity within a conversation and
/// folds them into a single deterministic participant.
struct ParticipantObservations {
    let identity: String
    private var originals: Set<String> = []
    private var services: Set<String> = []
    private var countries: Set<String> = []

    init(identity: String) {
        self.identity = identity
    }

    mutating func observe(original: String?, service: String?, country: String?) {
        if let original, !original.isEmpty { originals.insert(original) }
        if let service, !service.isEmpty { services.insert(service) }
        if let country, !country.isEmpty { countries.insert(country) }
    }

    func participant() -> MessagesParticipant {
        MessagesParticipant(
            handle: identity,
            originalHandle: originals.min(),
            canonicalE164: messagesHandleIsE164(identity) ? identity : nil,
            email: messagesHandleIsEmail(identity) ? identity : nil,
            service: services.min(),
            country: countries.min(),
            originalHandles: originals.count > 1 ? originals.sorted() : nil,
            services: services.count > 1 ? services.sorted() : nil,
            countries: countries.count > 1 ? countries.sorted() : nil
        )
    }
}

struct MessagesSchemaCapabilities: Equatable, Sendable {
    let columnsByTable: [String: Set<String>]
    let indexesByTable: [String: Set<String>]

    func hasTable(_ table: String) -> Bool { columnsByTable[table] != nil }
    func hasColumn(_ column: String, in table: String) -> Bool {
        columnsByTable[table]?.contains(column) == true
    }

    static func discover(in database: OpaquePointer) throws -> MessagesSchemaCapabilities {
        let trustedTables = [
            "chat", "handle", "message", "chat_handle_join", "chat_message_join",
            "attachment", "message_attachment_join",
        ]
        var columns: [String: Set<String>] = [:]
        var indexes: [String: Set<String>] = [:]
        for table in trustedTables {
            var columnNames: Set<String> = []
            try rows("PRAGMA table_info('\(table)')", database: database) { statement in
                if let name = sqliteText(statement, column: 1) { columnNames.insert(name) }
            }
            if !columnNames.isEmpty { columns[table] = columnNames }

            var indexNames: Set<String> = []
            try rows("PRAGMA index_list('\(table)')", database: database) { statement in
                if let name = sqliteText(statement, column: 1) { indexNames.insert(name) }
            }
            if !indexNames.isEmpty { indexes[table] = indexNames }
        }
        return MessagesSchemaCapabilities(columnsByTable: columns, indexesByTable: indexes)
    }
}

enum MessagesChatRepositoryError: LocalizedError, Equatable, Sendable {
    case invalidIdentifier
    case staleIdentifier
    case minimumSchemaUnavailable
    case databaseUnavailable(code: Int32)
    case queryFailed(stage: String, code: Int32)

    var diagnosticStage: String {
        switch self {
        case .invalidIdentifier: "identifier-validation"
        case .staleIdentifier: "identifier-resolution"
        case .minimumSchemaUnavailable: "schema-minimum"
        case .databaseUnavailable: "open"
        case .queryFailed(let stage, _): stage
        }
    }

    var sqliteCode: Int32 {
        switch self {
        case .databaseUnavailable(let code), .queryFailed(_, let code): code
        case .invalidIdentifier, .staleIdentifier, .minimumSchemaUnavailable: SQLITE_OK
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The chat identifier is invalid."
        case .staleIdentifier: "The chat identifier no longer resolves to an existing conversation."
        case .minimumSchemaUnavailable:
            "The Messages database does not expose a safe conversation identity."
        case .databaseUnavailable: "The Messages database is unavailable."
        case .queryFailed: "The Messages conversations query failed."
        }
    }
}

struct MessagesChatIdentifierCodec: Sendable {
    private static let prefix = "imcp-chat-v1_"
    private let key: SymmetricKey

    init(keyData: Data) { self.key = SymmetricKey(data: keyData) }

    func create(for chatGUID: String) throws -> String {
        guard Self.isValidGUID(chatGUID) else {
            throw MessagesChatRepositoryError.invalidIdentifier
        }
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(chatGUID.utf8),
            using: key
        )
        let encoded = Data(authenticationCode).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + encoded
    }

    func validate(_ identifier: String) throws {
        guard identifier.hasPrefix(Self.prefix) else {
            throw MessagesChatRepositoryError.invalidIdentifier
        }
        var encoded = String(identifier.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count == SHA256.Digest.byteCount,
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
                == identifier.dropFirst(Self.prefix.count)
        else { throw MessagesChatRepositoryError.invalidIdentifier }
    }

    private static func isValidGUID(_ guid: String) -> Bool {
        !guid.isEmpty && guid.utf8.count <= 1024
            && guid.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

private enum MessagesChatIdentifierKeyStore {
    private static let keyName = "me.mattt.iMCP.messagesChatIdentifierKey.v1"
    static func loadOrCreate() -> Data {
        if let storedKey = UserDefaults.standard.data(forKey: keyName), storedKey.count == 32 {
            return storedKey
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        UserDefaults.standard.set(key, forKey: keyName)
        return key
    }
}

protocol MessagesChatListing: Sendable {
    func listChats(
        databasePath: String,
        limit: Int,
        kind: MessagesChatKind?,
        participants: Set<String>?,
        detail: MessagesChatDetail
    ) throws -> MessagesConversationIndex
    func resolveChatIdentifier(_ identifier: String, databasePath: String) throws -> String
    func resolveChatDestination(
        _ identifier: String,
        databasePath: String
    ) throws -> MessagesResolvedChatDestination
    func matchConversation(
        normalizedParticipants: Set<String>,
        kind: MessagesChatKind,
        databasePath: String
    ) throws -> MessagesConversationMatch
}

extension MessagesChatListing {
    func matchConversation(
        normalizedParticipants: Set<String>,
        kind: MessagesChatKind,
        databasePath: String
    ) throws -> MessagesConversationMatch {
        .none
    }
}

struct SQLiteMessagesChatRepository: MessagesChatListing {
    private let identifierCodec: MessagesChatIdentifierCodec
    private let timeout: TimeInterval
    private let queryObserver: @Sendable (String) -> Void

    private let filterPageSize: Int

    init(
        identifierKey: Data = MessagesChatIdentifierKeyStore.loadOrCreate(),
        timeout: TimeInterval = 5,
        filterPageSize: Int = SQLiteMessagesChatRepository.defaultFilterPageSize,
        queryObserver: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.identifierCodec = MessagesChatIdentifierCodec(keyData: identifierKey)
        self.timeout = timeout
        self.filterPageSize = max(1, filterPageSize)
        self.queryObserver = queryObserver
    }

    /// Rows per internal page when scanning for a `kind`-filtered result.
    ///
    /// This bounds the size of each round trip, not the total scan. A filtered request
    /// keeps paging until the caller's limit is filled or the source is exhausted; the
    /// query deadline and cancellation are the only global bound.
    static let defaultFilterPageSize = 100

    func listChats(
        databasePath: String,
        limit: Int,
        kind: MessagesChatKind?,
        participants: Set<String>? = nil,
        detail: MessagesChatDetail = .summary
    ) throws -> MessagesConversationIndex {
        let database = try openReadOnly(databasePath)
        defer { sqlite3_close(database) }
        let guardState = QueryGuard(timeout: timeout)
        let context = Unmanaged.passUnretained(guardState).toOpaque()
        sqlite3_progress_handler(
            database,
            1_000,
            { context in
                guard let context else { return 0 }
                return Unmanaged<QueryGuard>.fromOpaque(context).takeUnretainedValue().shouldStop
                    ? 1 : 0
            },
            context
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }

        let capabilities = try MessagesSchemaCapabilities.discover(in: database)
        guard capabilities.hasColumn("guid", in: "chat") else {
            throw MessagesChatRepositoryError.minimumSchemaUnavailable
        }

        try execute("BEGIN DEFERRED TRANSACTION", stage: "snapshot", database: database)
        do {
            var availability = availability(for: capabilities)
            // Classification and participant filtering need readable handle text. Guessing
            // from relationship row IDs would count one person several times, so a filtered
            // request fails instead.
            guard
                (kind == nil && participants == nil)
                    || participantIdentitySupported(capabilities)
            else {
                throw MessagesChatRepositoryError.queryFailed(
                    stage: participants == nil ? "kind-unavailable" : "participants-unavailable",
                    code: SQLITE_OK
                )
            }

            var records: [ChatRecord]
            if kind != nil || participants != nil {
                // Scan ordered header pages, classify each page authoritatively, and keep
                // only matches, until the caller's limit is filled or the source runs out.
                // No SQL predicate narrows the scan, so a conversation can never be dropped
                // before `MessagesHandleIdentity` has seen it.
                records = []
                var offset = 0
                while records.count < limit {
                    try checkBoundary(guardState)
                    var page = try fetchChats(
                        database: database,
                        capabilities: capabilities,
                        limit: filterPageSize,
                        offset: offset
                    )
                    if page.isEmpty { break }
                    offset += page.count
                    try checkBoundary(guardState)
                    try fetchParticipants(
                        into: &page,
                        database: database,
                        capabilities: capabilities,
                        availability: &availability
                    )
                    for record in page
                    where (kind == nil || record.chat.kind == kind)
                        && participantFilter(participants, matches: record.chat)
                    {
                        records.append(record)
                        if records.count == limit { break }
                    }
                }
            } else {
                records = try fetchChats(
                    database: database,
                    capabilities: capabilities,
                    limit: limit,
                    offset: 0
                )
                try checkBoundary(guardState)
                try fetchParticipants(
                    into: &records,
                    database: database,
                    capabilities: capabilities,
                    availability: &availability
                )
            }
            if detail == .full {
                try fetchFullMetadata(
                    into: &records,
                    database: database,
                    capabilities: capabilities,
                    availability: &availability
                )
            }
            try execute("COMMIT", stage: "snapshot", database: database)
            return MessagesConversationIndex(
                detail: detail,
                metadataAvailability: availability,
                chats: records.map(\.chat)
            )
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func resolveChatIdentifier(_ identifier: String, databasePath: String) throws -> String {
        try resolveChatDestination(identifier, databasePath: databasePath).chatGuid
    }

    func resolveChatDestination(
        _ identifier: String,
        databasePath: String
    ) throws -> MessagesResolvedChatDestination {
        try identifierCodec.validate(identifier)
        let database = try openReadOnly(databasePath)
        defer { sqlite3_close(database) }
        let capabilities = try MessagesSchemaCapabilities.discover(in: database)
        guard capabilities.hasColumn("guid", in: "chat") else {
            throw MessagesChatRepositoryError.minimumSchemaUnavailable
        }
        try execute("BEGIN DEFERRED TRANSACTION", stage: "resolve-snapshot", database: database)
        do {
            let statement = try prepare(
                "SELECT ROWID, guid FROM chat",
                stage: "resolve",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            var resolved: (rowId: Int64, guid: String)?
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let guid = sqliteText(statement, column: 1) else {
                        throw queryError(stage: "resolve-map", database: database)
                    }
                    if try identifierCodec.create(for: guid) == identifier {
                        guard resolved == nil else {
                            throw queryError(stage: "resolve-duplicate", database: database)
                        }
                        resolved = (sqlite3_column_int64(statement, 0), guid)
                    }
                case SQLITE_DONE:
                    guard let resolved else {
                        throw MessagesChatRepositoryError.staleIdentifier
                    }
                    let destination = try resolvedDestination(
                        rowId: resolved.rowId,
                        guid: resolved.guid,
                        database: database,
                        capabilities: capabilities
                    )
                    try execute("COMMIT", stage: "resolve-snapshot", database: database)
                    return destination
                default: throw queryError(stage: "resolve-step", database: database)
                }
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Whether a stored handle that failed strict send normalization could still denote one
    /// of the requested participants.
    ///
    /// This deliberately answers "could not possibly" rather than "is". It never infers a
    /// country code or rewrites a handle into a destination — its only use is deciding
    /// whether a conversation must be reported as unresolvable instead of no-match.
    static func unresolvableHandle(
        _ stored: String,
        couldDenoteAnyOf requested: Set<String>
    ) -> Bool {
        if stored.contains("@") {
            let lowered = stored.lowercased()
            return requested.contains { $0.contains("@") && $0 == lowered }
        }
        // Phone numbers are frequently stored in a local or formatted style that is not
        // valid E.164. Compare significant digits only.
        let digits = String(stored.filter(\.isNumber))
        guard digits.count >= 7 else { return false }
        return requested.contains { candidate in
            guard candidate.hasPrefix("+") else { return false }
            let candidateDigits = candidate.dropFirst()
            return candidateDigits.hasSuffix(digits) || digits.hasSuffix(candidateDigits)
        }
    }

    func matchConversation(
        normalizedParticipants: Set<String>,
        kind: MessagesChatKind,
        databasePath: String
    ) throws -> MessagesConversationMatch {
        let database = try openReadOnly(databasePath)
        defer { sqlite3_close(database) }
        let guardState = QueryGuard(timeout: timeout)
        let context = Unmanaged.passUnretained(guardState).toOpaque()
        sqlite3_progress_handler(
            database,
            1_000,
            { context in
                guard let context else { return 0 }
                return Unmanaged<QueryGuard>.fromOpaque(context).takeUnretainedValue().shouldStop
                    ? 1 : 0
            },
            context
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let capabilities = try MessagesSchemaCapabilities.discover(in: database)
        guard capabilities.hasColumn("guid", in: "chat") else {
            throw MessagesChatRepositoryError.minimumSchemaUnavailable
        }
        guard capabilities.hasColumn("chat_id", in: "chat_handle_join"),
            capabilities.hasColumn("handle_id", in: "chat_handle_join"),
            capabilities.hasColumn("id", in: "handle")
        else { return .incomplete }

        func projection(_ column: String) -> String {
            capabilities.hasColumn(column, in: "chat") ? "c.\(column)" : "NULL"
        }
        let statement = try prepare(
            """
            SELECT c.ROWID, c.guid, \(projection("display_name")),
                   \(projection("room_name")), \(projection("service_name")),
                   \(projection("chat_identifier")), h.id
            FROM chat c
            LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            LEFT JOIN handle h ON h.ROWID = chj.handle_id
            ORDER BY c.ROWID, h.ROWID
            """,
            stage: "match",
            database: database
        )
        defer { sqlite3_finalize(statement) }

        struct Candidate {
            var guid: String
            var displayName: String?
            var roomName: String?
            var service: String?
            var chatIdentifier: String?
            var participants: Set<String> = []
            var unresolvable: Set<String> = []
            var incomplete: Bool { !unresolvable.isEmpty }
        }
        var candidates: [String: Candidate] = [:]
        try stepRows(statement, stage: "match-step", database: database) { row in
            guard let guid = sqliteText(row, column: 1) else { return }
            var candidate =
                candidates[guid]
                ?? Candidate(
                    guid: guid,
                    displayName: trimmedText(row, column: 2),
                    roomName: trimmedText(row, column: 3),
                    service: trimmedText(row, column: 4),
                    chatIdentifier: trimmedText(row, column: 5)
                )
            if let storedHandle = trimmedText(row, column: 6) {
                if let normalized = MessagesHandleNormalization.normalize(storedHandle) {
                    candidate.participants.insert(normalized)
                } else if let identity = MessagesHandleIdentity.identity(storedHandle) {
                    candidate.unresolvable.insert(identity)
                }
            }
            candidates[guid] = candidate
        }

        var matches: [String: MessagesResolvedChatDestination] = [:]
        var hasUnresolvableRelevantCandidate = false
        for candidate in candidates.values {
            var participants = candidate.participants
            if participants.isEmpty, let fallback = candidate.chatIdentifier,
                let normalized = MessagesHandleNormalization.normalize(fallback)
            {
                participants.insert(normalized)
            }
            if candidate.incomplete {
                // A stored participant that cannot be compared exactly — a phone number kept
                // in a non-E.164 form, for instance — might be one of the requested
                // participants, and no country code may be inferred to find out. Silently
                // skipping such a candidate could abandon the real existing conversation and
                // start a new one on a different route.
                //
                // Flag it only when it could still be this request: its resolvable
                // participants already equal the requested set (so it looks like an exact
                // match while holding extra members), or they are a subset that its
                // unresolvable members could exactly complete.
                //
                // A handle that could not denote any requested participant at all — a short
                // code, for instance — is simply a different conversation and is skipped.
                let couldDenoteRequest = candidate.unresolvable.contains {
                    Self.unresolvableHandle($0, couldDenoteAnyOf: normalizedParticipants)
                }
                let looksExact = participants == normalizedParticipants
                let couldComplete =
                    participants.isSubset(of: normalizedParticipants)
                    && participants.count + candidate.unresolvable.count
                        == normalizedParticipants.count
                if couldDenoteRequest, looksExact || couldComplete {
                    hasUnresolvableRelevantCandidate = true
                }
                continue
            }
            let candidateKind: MessagesChatKind = participants.count > 1 ? .group : .direct
            guard candidateKind == kind else { continue }
            guard participants == normalizedParticipants else { continue }
            let publicID = try identifierCodec.create(for: candidate.guid)
            let destination = MessagesResolvedChatDestination(
                chatGuid: candidate.guid,
                displayName: candidate.displayName,
                roomName: candidate.roomName,
                kind: candidateKind,
                participantCount: participants.count,
                participantHandles: participants.sorted(),
                service: candidate.service
            )
            if let prior = matches[publicID], prior != destination { return .ambiguous }
            matches[publicID] = destination
        }
        if matches.count > 1 { return .ambiguous }
        if hasUnresolvableRelevantCandidate { return .incomplete }
        if let match = matches.first {
            return .unique(publicChatID: match.key, destination: match.value)
        }
        return .none
    }
}

private extension SQLiteMessagesChatRepository {
    func resolvedDestination(
        rowId: Int64,
        guid: String,
        database: OpaquePointer,
        capabilities: MessagesSchemaCapabilities
    ) throws -> MessagesResolvedChatDestination {
        func projection(_ column: String) -> String {
            capabilities.hasColumn(column, in: "chat") ? column : "NULL"
        }
        let statement = try prepare(
            """
            SELECT \(projection("display_name")), \(projection("room_name")),
                   \(projection("service_name")), \(projection("chat_identifier"))
            FROM chat WHERE ROWID = ? AND guid = ?
            """,
            stage: "resolve-metadata",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, rowId) == SQLITE_OK,
            sqlite3_bind_text(statement, 2, guid, -1, sqliteTransient) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW
        else { throw MessagesChatRepositoryError.staleIdentifier }
        let displayName = trimmedText(statement, column: 0)
        let roomName = trimmedText(statement, column: 1)
        let service = trimmedText(statement, column: 2)
        let chatIdentifier = trimmedText(statement, column: 3)

        guard capabilities.hasColumn("chat_id", in: "chat_handle_join"),
            capabilities.hasColumn("handle_id", in: "chat_handle_join"),
            capabilities.hasColumn("id", in: "handle")
        else { throw MessagesChatRepositoryError.minimumSchemaUnavailable }
        let participantsStatement = try prepare(
            """
            SELECT h.id
            FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ? AND h.id IS NOT NULL
            ORDER BY h.id
            """,
            stage: "resolve-participants",
            database: database
        )
        defer { sqlite3_finalize(participantsStatement) }
        guard sqlite3_bind_int64(participantsStatement, 1, rowId) == SQLITE_OK else {
            throw queryError(stage: "resolve-participants-bind", database: database)
        }
        // Deduplicate by the same identity the conversation index uses, so a chat cannot be
        // resolved as a group here while being listed as direct.
        var identities: Set<String> = []
        try stepRows(
            participantsStatement,
            stage: "resolve-participants-step",
            database: database
        ) { statement in
            if let handle = trimmedText(statement, column: 0),
                let identity = MessagesHandleIdentity.identity(handle)
            {
                identities.insert(identity)
            }
        }
        if identities.isEmpty, let chatIdentifier,
            isE164(chatIdentifier) || isEmail(chatIdentifier),
            let identity = MessagesHandleIdentity.identity(chatIdentifier)
        {
            identities.insert(identity)
        }
        let participants = identities.sorted()
        return MessagesResolvedChatDestination(
            chatGuid: guid,
            displayName: displayName,
            roomName: roomName,
            kind: participants.count > 1 ? .group : .direct,
            participantCount: participants.count,
            participantHandles: participants,
            service: service
        )
    }

    struct ChatRecord {
        let rowId: Int64
        var chat: MessagesChat
    }

    final class QueryGuard: @unchecked Sendable {
        let deadline: Date
        init(timeout: TimeInterval) { deadline = Date().addingTimeInterval(timeout) }
        var shouldStop: Bool { Date() >= deadline || Task<Never, Never>.isCancelled }
    }

    struct MessageObservation {
        let rowId: Int64
        let chatId: Int64
        let guid: String?
        let date: Date?
        let isFromMe: Bool?
        let service: String?
        let isDelivered: Bool?
        let isSent: Bool?
        let isFinished: Bool?
        let error: Int?
        let isRead: Bool?
        let isSystem: Bool?
        let isService: Bool?
        let isEmpty: Bool?
        let itemType: Int?
        let associatedType: Int?
        let replyToGuid: String?
        let editedDate: Date?
        let retractedDate: Date?
        let expressiveStyle: String?
        let balloonBundleId: String?
    }

    struct AttachmentObservation: Hashable {
        let chatId: Int64
        let messageId: Int64
        let attachmentId: Int64
        let createdDate: Date?
        let mediaCategory: String
        let isSticker: Bool?
    }

    /// Fetches one ordered page of chat headers.
    ///
    /// This query never derives participant identity, participant count, or `kind`. No SQL
    /// expression can reproduce `MessagesHandleIdentity` — SQLite's `LOWER` and `TRIM` do
    /// not match Swift's case and whitespace semantics — and a lossy SQL predicate would
    /// silently drop conversations before Swift could classify them. Those fields are
    /// populated only by `fetchParticipants` from readable handle text.
    func fetchChats(
        database: OpaquePointer,
        capabilities: MessagesSchemaCapabilities,
        limit: Int,
        offset: Int
    ) throws -> [ChatRecord] {
        queryObserver("chats")
        let latestExpression: String
        if capabilities.hasColumn("message_date", in: "chat_message_join") {
            latestExpression =
                "(SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = c.ROWID)"
        } else if capabilities.hasTable("message"),
            capabilities.hasColumn("date", in: "message"),
            capabilities.hasColumn("message_id", in: "chat_message_join")
        {
            latestExpression = """
                (SELECT MAX(m.date) FROM chat_message_join cmj
                 JOIN message m ON m.ROWID = cmj.message_id WHERE cmj.chat_id = c.ROWID)
                """
        } else {
            latestExpression = "NULL"
        }
        func projection(_ column: String) -> String {
            capabilities.hasColumn(column, in: "chat") ? "c.\(column)" : "NULL"
        }
        let sql = """
            SELECT c.ROWID, c.guid, \(projection("chat_identifier")),
                   \(projection("group_id")), \(projection("original_group_id")),
                   \(projection("room_name")), \(projection("display_name")),
                   \(projection("service_name")), \(projection("is_archived")),
                   \(projection("is_filtered")), \(projection("last_read_message_timestamp")),
                   \(latestExpression)
            FROM chat c
            ORDER BY 12 IS NULL ASC, 12 DESC, c.ROWID DESC
            LIMIT ? OFFSET ?
            """
        let statement = try prepare(sql, stage: "chats-prepare", database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK,
            sqlite3_bind_int(statement, 2, Int32(offset)) == SQLITE_OK
        else {
            throw queryError(stage: "chats-bind", database: database)
        }
        var result: [ChatRecord] = []
        try stepRows(statement, stage: "chats-step", database: database) { statement in
            guard let guid = sqliteText(statement, column: 1) else {
                throw MessagesChatRepositoryError.minimumSchemaUnavailable
            }
            let publicId = try identifierCodec.create(for: guid)
            result.append(
                ChatRecord(
                    rowId: sqlite3_column_int64(statement, 0),
                    chat: MessagesChat(
                        id: publicId,
                        chatId: publicId,
                        chatGuid: guid,
                        chatIdentifier: trimmedText(statement, column: 2),
                        groupId: trimmedText(statement, column: 3),
                        originalGroupId: trimmedText(statement, column: 4),
                        roomName: trimmedText(statement, column: 5),
                        displayName: trimmedText(statement, column: 6),
                        kind: nil,
                        participantCount: nil,
                        participants: nil,
                        service: trimmedText(statement, column: 7),
                        isArchived: sqliteBool(statement, column: 8),
                        isFiltered: sqliteBool(statement, column: 9),
                        lastReadTimestamp: sqliteNanosecondDate(statement, column: 10),
                        latestActivity: sqliteNanosecondDate(statement, column: 11),
                        full: nil
                    )
                )
            )
        }
        return result
    }

    /// Whether readable remote handle text is available, which is the only basis on which
    /// participant identity, participant count, and `kind` may be reported.
    func participantIdentitySupported(_ capabilities: MessagesSchemaCapabilities) -> Bool {
        capabilities.hasColumn("chat_id", in: "chat_handle_join")
            && capabilities.hasColumn("handle_id", in: "chat_handle_join")
            && capabilities.hasColumn("id", in: "handle")
    }

    func participantFilter(_ requested: Set<String>?, matches chat: MessagesChat) -> Bool {
        guard let requested else { return true }
        let conversation = Set(chat.participants?.map(\.handle) ?? [])
        return requested.isSubset(of: conversation)
    }

    func fetchParticipants(
        into records: inout [ChatRecord],
        database: OpaquePointer,
        capabilities: MessagesSchemaCapabilities,
        availability: inout [String: Bool]
    ) throws {
        guard !records.isEmpty else { return }
        guard participantIdentitySupported(capabilities) else {
            availability["participants"] = false
            availability["participantCount"] = false
            availability["kind"] = false
            return
        }
        queryObserver("participants")
        func handleProjection(_ column: String) -> String {
            capabilities.hasColumn(column, in: "handle") ? "h.\(column)" : "NULL"
        }
        let placeholders = records.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT chj.chat_id, h.id, \(handleProjection("uncanonicalized_id")),
                   \(handleProjection("service")), \(handleProjection("country"))
            FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id IN (\(placeholders))
            ORDER BY chj.chat_id, h.id, h.ROWID
            """
        let statement = try prepare(sql, stage: "participants-prepare", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(records.map(\.rowId), to: statement, database: database)
        // Collapse every observation of one remote identity into a single participant so
        // duplicate relationship rows, letter-case differences, and differing service or
        // country metadata cannot inflate the count or change direct/group classification.
        var byChat: [Int64: [String: ParticipantObservations]] = [:]
        try stepRows(statement, stage: "participants-step", database: database) { statement in
            guard let handle = trimmedText(statement, column: 1),
                let identity = MessagesHandleIdentity.identity(handle)
            else { return }
            let chatId = sqlite3_column_int64(statement, 0)
            var observations =
                byChat[chatId]?[identity] ?? ParticipantObservations(identity: identity)
            observations.observe(
                original: trimmedText(statement, column: 2),
                service: trimmedText(statement, column: 3),
                country: trimmedText(statement, column: 4)
            )
            byChat[chatId, default: [:]][identity] = observations
        }
        for index in records.indices {
            var participants = (byChat[records[index].rowId] ?? [:])
                .values
                .map { $0.participant() }
                .sorted { $0.handle < $1.handle }
            if participants.isEmpty,
                let fallback = records[index].chat.chatIdentifier,
                let identity = MessagesHandleIdentity.identity(fallback),
                isE164(fallback) || isEmail(fallback)
            {
                var observations = ParticipantObservations(identity: identity)
                observations.observe(
                    original: nil,
                    service: records[index].chat.service,
                    country: nil
                )
                participants = [observations.participant()]
            }
            let kind: MessagesChatKind = participants.count > 1 ? .group : .direct
            // Synthesized here rather than in the header query, because "is this direct?"
            // is only knowable once identities have been normalized.
            let displayName =
                records[index].chat.displayName
                ?? (kind == .direct
                    ? "Direct conversation \(records[index].chat.id.suffix(8))" : nil)
            records[index].chat = replacing(
                records[index].chat,
                displayName: displayName,
                kind: kind,
                participantCount: participants.count,
                participants: participants
            )
        }
    }

    func fetchFullMetadata(
        into records: inout [ChatRecord],
        database: OpaquePointer,
        capabilities: MessagesSchemaCapabilities,
        availability: inout [String: Bool]
    ) throws {
        guard !records.isEmpty else { return }
        var messages: [MessageObservation] = []
        do {
            messages = try fetchMessages(
                chatIds: records.map(\.rowId),
                database: database,
                capabilities: capabilities
            )
        } catch let error as MessagesChatRepositoryError {
            markMessageAvailabilityUnavailable(&availability)
            queryObserver("optional-messages-\(error.diagnosticStage)")
        }
        var attachments: Set<AttachmentObservation> = []
        do {
            attachments = try fetchAttachments(
                chatIds: records.map(\.rowId),
                database: database,
                capabilities: capabilities
            )
        } catch let error as MessagesChatRepositoryError {
            markAttachmentAvailabilityUnavailable(&availability)
            queryObserver("optional-attachments-\(error.diagnosticStage)")
        }

        let messagesByChat = Dictionary(grouping: messages, by: \.chatId)
        let attachmentsByChat = Dictionary(grouping: attachments, by: \.chatId)
        let attachmentMessageIds = Set(attachments.map(\.messageId))
        for index in records.indices {
            let chatMessages = messagesByChat[records[index].rowId] ?? []
            let chatAttachments = attachmentsByChat[records[index].rowId] ?? []
            records[index].chat.full = aggregate(
                messages: chatMessages,
                attachments: chatAttachments,
                attachmentMessageIds: attachmentMessageIds,
                capabilities: capabilities,
                availability: availability
            )
        }
    }

    func fetchMessages(
        chatIds: [Int64],
        database: OpaquePointer,
        capabilities: MessagesSchemaCapabilities
    ) throws -> [MessageObservation] {
        guard capabilities.hasColumn("message_id", in: "chat_message_join"),
            capabilities.hasColumn("guid", in: "message")
        else { return [] }
        queryObserver("messages")
        func projection(_ column: String) -> String {
            capabilities.hasColumn(column, in: "message") ? "m.\(column)" : "NULL"
        }
        let placeholders = chatIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT DISTINCT m.ROWID, cmj.chat_id, m.guid, \(projection("date")),
                   \(projection("is_from_me")), \(projection("service")),
                   \(projection("is_delivered")), \(projection("is_sent")),
                   \(projection("is_finished")), \(projection("error")),
                   \(projection("is_read")), \(projection("is_system_message")),
                   \(projection("is_service_message")), \(projection("is_empty")),
                   \(projection("item_type")), \(projection("associated_message_type")),
                   \(projection("reply_to_guid")), \(projection("date_edited")),
                   \(projection("date_retracted")),
                   \(projection("expressive_send_style_id")),
                   \(projection("balloon_bundle_id"))
            FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id IN (\(placeholders))
            """
        let statement = try prepare(sql, stage: "messages-prepare", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(chatIds, to: statement, database: database)
        var result: [MessageObservation] = []
        try stepRows(statement, stage: "messages-step", database: database) { statement in
            result.append(
                MessageObservation(
                    rowId: sqlite3_column_int64(statement, 0),
                    chatId: sqlite3_column_int64(statement, 1),
                    guid: trimmedText(statement, column: 2),
                    date: sqliteNanosecondDate(statement, column: 3),
                    isFromMe: sqliteBool(statement, column: 4),
                    service: trimmedText(statement, column: 5),
                    isDelivered: sqliteBool(statement, column: 6),
                    isSent: sqliteBool(statement, column: 7),
                    isFinished: sqliteBool(statement, column: 8),
                    error: sqliteInt(statement, column: 9),
                    isRead: sqliteBool(statement, column: 10),
                    isSystem: sqliteBool(statement, column: 11),
                    isService: sqliteBool(statement, column: 12),
                    isEmpty: sqliteBool(statement, column: 13),
                    itemType: sqliteInt(statement, column: 14),
                    associatedType: sqliteInt(statement, column: 15),
                    replyToGuid: trimmedText(statement, column: 16),
                    editedDate: sqliteNanosecondDate(statement, column: 17),
                    retractedDate: sqliteNanosecondDate(statement, column: 18),
                    expressiveStyle: trimmedText(statement, column: 19),
                    balloonBundleId: trimmedText(statement, column: 20)
                )
            )
        }
        return result
    }

    func fetchAttachments(
        chatIds: [Int64],
        database: OpaquePointer,
        capabilities: MessagesSchemaCapabilities
    ) throws -> Set<AttachmentObservation> {
        guard capabilities.hasColumn("message_id", in: "chat_message_join"),
            capabilities.hasColumn("message_id", in: "message_attachment_join"),
            capabilities.hasColumn("attachment_id", in: "message_attachment_join"),
            capabilities.hasTable("attachment")
        else { return [] }
        queryObserver("attachments")
        func projection(_ column: String) -> String {
            capabilities.hasColumn(column, in: "attachment") ? "a.\(column)" : "NULL"
        }
        let placeholders = chatIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT cmj.chat_id, maj.message_id, a.ROWID,
                   \(projection("created_date")), \(projection("mime_type")),
                   \(projection("is_sticker"))
            FROM chat_message_join cmj
            JOIN message_attachment_join maj ON maj.message_id = cmj.message_id
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE cmj.chat_id IN (\(placeholders))
            """
        let statement = try prepare(sql, stage: "attachments-prepare", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(chatIds, to: statement, database: database)
        var result: Set<AttachmentObservation> = []
        try stepRows(statement, stage: "attachments-step", database: database) { statement in
            result.insert(
                AttachmentObservation(
                    chatId: sqlite3_column_int64(statement, 0),
                    messageId: sqlite3_column_int64(statement, 1),
                    attachmentId: sqlite3_column_int64(statement, 2),
                    createdDate: sqliteSecondDate(statement, column: 3),
                    mediaCategory: mediaCategory(for: trimmedText(statement, column: 4)),
                    isSticker: sqliteBool(statement, column: 5)
                )
            )
        }
        return result
    }

    func aggregate(
        messages: [MessageObservation],
        attachments: [AttachmentObservation],
        attachmentMessageIds: Set<Int64>,
        capabilities: MessagesSchemaCapabilities,
        availability: [String: Bool]
    ) -> MessagesChatFullMetadata {
        let baseSupported = availability["messageCounts"] == true
        let baseMessages = baseSupported ? messages.filter(isUserVisibleBaseMessage) : []
        let incoming = baseMessages.filter { $0.isFromMe == false }
        let outgoing = baseMessages.filter { $0.isFromMe == true }
        let activitySupported = availability["latestMessageRecords"] == true
        let latestActivitySource = activitySupported ? messages.max(by: messageDateOrder) : nil
        let latestIncoming = activitySupported ? incoming.max(by: messageDateOrder) : nil
        let latestOutgoing = activitySupported ? outgoing.max(by: messageDateOrder) : nil

        let reactions = messages.filter { message in
            guard let type = message.associatedType else { return false }
            return Self.reactionAddTypes.contains(type) || Self.reactionRemoveTypes.contains(type)
        }
        let reactionAdds = reactions.filter { Self.reactionAddTypes.contains($0.associatedType ?? -1) }
        let reactionRemoves = reactions.filter {
            Self.reactionRemoveTypes.contains($0.associatedType ?? -1)
        }
        let edited = Dictionary(
            grouping: baseMessages.filter { $0.editedDate != nil && $0.guid != nil },
            by: { $0.guid! }
        )
        let retracted = baseMessages.filter { $0.retractedDate != nil }
        let replies = baseMessages.filter { $0.replyToGuid != nil }
        let categories = Dictionary(grouping: attachments, by: \.mediaCategory).mapValues(\.count)

        return MessagesChatFullMetadata(
            latestActivity: activityRecord(latestActivitySource, attachmentMessageIds),
            latestIncomingMessage: activityRecord(latestIncoming, attachmentMessageIds),
            latestOutgoingMessage: activityRecord(latestOutgoing, attachmentMessageIds),
            messageCount: baseSupported ? baseMessages.count : nil,
            incomingMessageCount: baseSupported ? incoming.count : nil,
            outgoingMessageCount: baseSupported ? outgoing.count : nil,
            unreadIncomingCount: availability["unreadIncomingCount"] == true
                ? incoming.filter { $0.isRead == false }.count : nil,
            failedOutgoingCount: availability["failedOutgoingCount"] == true
                ? outgoing.filter { ($0.error ?? 0) != 0 && $0.isFinished == true }.count : nil,
            hasAttachments: availability["attachments"] == true ? !attachments.isEmpty : nil,
            attachmentCount: availability["attachments"] == true ? attachments.count : nil,
            messagesWithAttachmentsCount: availability["attachments"] == true
                ? Set(attachments.map(\.messageId)).count : nil,
            latestAttachmentTimestamp: availability["latestAttachmentTimestamp"] == true
                ? attachments.compactMap(\.createdDate).max() : nil,
            attachmentCountByMediaCategory: availability["attachmentMediaCategories"] == true
                ? categories : nil,
            stickerAttachmentCount: availability["stickers"] == true
                ? attachments.filter { $0.isSticker == true }.count : nil,
            replyCount: availability["replies"] == true ? replies.count : nil,
            latestReplyTimestamp: availability["replies"] == true
                ? replies.compactMap(\.date).max() : nil,
            reactionEventCount: availability["reactions"] == true ? reactions.count : nil,
            reactionAddCount: availability["reactions"] == true ? reactionAdds.count : nil,
            reactionRemoveCount: availability["reactions"] == true ? reactionRemoves.count : nil,
            latestReactionEventTimestamp: availability["reactions"] == true
                ? reactions.compactMap(\.date).max() : nil,
            editedMessageCount: availability["edits"] == true ? edited.count : nil,
            latestEditTimestamp: availability["edits"] == true
                ? edited.values.flatMap { $0.compactMap(\.editedDate) }.max() : nil,
            retractionCount: availability["retractions"] == true ? retracted.count : nil,
            latestRetractionTimestamp: availability["retractions"] == true
                ? retracted.compactMap(\.retractedDate).max() : nil,
            mentionCount: nil,
            expressiveEffectMessageCount: availability["expressiveEffects"] == true
                ? baseMessages.filter { $0.expressiveStyle != nil }.count : nil,
            pluginMessageCount: availability["pluginMessages"] == true
                ? baseMessages.filter { $0.balloonBundleId != nil }.count : nil
        )
    }

    func activityRecord(
        _ message: MessageObservation?,
        _ attachmentMessageIds: Set<Int64>
    ) -> MessagesActivityRecord? {
        guard let message, let guid = message.guid, let date = message.date,
            let isFromMe = message.isFromMe
        else { return nil }
        return MessagesActivityRecord(
            messageGuid: guid,
            timestamp: date,
            direction: isFromMe ? "outgoing" : "incoming",
            service: message.service,
            hasAttachments: attachmentMessageIds.contains(message.rowId),
            deliveryState: deliveryState(for: message)
        )
    }

    func deliveryState(for message: MessageObservation) -> String? {
        guard message.isFromMe == true else { return "received" }
        guard message.isFinished != nil, message.isDelivered != nil, message.isSent != nil,
            message.error != nil
        else { return nil }
        if message.isFinished == true, (message.error ?? 0) != 0 { return "failed" }
        if message.isDelivered == true { return "delivered" }
        if message.isSent == true { return "sent" }
        if message.isFinished == false { return "pending" }
        return "unknown"
    }

    func isUserVisibleBaseMessage(_ message: MessageObservation) -> Bool {
        message.isSystem == false && message.isService == false && message.isEmpty == false
            && message.itemType == 0 && (message.associatedType ?? 0) == 0
    }

    func messageDateOrder(_ lhs: MessageObservation, _ rhs: MessageObservation) -> Bool {
        (lhs.date ?? .distantPast) < (rhs.date ?? .distantPast)
    }

    static let reactionAddTypes = Set(2000 ... 2006)
    static let reactionRemoveTypes = Set(3000 ... 3006)

    func availability(for capabilities: MessagesSchemaCapabilities) -> [String: Bool] {
        let participantRelationship =
            capabilities.hasColumn("chat_id", in: "chat_handle_join")
            && capabilities.hasColumn("handle_id", in: "chat_handle_join")
            && capabilities.hasColumn("id", in: "handle")
        let messageJoin =
            capabilities.hasColumn("message_id", in: "chat_message_join")
            && capabilities.hasTable("message")
        let baseMessage =
            messageJoin
            && [
                "guid", "date", "is_from_me", "is_system_message", "is_service_message", "is_empty",
                "item_type", "associated_message_type",
            ].allSatisfy { capabilities.hasColumn($0, in: "message") }
        let attachmentJoin =
            messageJoin
            && capabilities.hasColumn("message_id", in: "message_attachment_join")
            && capabilities.hasColumn("attachment_id", in: "message_attachment_join")
            && capabilities.hasTable("attachment")
        return [
            "chatGuid": true,
            "chatIdentifier": capabilities.hasColumn("chat_identifier", in: "chat"),
            "groupId": capabilities.hasColumn("group_id", in: "chat"),
            "originalGroupId": capabilities.hasColumn("original_group_id", in: "chat"),
            "roomName": capabilities.hasColumn("room_name", in: "chat"),
            "displayName": capabilities.hasColumn("display_name", in: "chat"),
            "service": capabilities.hasColumn("service_name", in: "chat"),
            "archived": capabilities.hasColumn("is_archived", in: "chat"),
            "filtered": capabilities.hasColumn("is_filtered", in: "chat"),
            // is_pending_review and is_blackholed exist in the inspected schema, but their
            // user-visible "screened" semantics have not been verified across releases.
            "screened": false,
            "lastReadTimestamp": capabilities.hasColumn("last_read_message_timestamp", in: "chat"),
            "latestActivityTimestamp": capabilities.hasColumn("message_date", in: "chat_message_join")
                || (messageJoin && capabilities.hasColumn("date", in: "message")),
            "participants": participantRelationship,
            "participantOriginalHandle": capabilities.hasColumn("uncanonicalized_id", in: "handle"),
            "participantService": capabilities.hasColumn("service", in: "handle"),
            "participantCountry": capabilities.hasColumn("country", in: "handle"),
            "participantCount": participantRelationship,
            "kind": participantRelationship,
            "latestMessageRecords": baseMessage,
            "messageCounts": baseMessage,
            "unreadIncomingCount": baseMessage && capabilities.hasColumn("is_read", in: "message"),
            "failedOutgoingCount": baseMessage
                && ["error", "is_finished"].allSatisfy {
                    capabilities.hasColumn($0, in: "message")
                },
            "deliveryState": ["is_delivered", "is_sent", "is_finished", "error"].allSatisfy {
                capabilities.hasColumn($0, in: "message")
            },
            "attachments": attachmentJoin,
            "latestAttachmentTimestamp": attachmentJoin
                && capabilities.hasColumn("created_date", in: "attachment"),
            "attachmentMediaCategories": attachmentJoin
                && capabilities.hasColumn("mime_type", in: "attachment"),
            "stickers": attachmentJoin
                && capabilities.hasColumn("is_sticker", in: "attachment"),
            "replies": baseMessage && capabilities.hasColumn("reply_to_guid", in: "message"),
            "reactions": messageJoin
                && capabilities.hasColumn("associated_message_type", in: "message"),
            "edits": baseMessage && capabilities.hasColumn("date_edited", in: "message"),
            "retractions": baseMessage && capabilities.hasColumn("date_retracted", in: "message"),
            "mentions": false,
            "expressiveEffects": baseMessage
                && capabilities.hasColumn("expressive_send_style_id", in: "message"),
            "pluginMessages": baseMessage
                && capabilities.hasColumn("balloon_bundle_id", in: "message"),
        ]
    }

    func markMessageAvailabilityUnavailable(_ availability: inout [String: Bool]) {
        for key in [
            "latestMessageRecords", "messageCounts", "unreadIncomingCount",
            "failedOutgoingCount", "deliveryState", "replies", "reactions", "edits",
            "retractions", "mentions", "expressiveEffects", "pluginMessages",
        ] { availability[key] = false }
    }

    func markAttachmentAvailabilityUnavailable(_ availability: inout [String: Bool]) {
        for key in [
            "attachments", "latestAttachmentTimestamp", "attachmentMediaCategories", "stickers",
        ] {
            availability[key] = false
        }
    }

    func isE164(_ value: String) -> Bool { messagesHandleIsE164(value) }

    func isEmail(_ value: String) -> Bool { messagesHandleIsEmail(value) }

    func mediaCategory(for mimeType: String?) -> String {
        guard let mimeType = mimeType?.lowercased() else { return "other" }
        for category in ["image", "video", "audio", "text", "application"] {
            if mimeType.hasPrefix("\(category)/") { return category }
        }
        return "other"
    }

    func replacing(
        _ chat: MessagesChat,
        displayName: String?,
        kind: MessagesChatKind,
        participantCount: Int,
        participants: [MessagesParticipant]
    ) -> MessagesChat {
        MessagesChat(
            id: chat.id,
            chatId: chat.chatId,
            chatGuid: chat.chatGuid,
            chatIdentifier: chat.chatIdentifier,
            groupId: chat.groupId,
            originalGroupId: chat.originalGroupId,
            roomName: chat.roomName,
            displayName: displayName,
            kind: kind,
            participantCount: participantCount,
            participants: participants,
            service: chat.service,
            isArchived: chat.isArchived,
            isFiltered: chat.isFiltered,
            lastReadTimestamp: chat.lastReadTimestamp,
            latestActivity: chat.latestActivity,
            full: chat.full
        )
    }

    func openReadOnly(_ path: String) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let database else {
            let code = database.map(sqlite3_extended_errcode) ?? result
            if let database { sqlite3_close(database) }
            throw MessagesChatRepositoryError.databaseUnavailable(code: code)
        }
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 1_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            let error = queryError(stage: "configure", database: database)
            sqlite3_close(database)
            throw error
        }
        return database
    }

    func prepare(_ sql: String, stage: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw queryError(stage: stage, database: database) }
        return statement
    }

    func execute(_ sql: String, stage: String, database: OpaquePointer) throws {
        queryObserver(stage)
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw queryError(stage: stage, database: database)
        }
    }

    func bind(_ values: [Int64], to statement: OpaquePointer, database: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(offset + 1), value) == SQLITE_OK else {
                throw queryError(stage: "bind", database: database)
            }
        }
    }

    func stepRows(
        _ statement: OpaquePointer,
        stage: String,
        database: OpaquePointer,
        row: (OpaquePointer) throws -> Void
    ) throws {
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw queryError(stage: stage, database: database)
            }
        }
    }

    func checkBoundary(_ guardState: QueryGuard) throws {
        if guardState.shouldStop {
            throw MessagesChatRepositoryError.queryFailed(
                stage: "cancelled-or-timeout",
                code: SQLITE_INTERRUPT
            )
        }
    }

    func queryError(stage: String, database: OpaquePointer) -> MessagesChatRepositoryError {
        let code = sqlite3_extended_errcode(database)
        return .queryFailed(stage: stage, code: code == SQLITE_OK ? SQLITE_ERROR : code)
    }
}

private func rows(
    _ sql: String,
    database: OpaquePointer,
    row: (OpaquePointer) throws -> Void
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
    else {
        throw MessagesChatRepositoryError.queryFailed(
            stage: "schema",
            code: sqlite3_extended_errcode(database)
        )
    }
    defer { sqlite3_finalize(statement) }
    while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: try row(statement)
        case SQLITE_DONE: return
        default:
            throw MessagesChatRepositoryError.queryFailed(
                stage: "schema",
                code: sqlite3_extended_errcode(database)
            )
        }
    }
}

private func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
}

private func trimmedText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard let value = sqliteText(statement, column: column)?.trimmingCharacters(in: .whitespaces),
        !value.isEmpty
    else { return nil }
    return value
}

private func sqliteInt(_ statement: OpaquePointer, column: Int32) -> Int? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, column))
}

private func sqliteBool(_ statement: OpaquePointer, column: Int32) -> Bool? {
    sqliteInt(statement, column: column).map { $0 != 0 }
}

private func sqliteNanosecondDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    let nanoseconds = sqlite3_column_int64(statement, column)
    guard nanoseconds != 0 else { return nil }
    return Date(timeIntervalSinceReferenceDate: TimeInterval(nanoseconds) / 1_000_000_000)
}

private func sqliteSecondDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    let seconds = sqlite3_column_double(statement, column)
    guard seconds != 0 else { return nil }
    return Date(timeIntervalSinceReferenceDate: seconds)
}

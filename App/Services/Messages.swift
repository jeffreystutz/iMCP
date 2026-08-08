import AppKit
import MCP
import OSLog
import SQLite3
import UniformTypeIdentifiers
import iMessage

private let log = Logger.service("messages")
private let messagesDatabasePath = "/Users/\(NSUserName())/Library/Messages/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let messagesDatabaseDirectoryBookmarkKey: String =
    "me.mattt.iMCP.messagesDatabaseDirectoryBookmark.v1"
private let messagesDirectoryAccessUpgradeVersionKey: String =
    "me.mattt.iMCP.messagesDirectoryAccessUpgradeVersion"
private let currentMessagesDirectoryAccessUpgradeVersion = 1
private let defaultLimit = 30
private let maximumChatLimit = 100

enum MessagesChatListingError: LocalizedError, Equatable, Sendable {
    case invalidLimit
    case invalidKind
    case invalidDetail

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "The chat limit must be an integer from 1 through 100."
        case .invalidKind:
            return "The chat kind must be direct or group."
        case .invalidDetail:
            return "The chat detail must be summary or full."
        }
    }
}

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    /// Options for persisting user-selected Messages locations across launches.
    ///
    /// `.withSecurityScope` is what makes the bookmark security-scoped at all, and the app
    /// must additionally declare `com.apple.security.files.bookmarks.app-scope` for the
    /// sandbox to issue one. Without both, creation fails with the Cocoa error
    /// "Failed to retrieve app-scope key". `.securityScopeAllowOnlyReadAccess` narrows the
    /// restored scope to reading, and is only meaningful alongside `.withSecurityScope`.
    static let readOnlySecurityScopedBookmarkOptions: URL.BookmarkCreationOptions = [
        .withSecurityScope, .securityScopeAllowOnlyReadAccess,
    ]

    private let sender: any MessagesSending
    private let chatRepository: any MessagesChatListing
    private let chatDatabasePathOverride: String?
    private let chatListingLog: @Sendable (Int) -> Void

    init(
        sender: any MessagesSending = AppleScriptMessagesSender(),
        chatRepository: any MessagesChatListing = SQLiteMessagesChatRepository(),
        chatDatabasePathOverride: String? = nil,
        chatListingLog: @escaping @Sendable (Int) -> Void = { count in
            log.notice("Listed \(count) Messages conversations")
        }
    ) {
        self.sender = sender
        self.chatRepository = chatRepository
        self.chatDatabasePathOverride = chatDatabasePathOverride
        self.chatListingLog = chatListingLog
        super.init()
    }

    func activate() async throws {
        log.debug("Starting message service activation")

        if canAccessDatabaseAtDefaultPath {
            log.debug("Successfully activated using default database path")
            await requestChatListingDirectoryAccessIfNeeded()
            return
        }

        if canAccessDatabaseUsingBookmark {
            log.debug("Successfully activated using stored bookmark")
            await requestChatListingDirectoryAccessIfNeeded()
            return
        }

        log.debug("Opening file picker for manual database selection")
        guard try await showDatabaseAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }

        let selectedURL = try await showFilePicker()

        guard FileManager.default.isReadableFile(atPath: selectedURL.path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        storeBookmark(for: selectedURL)
        await requestChatListingDirectoryAccessIfNeeded()
        log.debug("Successfully activated message service")
    }

    @MainActor
    func performDirectoryAccessUpgradeIfNeeded() async {
        guard !canAccessChatDatabaseDirectoryUsingBookmark else { return }
        let completedVersion = UserDefaults.standard.integer(
            forKey: messagesDirectoryAccessUpgradeVersionKey
        )
        guard completedVersion < currentMessagesDirectoryAccessUpgradeVersion else { return }

        UserDefaults.standard.set(
            currentMessagesDirectoryAccessUpgradeVersion,
            forKey: messagesDirectoryAccessUpgradeVersionKey
        )
        await requestChatListingDirectoryAccessIfNeeded()
    }

    var isActivated: Bool {
        get async {
            let isActivated = canAccessDatabaseAtDefaultPath || canAccessDatabaseUsingBookmark
            log.debug("Message service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "messages_list_chats",
            description:
                "List existing Messages conversations with schema-supported metadata, including conversation identifiers, names, direct or group kind, participant handles and counts, service, state flags, and activity timestamps. Does not return message contents, attachment names, attachment paths, or account credentials.",
            inputSchema: .object(
                properties: [
                    "limit": .integer(
                        description: "Maximum conversations to return",
                        default: .int(defaultLimit),
                        minimum: 1,
                        maximum: maximumChatLimit
                    ),
                    "kind": .string(
                        description: "Optionally return only direct or group conversations",
                        enum: ["direct", "group"]
                    ),
                    "detail": .string(
                        description:
                            "Metadata detail: summary avoids history aggregates; full adds supported message, attachment, and event aggregates",
                        default: .string("summary"),
                        enum: ["summary", "full"]
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Messages Conversations",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit: Int
            if let value = arguments["limit"] {
                guard let requestedLimit = value.intValue,
                    (1 ... maximumChatLimit).contains(requestedLimit)
                else {
                    throw MessagesChatListingError.invalidLimit
                }
                limit = requestedLimit
            } else {
                limit = defaultLimit
            }

            let kind: MessagesChatKind?
            if let value = arguments["kind"] {
                guard let rawKind = value.stringValue,
                    let requestedKind = MessagesChatKind(rawValue: rawKind)
                else {
                    throw MessagesChatListingError.invalidKind
                }
                kind = requestedKind
            } else {
                kind = nil
            }

            let detail: MessagesChatDetail
            if let value = arguments["detail"] {
                guard let rawDetail = value.stringValue,
                    let requestedDetail = MessagesChatDetail(rawValue: rawDetail)
                else { throw MessagesChatListingError.invalidDetail }
                detail = requestedDetail
            } else {
                detail = .summary
            }

            let start = ContinuousClock.now
            let index = try await self.listChats(limit: limit, kind: kind, detail: detail)
            self.chatListingLog(index.chats.count)
            let elapsed = start.duration(to: .now)
            log.notice(
                "Listed Messages conversations detail=\(detail.rawValue, privacy: .public) count=\(index.chats.count) elapsed=\(String(describing: elapsed), privacy: .public)"
            )
            return index
        }

        Tool(
            name: "messages_fetch",
            description: "Fetch messages from the Messages app",
            inputSchema: .object(
                properties: [
                    "participants": .array(
                        description:
                            "Participant handles (phone or email). Phone numbers should use E.164 format",
                        items: .string()
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "query": .string(
                        description: "Search term to filter messages by content"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting message fetch with arguments: \(arguments)")
            try await self.activate()

            let participants =
                arguments["participants"]?.arrayValue?.compactMap({
                    $0.stringValue
                }) ?? []

            var dateRange: Range<Date>?
            if let startDateStr = arguments["start"]?.stringValue,
                let endDateStr = arguments["end"]?.stringValue,
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            {
                let calendar = Calendar.current
                let normalizedStart = calendar.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
                let normalizedEnd = calendar.normalizedEndDate(
                    from: parsedEnd.date,
                    isDateOnly: parsedEnd.isDateOnly
                )

                dateRange = normalizedStart ..< normalizedEnd
            }

            let searchTerm = arguments["query"]?.stringValue
            let limit = arguments["limit"]?.intValue

            let db = try self.createDatabaseConnection()
            var messages: [[String: Value]] = []

            log.debug("Fetching handles for participants: \(participants)")
            let handles = try db.fetchParticipant(matching: participants)

            log.debug(
                "Fetching messages with date range: \(String(describing: dateRange)), limit: \(limit ?? -1)"
            )
            for message in try db.fetchMessages(
                with: Set(handles),
                in: dateRange,
                limit: max(limit ?? defaultLimit, 1024)
            ) {
                guard messages.count < (limit ?? defaultLimit) else { break }
                guard !message.text.isEmpty else { continue }

                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else if message.sender == nil {
                    sender = "unknown"
                } else {
                    sender = message.sender!.rawValue
                }

                if let searchTerm {
                    guard message.text.localizedCaseInsensitiveContains(searchTerm) else {
                        continue
                    }
                }

                messages.append([
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(message.text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                ])
            }

            log.debug("Successfully fetched \(messages.count) messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }

        Tool(
            name: "messages_send",
            description:
                "Submit one plain-text message using exactly one destination. A recipient first uses one uniquely matching existing direct conversation, or retains raw-recipient behavior when none exists. Recipients can address only an existing group conversation: iMCP cannot create a new group from a list, and the complete participant set must exactly match one existing group or the call fails without sending. When multiple groups have the same participant set, use chat_id; chat_id is preferred when the intended group is already known. Existing-chat sends always require confirmation.",
            inputSchema: .object(
                properties: [
                    "recipient": .string(
                        description:
                            "One exact E.164 phone number or email address. A unique existing direct conversation is used when available; otherwise the established raw-recipient path is used."
                    ),
                    "recipients": .array(
                        description:
                            "The complete set of remote participants in an existing group conversation. This does not create a new group. The set must exactly match one existing group, or the call fails without sending.",
                        items: .string(
                            description: "One exact E.164 phone number or email address"
                        ),
                        minItems: 2
                    ),
                    "chat_id": .string(
                        description:
                            "Opaque chat ID returned by messages_list_chats that explicitly selects an existing direct or group conversation; preferred when the intended group is already known. Do not supply a database or scripting identifier.",
                        minLength: 1
                    ),
                    "body": .string(
                        description: "Plain-text message body",
                        minLength: 1
                    ),
                ],
                required: ["body"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send iMessage",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments, context in
            let input = try await self.resolveSendInput(
                arguments,
                context: context
            )
            guard !input.body.isEmpty else {
                throw MessageSendError.emptyBody
            }

            let preparedDestination: PreparedSendDestination
            switch input.destination {
            case .recipient(let recipient):
                let participants = Set([MessagesHandleNormalization.normalize(recipient)!])
                switch try await self.matchSendConversation(participants, kind: .direct) {
                case .none:
                    // Only a verified absence of any matching conversation may fall back to
                    // the raw-recipient path. Unresolved membership is not evidence of absence.
                    preparedDestination = .rawRecipient(recipient)
                case .incomplete:
                    throw MessageSendError.incompleteDirectMembership
                case .ambiguous:
                    throw MessageSendError.ambiguousDirectConversation
                case .unique(let publicChatID, let destination):
                    preparedDestination = .matched(
                        publicChatID: publicChatID,
                        expectedParticipants: participants,
                        initial: destination
                    )
                }
            case .recipients(let participants):
                switch try await self.matchSendConversation(participants, kind: .group) {
                case .none:
                    throw MessageSendError.groupConversationNotFound
                case .incomplete:
                    throw MessageSendError.incompleteGroupMembership
                case .ambiguous:
                    throw MessageSendError.ambiguousGroupConversation
                case .unique(let publicChatID, let destination):
                    preparedDestination = .matched(
                        publicChatID: publicChatID,
                        expectedParticipants: participants,
                        initial: destination
                    )
                }
            case .chat(let chatID):
                preparedDestination = .explicitChat(
                    publicChatID: chatID,
                    initial: try await self.resolveSendChat(chatID)
                )
            }

            // Every destination form requires its own final confirmation. There is no
            // setting, build configuration, or injected dependency that can bypass this.
            let confirmationMessage: String
            let confirmationTitle: String
            switch preparedDestination {
            case .rawRecipient(let recipient):
                confirmationMessage = self.rawRecipientConfirmationMessage(
                    recipient: recipient,
                    body: input.body
                )
                confirmationTitle = "Confirm new direct message"
            case .explicitChat(_, let initialChat), .matched(_, _, let initialChat):
                confirmationMessage = self.chatConfirmationMessage(
                    initialChat,
                    body: input.body,
                    matchedFromParticipants: preparedDestination.isMatchedGroup
                )
                confirmationTitle = "Confirm existing-chat submission"
            }
            let confirmation = try await context.elicitation.requestForm(
                message: confirmationMessage,
                schema: .init(
                    title: confirmationTitle,
                    properties: [
                        "confirmed": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                "Confirm that Messages should submit this message"
                            ),
                        ])
                    ],
                    required: ["confirmed"]
                )
            )

            switch confirmation.action {
            case .decline:
                throw MessageSendError.confirmationDeclined
            case .cancel:
                throw MessageSendError.confirmationCancelled
            case .accept:
                guard confirmation.content?["confirmed"]?.boolValue == true else {
                    throw MessageSendError.confirmationMalformed
                }
            }

            try Task.checkCancellation()
            switch preparedDestination {
            case .rawRecipient(let recipient):
                try await self.sender.submit(recipient: recipient, body: input.body)
                log.notice("Messages accepted one submission destination=recipient path=raw-recipient")
                return MessageSubmissionResult(status: "submitted", service: "iMessage")
            case .explicitChat(let publicChatID, let initialChat):
                let revalidatedChat = try await self.resolveSendChat(publicChatID)
                guard revalidatedChat == initialChat else {
                    throw MessageSendError.staleChatIdentifier
                }
                try Task.checkCancellation()
                try await self.sender.submit(
                    chatGUID: revalidatedChat.chatGuid,
                    body: input.body
                )
                log.notice(
                    "Messages accepted one submission destination=chat kind=\(revalidatedChat.kind.rawValue, privacy: .public)"
                )
                return MessageSubmissionResult(status: "submitted", service: "Messages")
            case .matched(let publicChatID, let expectedParticipants, let initial):
                let match = try await self.matchSendConversation(
                    expectedParticipants,
                    kind: initial.kind
                )
                guard case .unique(let revalidatedID, let revalidatedChat) = match,
                    revalidatedID == publicChatID,
                    revalidatedChat == initial
                else { throw MessageSendError.staleMatchedConversation }
                try Task.checkCancellation()
                try await self.sender.submit(chatGUID: revalidatedChat.chatGuid, body: input.body)
                log.notice(
                    "Messages accepted one submission destination=\(initial.kind == .group ? "recipients" : "recipient", privacy: .public) resolution=unique path=existing-chat kind=\(initial.kind.rawValue, privacy: .public)"
                )
                return MessageSubmissionResult(status: "submitted", service: "Messages")
            }
        }
    }

    private func listChats(
        limit: Int,
        kind: MessagesChatKind?,
        detail: MessagesChatDetail
    ) async throws -> MessagesConversationIndex {
        if let chatDatabasePathOverride {
            return try chatRepository.listChats(
                databasePath: chatDatabasePathOverride,
                limit: limit,
                kind: kind,
                detail: detail
            )
        }

        if !canAccessChatDatabaseDirectoryUsingBookmark {
            guard await showChatDatabaseDirectoryAccessAlert() else {
                throw DatabaseAccessError.userDeclinedAccess
            }
            let directoryURL = try await showChatDatabaseDirectoryPicker()
            try storeChatDatabaseDirectoryBookmark(for: directoryURL)
        }

        let directoryURL = try resolveChatDatabaseDirectoryBookmarkURL()
        return try withSecurityScopedAccess(directoryURL) { directoryURL in
            let databasePath = directoryURL.appendingPathComponent("chat.db").path
            do {
                return try chatRepository.listChats(
                    databasePath: databasePath,
                    limit: limit,
                    kind: kind,
                    detail: detail
                )
            } catch let error as MessagesChatRepositoryError {
                log.error(
                    "Chat listing failed stage=\(error.diagnosticStage, privacy: .public) sqliteCode=\(error.sqliteCode, privacy: .public)"
                )
                throw error
            }
        }
    }

    private enum SendDestination {
        case recipient(String)
        case recipients(Set<String>)
        case chat(String)
    }

    private enum PreparedSendDestination {
        case rawRecipient(String)
        case explicitChat(publicChatID: String, initial: MessagesResolvedChatDestination)
        case matched(
            publicChatID: String,
            expectedParticipants: Set<String>,
            initial: MessagesResolvedChatDestination
        )

        var isMatchedGroup: Bool {
            if case .matched(_, _, let initial) = self { return initial.kind == .group }
            return false
        }
    }

    private struct ResolvedSendInput {
        let destination: SendDestination
        let body: String
    }

    private func resolveSendInput(
        _ arguments: [String: Value],
        context: ToolCallContext
    ) async throws -> ResolvedSendInput {
        let recipient = arguments["recipient"]?.stringValue
        let recipientsValue = arguments["recipients"]
        let chatID = arguments["chat_id"]?.stringValue
        var body = arguments["body"]?.stringValue
        let suppliedDestinationCount = [recipient != nil, recipientsValue != nil, chatID != nil]
            .filter { $0 }.count
        guard suppliedDestinationCount == 1 else {
            throw MessageSendError.invalidDestination
        }

        var properties: [String: MCP.Value] = [:]
        var required: [String] = []
        if body == nil {
            properties["body"] = .object([
                "type": .string("string"),
                "description": .string("Plain-text message body"),
                "minLength": .int(1),
            ])
            required.append("body")
        }

        if !required.isEmpty {
            let response = try await context.elicitation.requestForm(
                message: "Provide the missing information required to prepare an iMessage.",
                schema: .init(
                    title: "Complete iMessage",
                    properties: properties,
                    required: required
                )
            )
            switch response.action {
            case .decline:
                throw MessageSendError.inputDeclined
            case .cancel:
                throw MessageSendError.inputCancelled
            case .accept:
                body = body ?? response.content?["body"]?.stringValue
            }
        }

        guard let body else {
            throw MessageSendError.inputMalformed
        }
        if let recipient {
            guard recipient.isExactMessageHandle else {
                throw MessageSendError.invalidRecipient
            }
            return ResolvedSendInput(destination: .recipient(recipient), body: body)
        }
        if let recipientsValue {
            guard case .array(let values) = recipientsValue else {
                throw MessageSendError.insufficientGroupParticipants
            }
            let handles = values.compactMap(\.stringValue)
            guard handles.count == values.count else {
                throw MessageSendError.invalidRecipient
            }
            let normalized = handles.compactMap(MessagesHandleNormalization.normalize)
            guard normalized.count == handles.count else { throw MessageSendError.invalidRecipient }
            let distinct = Set(normalized)
            guard distinct.count >= 2 else {
                throw MessageSendError.insufficientGroupParticipants
            }
            return ResolvedSendInput(destination: .recipients(distinct), body: body)
        }
        guard let chatID else { throw MessageSendError.invalidDestination }
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageSendError.invalidChatIdentifier
        }
        return ResolvedSendInput(destination: .chat(chatID), body: body)
    }

    private func resolveSendChat(_ chatID: String) async throws -> MessagesResolvedChatDestination {
        do {
            if let chatDatabasePathOverride {
                return try chatRepository.resolveChatDestination(
                    chatID,
                    databasePath: chatDatabasePathOverride
                )
            }
            let directoryURL = try resolveChatDatabaseDirectoryBookmarkURL()
            return try withSecurityScopedAccess(directoryURL) { directoryURL in
                try chatRepository.resolveChatDestination(
                    chatID,
                    databasePath: directoryURL.appendingPathComponent("chat.db").path
                )
            }
        } catch let error as MessagesChatRepositoryError {
            switch error {
            case .invalidIdentifier:
                throw MessageSendError.invalidChatIdentifier
            case .staleIdentifier:
                throw MessageSendError.staleChatIdentifier
            case .queryFailed(let stage, _) where stage == "resolve-duplicate":
                throw MessageSendError.ambiguousChatResolution
            default:
                throw MessageSendError.staleChatIdentifier
            }
        }
    }

    private func matchSendConversation(
        _ normalizedParticipants: Set<String>,
        kind: MessagesChatKind
    ) async throws -> MessagesConversationMatch {
        if let chatDatabasePathOverride {
            return try chatRepository.matchConversation(
                normalizedParticipants: normalizedParticipants,
                kind: kind,
                databasePath: chatDatabasePathOverride
            )
        }
        let directoryURL = try resolveChatDatabaseDirectoryBookmarkURL()
        return try withSecurityScopedAccess(directoryURL) { directoryURL in
            try chatRepository.matchConversation(
                normalizedParticipants: normalizedParticipants,
                kind: kind,
                databasePath: directoryURL.appendingPathComponent("chat.db").path
            )
        }
    }

    /// Builds the final authorization prompt for a recipient with no existing conversation.
    ///
    /// This prompt is the user-facing authorization surface, so it deliberately shows the
    /// exact destination and exact body that will be handed to the sender. Those values
    /// must never reach logs, diagnostics, errors, or tool results.
    private func rawRecipientConfirmationMessage(recipient: String, body: String) -> String {
        [
            "Submit this message as a new direct conversation?",
            "No existing conversation matches this recipient, so Messages will start a new direct conversation rather than replying in an existing thread.",
            "Recipient: \(recipient)",
            "Message:",
            body,
        ].joined(separator: "\n")
    }

    private func chatConfirmationMessage(
        _ chat: MessagesResolvedChatDestination,
        body: String,
        matchedFromParticipants: Bool = false
    ) -> String {
        let fallback = chat.participantHandles.first ?? "Unnamed conversation"
        let name = chat.displayName ?? (chat.kind == .direct ? fallback : "Unnamed group")
        var lines = [
            "Submit this message to the existing Messages conversation?",
            "Conversation: \(name)",
        ]
        if let roomName = chat.roomName, roomName != name {
            lines.append("Room: \(roomName)")
        }
        lines.append("Type: \(chat.kind.rawValue)")
        lines.append("Participant count: \(chat.participantCount)")
        if !chat.participantHandles.isEmpty {
            lines.append("Participants: \(chat.participantHandles.joined(separator: ", "))")
        }
        if let service = chat.service { lines.append("Service: \(service)") }
        if matchedFromParticipants {
            lines.append("This existing group exactly matches the supplied participants.")
            lines.append("No new group will be created.")
        } else {
            lines.append("An existing conversation will be used.")
        }
        lines.append("Message:")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: messagesDatabasePath)
    }

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case invalidParticipants
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .invalidParticipants:
                return "Invalid participants provided"
            case .userDeclinedAccess:
                return "User declined to grant access to the messages database"
            case .invalidFileSelected:
                return "Messages database access denied or invalid file selected"
            case .fileNotReadable:
                return "Selected database file is not readable"
            }
        }
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: messagesDatabaseBookmarkKey)
        else {
            throw DatabaseAccessError.noBookmarkFound
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func resolveChatDatabaseDirectoryBookmarkURL() throws -> URL {
        guard
            let bookmarkData = UserDefaults.standard.data(
                forKey: messagesDatabaseDirectoryBookmarkKey
            )
        else {
            throw DatabaseAccessError.noBookmarkFound
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else {
            throw DatabaseAccessError.noBookmarkFound
        }
        return url
    }

    private func createDatabaseConnection() throws -> iMessage.Database {
        if canAccessDatabaseAtDefaultPath {
            return try iMessage.Database()
        }

        let databaseURL = try resolveBookmarkURL()
        return try withSecurityScopedAccess(databaseURL) { url in
            try iMessage.Database(path: url.path)
        }
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkURL()
            return try withSecurityScopedAccess(url) { url in
                FileManager.default.isReadableFile(atPath: url.path)
            }
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    private var canAccessChatDatabaseDirectoryUsingBookmark: Bool {
        do {
            let directoryURL = try resolveChatDatabaseDirectoryBookmarkURL()
            return try withSecurityScopedAccess(directoryURL) { directoryURL in
                FileManager.default.isReadableFile(
                    atPath: directoryURL.appendingPathComponent("chat.db").path
                )
            }
        } catch {
            log.debug("No usable Messages directory bookmark is available")
            return false
        }
    }

    @MainActor
    private func requestChatListingDirectoryAccessIfNeeded() async {
        guard !canAccessChatDatabaseDirectoryUsingBookmark else { return }
        guard await showChatDatabaseDirectoryAccessAlert() else { return }

        do {
            let directoryURL = try await showChatDatabaseDirectoryPicker()
            try storeChatDatabaseDirectoryBookmark(for: directoryURL)
        } catch {
            log.notice("Messages directory access was not granted")
        }
    }

    @MainActor
    private func showChatDatabaseDirectoryAccessAlert() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Conversation Listing Needs Additional Access"
        alert.informativeText = """
            iMCP can list your existing direct and group conversations so MCP clients can identify and reply to existing threads.

            Conversation listing returns privacy-sensitive metadata about each conversation, including conversation identifiers, display and room names, whether it is direct or group, the handles and count of its participants, service metadata, archive, filter, and read state, activity timestamps, and — when requested in full detail — supported message-state, attachment-category, reaction-event, reply, edit, and related aggregate counts.

            It does not return message bodies, attachment filenames, attachment file paths, attachment contents, or account credentials.

            This requires read-only access to the Messages folder so SQLite can read `chat.db` together with its companion files. Conversation listing does not use Apple Events and does not send messages.

            Select the Messages folder in the next screen to enable conversation listing. Existing message fetching and sending permissions are unchanged.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showChatDatabaseDirectoryPicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.message = "Select the Messages folder containing chat.db"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = URL(fileURLWithPath: messagesDatabasePath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK, let directoryURL = openPanel.url else {
            throw DatabaseAccessError.invalidFileSelected
        }
        guard
            FileManager.default.isReadableFile(
                atPath: directoryURL.appendingPathComponent("chat.db").path
            )
        else {
            throw DatabaseAccessError.fileNotReadable
        }
        return directoryURL
    }

    private func storeChatDatabaseDirectoryBookmark(for directoryURL: URL) throws {
        let bookmarkData = try directoryURL.bookmarkData(
            options: Self.readOnlySecurityScopedBookmarkOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: messagesDatabaseDirectoryBookmarkKey)
        log.debug("Stored read-only Messages directory bookmark")
    }

    @MainActor
    private func showDatabaseAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Messages Database Access Required"
        alert.informativeText = """
            To read your Messages history, we need to open your database file.

            In the next screen, please select the file `chat.db` and click "Grant Access".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showFilePicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message = "Please select the Messages database file (chat.db)"
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [UTType.item]
        openPanel.directoryURL = URL(fileURLWithPath: messagesDatabasePath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            url.lastPathComponent == "chat.db"
        else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: Self.readOnlySecurityScopedBookmarkOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: messagesDatabaseBookmarkKey)
            log.debug("Successfully created and stored bookmark")
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    // NSOpenSavePanelDelegate method to constrain file selection
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = url.lastPathComponent == "chat.db"
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}

private struct MessageSubmissionResult: Encodable {
    let status: String
    let service: String
}

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
let messagesSendConfirmationRequiredKey = "messagesSendConfirmationRequired"
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

    private let sender: any MessagesSending
    private let requiresSendConfirmation: @Sendable () -> Bool
    private let chatRepository: any MessagesChatListing
    private let chatDatabasePathOverride: String?
    private let chatListingLog: @Sendable (Int) -> Void

    init(
        sender: any MessagesSending = AppleScriptMessagesSender(),
        requiresSendConfirmation: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.object(forKey: messagesSendConfirmationRequiredKey) as? Bool
                ?? true
        },
        chatRepository: any MessagesChatListing = SQLiteMessagesChatRepository(),
        chatDatabasePathOverride: String? = nil,
        chatListingLog: @escaping @Sendable (Int) -> Void = { count in
            log.notice("Listed \(count) Messages conversations")
        }
    ) {
        self.sender = sender
        self.requiresSendConfirmation = requiresSendConfirmation
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
                "List existing Messages conversations and schema-supported metadata without returning message contents, attachment names, or file paths.",
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
                "Submit one plain-text message to either one exact recipient handle or one existing Messages conversation identified by messages_list_chats. Existing-chat sends always require confirmation.",
            inputSchema: .object(
                properties: [
                    "recipient": .string(
                        description: "One exact E.164 phone number or email address"
                    ),
                    "chat_id": .string(
                        description:
                            "Opaque chat ID returned by messages_list_chats; do not supply a database or scripting identifier",
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

            let initialChat: MessagesResolvedChatDestination?
            switch input.destination {
            case .recipient:
                initialChat = nil
            case .chat(let chatID):
                initialChat = try await self.resolveSendChat(chatID)
            }

            if initialChat != nil || self.requiresSendConfirmation() {
                let confirmationMessage: String
                let confirmationTitle: String
                if let initialChat {
                    confirmationMessage = self.chatConfirmationMessage(
                        initialChat,
                        body: input.body
                    )
                    confirmationTitle = "Confirm existing-chat submission"
                } else {
                    confirmationMessage =
                        "Submit this iMessage to Messages? Recipient and message text are intentionally omitted."
                    confirmationTitle = "Confirm iMessage submission"
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
            } else {
                log.warning("Messages confirmation is disabled; proceeding without elicitation")
            }

            try Task.checkCancellation()
            switch input.destination {
            case .recipient(let recipient):
                try await self.sender.submit(recipient: recipient, body: input.body)
                log.notice("Messages accepted one submission destination=recipient")
                return MessageSubmissionResult(status: "submitted", service: "iMessage")
            case .chat(let chatID):
                guard let initialChat else { throw MessageSendError.staleChatIdentifier }
                let revalidatedChat = try await self.resolveSendChat(chatID)
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
        case chat(String)
    }

    private struct ResolvedSendInput {
        let destination: SendDestination
        let body: String
    }

    private func resolveSendInput(
        _ arguments: [String: Value],
        context: ToolCallContext
    ) async throws -> ResolvedSendInput {
        var recipient = arguments["recipient"]?.stringValue
        let chatID = arguments["chat_id"]?.stringValue
        var body = arguments["body"]?.stringValue
        guard recipient == nil || chatID == nil else {
            throw MessageSendError.invalidDestination
        }

        var properties: [String: MCP.Value] = [:]
        var required: [String] = []
        if recipient == nil, chatID == nil {
            properties["recipient"] = .object([
                "type": .string("string"),
                "description": .string("One exact E.164 phone number or email address"),
            ])
            required.append("recipient")
        }
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
                recipient = recipient ?? response.content?["recipient"]?.stringValue
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

    private func chatConfirmationMessage(
        _ chat: MessagesResolvedChatDestination,
        body: String
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
            iMCP can list existing direct and group conversations with limited metadata such as display name, conversation type, participant count, service, and latest activity timestamp. This lets MCP clients identify and reply to existing threads, including group chats.

            This requires read-only access to the Messages folder so SQLite can read `chat.db` together with its companion files. Conversation listing does not use Apple Events, send messages, or return message contents or participant lists.

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
            options: .securityScopeAllowOnlyReadAccess,
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
                options: .securityScopeAllowOnlyReadAccess,
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

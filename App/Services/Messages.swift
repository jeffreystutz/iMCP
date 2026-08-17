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
/// Finite scan/result budget for `messages_fetch`. The database fetch always scans up
/// to this many rows regardless of the requested limit, so the content-text filter has
/// a fixed, bounded pool of candidates to search — this must stay a hard ceiling, not
/// just a default, or a large requested limit could force an unbounded database scan.
private let maximumFetchLimit = 1024
/// Bounds for conversation discovery.
///
/// The handle bound is sized for the fan-out of one contact search — a handful of candidate
/// people, each with a few phone numbers and email addresses — rather than for bulk export.
/// The per-handle bound applies independently to each supplied handle, so one very active
/// candidate cannot consume another candidate's result budget.
private let maximumConversationSearchHandles = 20
/// Shared with the cross-service composite, which applies the same per-identity bound to
/// the same operation.
let defaultConversationsPerHandle = 10
let maximumConversationsPerHandle = 25

enum MessagesChatListingError: LocalizedError, Equatable, Sendable {
    case invalidLimit
    case invalidKind
    case invalidDetail
    case invalidParticipants

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "The chat limit must be an integer from 1 through 100."
        case .invalidKind:
            return "The chat kind must be direct or group."
        case .invalidDetail:
            return "The chat detail must be summary or full."
        case .invalidParticipants:
            return "The participant filter must contain at least one usable participant identity."
        }
    }
}

enum MessagesFetchError: LocalizedError, Equatable, Sendable {
    case invalidLimit

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "The message limit must be an integer from 1 through \(maximumFetchLimit)."
        }
    }
}

/// Validates and resolves the `messages_fetch` `limit` argument.
///
/// Extracted from the tool closure so the bound can be exercised directly in tests
/// without triggering Messages database activation, and so a malformed request is
/// rejected before it can ever reach the database.
func resolveMessagesFetchLimit(_ value: Value?) throws -> Int {
    guard let value else { return defaultLimit }
    guard let requestedLimit = value.intValue,
        (1 ... maximumFetchLimit).contains(requestedLimit)
    else {
        throw MessagesFetchError.invalidLimit
    }
    return requestedLimit
}

/// Input failures for conversation discovery.
///
/// None of these carries the rejected value. A malformed handle is still a private
/// identity, and upper layers may interpolate an error into a message the model sees.
enum MessagesConversationSearchError: LocalizedError, Equatable, Sendable {
    case invalidHandles
    case tooManyHandles
    case invalidLimit

    var errorDescription: String? {
        switch self {
        case .invalidHandles:
            return
                "Every handle must be one exact E.164 phone number or email address. Supply at least one."
        case .tooManyHandles:
            return
                "A conversation search accepts at most \(maximumConversationSearchHandles) handles."
        case .invalidLimit:
            return
                "The per-handle conversation limit must be an integer from 1 through \(maximumConversationsPerHandle)."
        }
    }
}

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate,
    MessagesConversationLookup
{
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
    private let composer: any MessagesNewRecipientComposing
    private let chatRepository: any MessagesChatListing
    private let conversationSearch: any MessagesConversationSearching
    private let sendConfirmationRequester: any MessagesFinalSendConfirmationRequesting
    private let attachmentSelector: any MessagesAttachmentSelecting
    private let attachmentValidator: any MessagesAttachmentValidating
    private let chatDatabasePathOverride: String?
    private let chatListingLog: @Sendable (Int) -> Void
    private let sendingMode: @Sendable () -> MessagesSendingMode

    init(
        sender: any MessagesSending = AppleScriptMessagesSender(),
        composer: any MessagesNewRecipientComposing = SystemMessagesComposer(),
        chatRepository: any MessagesChatListing = SQLiteMessagesChatRepository(),
        conversationSearch: any MessagesConversationSearching = SQLiteMessagesChatRepository(),
        sendConfirmationRequester: any MessagesFinalSendConfirmationRequesting =
            MessagesFinalSendConfirmationRequester(),
        attachmentSelector: any MessagesAttachmentSelecting =
            OpenPanelMessagesAttachmentSelector(),
        attachmentValidator: any MessagesAttachmentValidating =
            FileManagerMessagesAttachmentValidator(),
        chatDatabasePathOverride: String? = nil,
        chatListingLog: @escaping @Sendable (Int) -> Void = { count in
            log.notice("Listed \(count) Messages conversations")
        },
        sendingMode: @escaping @Sendable () -> MessagesSendingMode = {
            MessagesSendingMode.load()
        }
    ) {
        self.sender = sender
        self.composer = composer
        self.chatRepository = chatRepository
        self.conversationSearch = conversationSearch
        self.sendConfirmationRequester = sendConfirmationRequester
        self.attachmentSelector = attachmentSelector
        self.attachmentValidator = attachmentValidator
        self.chatDatabasePathOverride = chatDatabasePathOverride
        self.chatListingLog = chatListingLog
        self.sendingMode = sendingMode
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
                    "participants": .array(
                        description:
                            "Optionally return conversations containing every supplied participant identity; additional conversation participants are allowed",
                        items: .string(),
                        minItems: 1
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

            let participants: Set<String>?
            if let value = arguments["participants"] {
                guard let requested = value.arrayValue, !requested.isEmpty else {
                    throw MessagesChatListingError.invalidParticipants
                }
                var identities: Set<String> = []
                for value in requested {
                    guard let handle = value.stringValue,
                        let identity = MessagesHandleIdentity.identity(handle)
                    else { throw MessagesChatListingError.invalidParticipants }
                    identities.insert(identity)
                }
                participants = identities
            } else {
                participants = nil
            }

            let start = ContinuousClock.now
            let index = try await self.listChats(
                limit: limit,
                kind: kind,
                participants: participants,
                detail: detail
            )
            self.chatListingLog(index.chats.count)
            let elapsed = start.duration(to: .now)
            log.notice(
                "Listed Messages conversations detail=\(detail.rawValue, privacy: .public) count=\(index.chats.count) elapsed=\(String(describing: elapsed), privacy: .public)"
            )
            return index
        }

        Tool(
            name: "messages_find_conversations",
            description:
                "Find the existing Messages conversations associated with exact phone or email handles you already have, such as the communication identities returned by contacts_search. Each supplied handle gets its own result holding the direct and group conversations that include it, newest first, with participants, service, and latest activity. Group conversations are returned as context about who a handle talks with; that never implies a later message should go to a group. This tool does not search contacts, resolve names, rank people, choose a destination, recommend a recipient, or send anything, and it never converts a local phone number into E.164. Read the per-handle lookupCompleteness before concluding that a handle has no conversations.",
            inputSchema: .object(
                properties: [
                    "handles": .array(
                        description:
                            "Exact communication handles to look up. Each must be a strict E.164 phone number or a valid email address; nothing is inferred or rewritten, and one invalid entry fails the whole request.",
                        items: .string(
                            description: "One exact E.164 phone number or email address"
                        ),
                        minItems: 1,
                        maxItems: maximumConversationSearchHandles
                    ),
                    "limit": .integer(
                        description:
                            "Maximum conversations returned for each supplied handle, applied independently per handle",
                        default: .int(defaultConversationsPerHandle),
                        minimum: 1,
                        maximum: maximumConversationsPerHandle
                    ),
                ],
                required: ["handles"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Find Messages Conversations",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // Every input is validated before the database is opened, so a malformed
            // request never becomes a query.
            guard let requested = arguments["handles"]?.arrayValue, !requested.isEmpty else {
                throw MessagesConversationSearchError.invalidHandles
            }
            guard requested.count <= maximumConversationSearchHandles else {
                throw MessagesConversationSearchError.tooManyHandles
            }
            var handles: [String] = []
            for value in requested {
                guard case let .string(handle) = value,
                    let normalized = MessagesHandleNormalization.normalize(handle)
                else { throw MessagesConversationSearchError.invalidHandles }
                handles.append(normalized)
            }

            let limit: Int
            if let value = arguments["limit"] {
                guard let requestedLimit = value.intValue,
                    (1 ... maximumConversationsPerHandle).contains(requestedLimit)
                else { throw MessagesConversationSearchError.invalidLimit }
                limit = requestedLimit
            } else {
                limit = defaultConversationsPerHandle
            }

            let start = ContinuousClock.now
            let result = try await self.findConversations(handles: handles, limitPerHandle: limit)
            let elapsed = start.duration(to: .now)
            let conversationCount = result.results.reduce(0) { $0 + $1.conversations.count }
            log.notice(
                "Searched Messages conversations handles=\(handles.count, privacy: .public) conversations=\(conversationCount, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
            )
            return result
        }

        Tool(
            name: "messages_fetch",
            description: """
                Fetch existing messages from the Messages app. Read-only: this tool never sends, \
                composes, or modifies anything. Optionally filter by participant handles (phone \
                or email), a date range, and/or a content search term. Results are bounded by \
                `limit` (default \(defaultLimit), maximum \(maximumFetchLimit)) and returned \
                newest-first.
                """,
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
                        default: .int(defaultLimit),
                        minimum: 1,
                        maximum: maximumFetchLimit
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
            log.debug(
                "Starting message fetch hasParticipants=\(arguments["participants"] != nil, privacy: .public) hasDateRange=\(arguments["start"] != nil && arguments["end"] != nil, privacy: .public) hasQuery=\(arguments["query"] != nil, privacy: .public)"
            )

            // Every input is validated before the database is opened, so a malformed
            // request never becomes a query.
            let limit = try resolveMessagesFetchLimit(arguments["limit"])

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

            let db = try self.createDatabaseConnection()
            var messages: [[String: Value]] = []

            log.debug("Fetching handles for participants=\(participants.count, privacy: .public)")
            let handles = try db.fetchParticipant(matching: participants)

            log.debug(
                "Fetching messages hasDateRange=\(dateRange != nil, privacy: .public) limit=\(limit, privacy: .public)"
            )
            for message in try db.fetchMessages(
                with: Set(handles),
                in: dateRange,
                limit: maximumFetchLimit
            ) {
                guard messages.count < limit else { break }
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
            name: "message_send_text",
            description:
                "Send one plain-text message to exactly one destination, by one of two routes that never fall back to each other. A recipient that uniquely matches one existing direct conversation, or an explicit chat_id, is submitted to that existing conversation, showing the exact destination and body. Whether that submission requires the user's confirmation first, or submits directly, follows the user's Sending mode setting in iMCP; there is no way for a caller to choose or override it. A recipient verified to have no existing conversation instead opens a Messages compose window, seeded with that recipient and body, which you review and send yourself; because you can edit it there, iMCP does not confirm it first and cannot report what was ultimately sent, and this route is unaffected by the Sending mode setting. Ambiguous or unresolvable matching fails without sending. Recipients can address only an existing group conversation: iMCP cannot create a new group from a list, and the complete participant set must exactly match one existing group or the call fails without sending. When multiple groups have the same participant set, use chat_id; chat_id is preferred when the intended group is already known. Messages chooses iMessage, SMS, or RCS; this tool never selects it.",
            inputSchema: .object(
                properties: [
                    "recipient": .string(
                        description:
                            "One exact E.164 phone number or email address. A unique existing direct conversation is submitted to, subject to the user's Sending mode setting. A recipient verified to have no existing conversation instead opens a user-controlled Messages compose window seeded with this recipient and body, which the user reviews, may edit, and sends personally. Ambiguous or unresolvable matching fails without sending."
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
                title: "Send Message",
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
            return try await self.sendText(
                destination: input.destination,
                body: input.body,
                context: context
            )
        }

        Tool(
            name: "message_send_attachment",
            description:
                "Submit exactly one file as an attachment to one existing Messages conversation that you identify by recipient, recipients, or chat_id. This tool takes no file path, no file name, and no file contents: after the destination resolves, iMCP always opens a native file picker on the user's Mac and the user chooses the file there. Whether the user must then separately confirm the exact conversation together with the file's name, type, and size before it sends, or it submits directly after the picker, follows the user's Sending mode setting in iMCP; there is no way for a caller to choose or override it, and the picker itself is never treated as that authorization. It sends no message text, so it cannot carry a caption or a body; send any accompanying text as its own message_send_text call. The file must be one ordinary image, video or audio, PDF, or plain-text file of at most 25 MiB. Unlike message_send_text, a recipient with no existing conversation fails instead of opening a compose window, and no new conversation or group is ever created, in either mode. Cancelling the picker, or the confirmation when one is presented, sends nothing. Success means Messages accepted one attachment submission, never that it was delivered.",
            inputSchema: .object(
                properties: [
                    "recipient": .string(
                        description:
                            "One exact E.164 phone number or email address that must already have exactly one existing direct conversation. A recipient with no existing conversation, or an ambiguous or unresolvable match, fails without opening the picker and without sending."
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
                            "Opaque chat ID returned by messages_list_chats that explicitly selects an existing direct or group conversation; preferred when the intended conversation is already known. Do not supply a database or scripting identifier.",
                        minLength: 1
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Messages Attachment",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments, context in
            let destination = try self.resolveAttachmentDestination(arguments)
            return try await self.sendAttachment(
                destination: destination,
                context: context
            )
        }
    }

    private struct ResolvedSendInput {
        let destination: SendDestination
        let body: String
    }

    /// Validates `message_send_text`'s destination selectors and resolves the message
    /// body, eliciting it through the existing MCP form mechanism when the caller omits
    /// it. Accepting that elicitation supplies the body; it is never itself final send
    /// authorization, which remains a separate step in `sendText`.
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
                message: "Provide the missing information required to prepare a message.",
                schema: .init(
                    title: "Complete Message",
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

    /// Existing-conversation plain-text submission, or verified-new-recipient composition.
    private func sendText(
        destination: SendDestination,
        body: String,
        context: ToolCallContext
    ) async throws -> MessageSendResult {
        guard !body.isEmpty else {
            throw MessageSendError.emptyBody
        }

        let preparedDestination = try await self.prepareDestination(destination)

        // A recipient with no existing conversation is composed, not submitted.
        // Authorization for this mode is the human's own review and Send action in
        // the system-owned Messages panel, so iMCP requests no final confirmation:
        // recipient and body stay editable there, and an earlier immutable
        // confirmation could not honestly authorize whatever is ultimately sent.
        if case .newRecipient(let recipient) = preparedDestination {
            try Task.checkCancellation()
            _ = try await self.composer.compose(
                seedRecipient: recipient,
                seedBody: body
            )
            log.notice(
                "User completed a Messages composition mode=system_messages_compose"
            )
            return MessageSendResult.userCompletedComposition
        }

        try await self.preflightAddressabilityIfAuthorized(preparedDestination)

        // Every existing-conversation form must be authorized before it proceeds:
        // either the required final confirmation in Ask Before Sending mode, or the
        // user's persisted app-owned Send Automatically setting. Composition already
        // returned above, so anything reaching here resolved to an existing
        // conversation. Automatic mode bypasses only this authorization step; every
        // step after it — cancellation, revalidation, Automation/addressability,
        // dispatch, logging, and result — is identical for both modes.
        guard let initialChat = preparedDestination.initialChat else {
            throw MessageSendError.invalidDestination
        }
        switch self.sendingMode() {
        case .askBeforeSending:
            let confirmationPresentation = MessagesSendConfirmationPresentation(
                title: "Confirm existing-chat submission",
                message: self.chatConfirmationMessage(
                    initialChat,
                    body: body,
                    matchedFromParticipants: preparedDestination.isMatchedGroup
                )
            )
            try await self.sendConfirmationRequester.requestConfirmation(
                confirmationPresentation,
                elicitation: context.elicitation
            )
        case .sendAutomatically:
            break
        }

        try Task.checkCancellation()
        let revalidatedChat = try await self.revalidateDestination(preparedDestination)
        try Task.checkCancellation()
        try await self.authorizeAndVerifyAddressability(revalidatedChat.chatGuid)
        try await self.sender.submit(
            chatGUID: revalidatedChat.chatGuid,
            body: body
        )
        log.notice(
            "Messages accepted one submission \(preparedDestination.submissionLogFields, privacy: .public)"
        )
        return MessageSendResult.submitted(service: "Messages")
    }

    /// Existing-conversation picker-based attachment submission for `message_send_attachment`.
    private func sendAttachment(
        destination: SendDestination,
        context: ToolCallContext
    ) async throws -> MessageSendResult {
        // 1. The destination is resolved to one exact existing conversation before a
        //    picker is ever presented. Nothing about the file is known yet, so a bad
        //    destination costs the user no file selection.
        let preparedDestination = try await self.prepareDestination(destination)

        // A verified-new recipient is out of scope for attachments. It fails here,
        // categorically, without reaching system composition: the sharing service
        // cannot address a chosen existing conversation, so using it would silently
        // change what the caller asked for.
        if case .newRecipient = preparedDestination {
            throw MessageSendError.attachmentRequiresExistingConversation
        }

        // 2. Same non-prompting preflight as a text submission. No TCC prompt may
        //    precede the final confirmation.
        try await self.preflightAddressabilityIfAuthorized(preparedDestination)
        guard let initialChat = preparedDestination.initialChat else {
            throw MessageSendError.invalidDestination
        }

        // 3. Only now is the picker presented, and the selection is validated against
        //    the bounded file policy before the user is asked to authorize anything.
        try Task.checkCancellation()
        let selectedURL = try await self.attachmentSelector.selectAttachment()
        // Read access is held from validation through the synchronous submission, so
        // the facts that were authorized are the facts the Apple Event carries.
        let access = MessagesAttachmentAccess(url: selectedURL)
        defer { access.release() }
        let facts = try self.attachmentValidator.validate(selectedURL)

        // 4. Authorization: either one immutable confirmation naming the exact
        //    conversation and the file's display name, public type, and size (never
        //    its path or its contents), in Ask Before Sending mode, or the user's
        //    persisted app-owned Send Automatically setting. The native picker above
        //    is still the only file-input/selection mechanism in either mode — it is
        //    never itself treated as authorization, and automatic mode does not add a
        //    second confirmation after it.
        switch self.sendingMode() {
        case .askBeforeSending:
            try await self.sendConfirmationRequester.requestConfirmation(
                MessagesSendConfirmationPresentation(
                    title: "Confirm existing-chat attachment submission",
                    message: self.attachmentConfirmationMessage(
                        initialChat,
                        attachment: facts,
                        matchedFromParticipants: preparedDestination.isMatchedGroup
                    )
                ),
                elicitation: context.elicitation
            )
        case .sendAutomatically:
            break
        }

        // 5. The destination must still be exactly the conversation that was shown.
        try Task.checkCancellation()
        let revalidatedChat = try await self.revalidateDestination(preparedDestination)

        // 6. The file must still be the same file with the same bounded properties. A
        //    file that was removed, replaced, modified, enlarged, or has become an
        //    unsupported type fails here, with zero dispatch.
        let revalidatedFacts = try self.attachmentValidator.validate(selectedURL)
        guard revalidatedFacts == facts else {
            throw MessagesAttachmentError.attachmentChanged
        }

        // 7. Automation authority is requested only now, after authorization, and
        //    addressability is rechecked immediately before dispatch.
        try Task.checkCancellation()
        try await self.authorizeAndVerifyAddressability(revalidatedChat.chatGuid)

        // 8. Exactly one dispatch. There is no retry, queue, alternate conversation,
        //    sharing-service fallback, or second submission on any outcome.
        try await self.sender.submitChatAttachment(
            chatGUID: revalidatedChat.chatGuid,
            attachmentFile: revalidatedFacts.url
        )
        log.notice(
            "Messages accepted one attachment submission \(preparedDestination.submissionLogFields, privacy: .public)"
        )
        return MessageSendResult.attachmentSubmitted(service: "Messages")
    }

    /// Resolves one exact existing conversation, or the verified absence of one.
    ///
    /// Both send tools share this so that "which conversation is this" is answered
    /// identically for text and for an attachment. Only the treatment of a verified-new
    /// recipient differs, and that decision belongs to each tool.
    private func prepareDestination(
        _ destination: SendDestination
    ) async throws -> PreparedSendDestination {
        switch destination {
        case .recipient(let recipient):
            let participants = Set([MessagesHandleNormalization.normalize(recipient)!])
            switch try await matchSendConversation(participants, kind: .direct) {
            case .none:
                // Only a verified absence of any matching conversation is reported as a
                // new recipient. Unresolved membership is not evidence of absence, and no
                // failure of another route ever arrives here.
                return .newRecipient(recipient)
            case .incomplete:
                throw MessageSendError.incompleteDirectMembership
            case .ambiguous:
                throw MessageSendError.ambiguousDirectConversation
            case .unique(let publicChatID, let destination):
                return .matched(
                    publicChatID: publicChatID,
                    expectedParticipants: participants,
                    initial: destination
                )
            }
        case .recipients(let participants):
            switch try await matchSendConversation(participants, kind: .group) {
            case .none:
                throw MessageSendError.groupConversationNotFound
            case .incomplete:
                throw MessageSendError.incompleteGroupMembership
            case .ambiguous:
                throw MessageSendError.ambiguousGroupConversation
            case .unique(let publicChatID, let destination):
                return .matched(
                    publicChatID: publicChatID,
                    expectedParticipants: participants,
                    initial: destination
                )
            }
        case .chat(let chatID):
            return .explicitChat(
                publicChatID: chatID,
                initial: try await resolveSendChat(chatID)
            )
        }
    }

    /// Messages exposes only a bounded, recency-biased subset of its conversations to
    /// automation, so a valid database conversation can be temporarily unaddressable.
    /// Establishing that before confirmation spares the user from authorizing a
    /// submission that could not be dispatched.
    ///
    /// The probe is an Apple Event, so it runs only where it cannot cause a permission
    /// prompt: no TCC prompt may ever precede the final confirmation.
    private func preflightAddressabilityIfAuthorized(
        _ preparedDestination: PreparedSendDestination
    ) async throws {
        guard let initialChat = preparedDestination.initialChat else { return }
        switch await sender.automationAuthorization() {
        case .denied:
            throw MessageSendError.automationDenied
        case .authorized:
            guard try await sender.isChatAddressable(chatGUID: initialChat.chatGuid) else {
                throw MessageSendError.chatUnavailableInAutomation
            }
        case .consentRequired, .unknown:
            // Probing now could prompt. Addressability is verified after the user
            // authorizes the submission instead.
            break
        }
    }

    /// Re-resolves the confirmed destination and requires exact equality with what was
    /// authorized. Anything else fails closed, before any permission request or dispatch.
    private func revalidateDestination(
        _ preparedDestination: PreparedSendDestination
    ) async throws -> MessagesResolvedChatDestination {
        switch preparedDestination {
        case .newRecipient:
            // Composition never reaches a dispatch router, and an attachment refuses this
            // destination outright.
            throw MessageSendError.invalidDestination
        case .explicitChat(let publicChatID, let initialChat):
            let revalidatedChat = try await resolveSendChat(publicChatID)
            guard revalidatedChat == initialChat else {
                throw MessageSendError.staleChatIdentifier
            }
            return revalidatedChat
        case .matched(let publicChatID, let expectedParticipants, let initial):
            let match = try await matchSendConversation(expectedParticipants, kind: initial.kind)
            guard case .unique(let revalidatedID, let revalidatedChat) = match,
                revalidatedID == publicChatID,
                revalidatedChat == initial
            else { throw MessageSendError.staleMatchedConversation }
            return revalidatedChat
        }
    }

    /// Validates the attachment tool's destination selectors.
    ///
    /// It accepts exactly the same mutually exclusive selectors as `message_send_text`, and
    /// deliberately accepts nothing else: there is no path, URL, file name, byte, body, or
    /// attachment identifier in this tool's arguments.
    private func resolveAttachmentDestination(
        _ arguments: [String: Value]
    ) throws -> SendDestination {
        let recipient = arguments["recipient"]?.stringValue
        let recipientsValue = arguments["recipients"]
        let chatID = arguments["chat_id"]?.stringValue
        let suppliedDestinationCount = [recipient != nil, recipientsValue != nil, chatID != nil]
            .filter { $0 }.count
        guard suppliedDestinationCount == 1 else {
            throw MessageSendError.invalidDestination
        }

        if let recipient {
            guard recipient.isExactMessageHandle else {
                throw MessageSendError.invalidRecipient
            }
            return .recipient(recipient)
        }
        if let recipientsValue {
            guard case .array(let values) = recipientsValue else {
                throw MessageSendError.insufficientGroupParticipants
            }
            let handles = values.compactMap(\.stringValue)
            guard handles.count == values.count else { throw MessageSendError.invalidRecipient }
            let normalized = handles.compactMap(MessagesHandleNormalization.normalize)
            guard normalized.count == handles.count else { throw MessageSendError.invalidRecipient }
            let distinct = Set(normalized)
            guard distinct.count >= 2 else {
                throw MessageSendError.insufficientGroupParticipants
            }
            return .recipients(distinct)
        }
        guard let chatID else { throw MessageSendError.invalidDestination }
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageSendError.invalidChatIdentifier
        }
        return .chat(chatID)
    }

    /// Runs one read-only conversation-database operation under the directory-scoped
    /// bookmark, requesting that read access once if it has not been granted yet.
    ///
    /// This is the read model both conversation-index tools share. It opens no Apple Event
    /// connection, requests no Automation authority, and adds no entitlement.
    private func withChatDatabase<T>(
        stage: String,
        _ operation: (String) throws -> T
    ) async throws -> T {
        let databasePath: String
        let directoryURL: URL?
        if let chatDatabasePathOverride {
            databasePath = chatDatabasePathOverride
            directoryURL = nil
        } else {
            if !canAccessChatDatabaseDirectoryUsingBookmark {
                guard await showChatDatabaseDirectoryAccessAlert() else {
                    throw DatabaseAccessError.userDeclinedAccess
                }
                let selectedURL = try await showChatDatabaseDirectoryPicker()
                try storeChatDatabaseDirectoryBookmark(for: selectedURL)
            }
            let resolvedURL = try resolveChatDatabaseDirectoryBookmarkURL()
            directoryURL = resolvedURL
            databasePath = resolvedURL.appendingPathComponent("chat.db").path
        }

        func run() throws -> T {
            do {
                return try operation(databasePath)
            } catch let error as MessagesChatRepositoryError {
                // Only the stage name and the numeric SQLite code are diagnosable. No
                // handle, participant, chat identity, or row content may be logged.
                log.error(
                    "\(stage, privacy: .public) failed stage=\(error.diagnosticStage, privacy: .public) sqliteCode=\(error.sqliteCode, privacy: .public)"
                )
                throw error
            }
        }

        guard let directoryURL else { return try run() }
        return try withSecurityScopedAccess(directoryURL) { _ in try run() }
    }

    private func listChats(
        limit: Int,
        kind: MessagesChatKind?,
        participants: Set<String>?,
        detail: MessagesChatDetail
    ) async throws -> MessagesConversationIndex {
        try await withChatDatabase(stage: "chat-listing") { databasePath in
            try chatRepository.listChats(
                databasePath: databasePath,
                limit: limit,
                kind: kind,
                participants: participants,
                detail: detail
            )
        }
    }

    /// The Messages service's complete conversation lookup, satisfying
    /// `MessagesConversationLookup`.
    ///
    /// The `messages_find_conversations` adapter and the cross-service composite both come
    /// through here, so both get the same database access, the same search, and the same
    /// failures. Handles must already be normalized: this rewrites nothing.
    func findConversations(
        handles: [String],
        limitPerHandle: Int
    ) async throws -> MessagesConversationSearchResult {
        try await withChatDatabase(stage: "conversation-search") { databasePath in
            try conversationSearch.findConversations(
                handles: handles,
                limitPerHandle: limitPerHandle,
                databasePath: databasePath
            )
        }
    }

    private enum SendDestination {
        case recipient(String)
        case recipients(Set<String>)
        case chat(String)
    }

    private enum PreparedSendDestination {
        case newRecipient(String)
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

        /// The existing conversation this send resolved to, when it resolved to one.
        var initialChat: MessagesResolvedChatDestination? {
            switch self {
            case .newRecipient:
                return nil
            case .explicitChat(_, let initial), .matched(_, _, let initial):
                return initial
            }
        }

        /// Categorical fields describing how one accepted submission was addressed.
        ///
        /// Every component is a fixed keyword or an enumeration case. No handle,
        /// participant set, chat identifier, body, or attachment fact appears here.
        var submissionLogFields: String {
            switch self {
            case .newRecipient:
                return "destination=none"
            case .explicitChat(_, let initial):
                return "destination=chat kind=\(initial.kind.rawValue)"
            case .matched(_, _, let initial):
                let selector = initial.kind == .group ? "recipients" : "recipient"
                return
                    "destination=\(selector) resolution=unique path=existing-chat kind=\(initial.kind.rawValue)"
            }
        }
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

    /// Obtains Messages Automation authority, then reconfirms that Messages still
    /// exposes this exact chat.
    ///
    /// Only the user's accepted confirmation may lead here, because this is the step
    /// that can present the system Automation prompt. The pre-confirmation probe is
    /// an optimization and reserves nothing: a conversation can leave the scripting
    /// window at any moment, so this guard runs immediately before every dispatch.
    private func authorizeAndVerifyAddressability(_ chatGUID: String) async throws {
        try await sender.requestAutomationAuthorization()
        guard try await sender.isChatAddressable(chatGUID: chatGUID) else {
            throw MessageSendError.chatUnavailableInAutomation
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

    /// Builds the final authorization prompt for an existing conversation.
    ///
    /// This prompt is the user-facing authorization surface, so it deliberately shows the
    /// exact destination and exact body that will be handed to the sender. Those values
    /// must never reach logs, diagnostics, errors, or tool results.
    ///
    /// There is no counterpart for a new recipient: that mode is authorized in the
    /// system-owned Messages panel, where both values remain editable.
    private func chatConfirmationMessage(
        _ chat: MessagesResolvedChatDestination,
        body: String,
        matchedFromParticipants: Bool = false
    ) -> String {
        var lines = ["Submit this message to the existing Messages conversation?"]
        lines.append(
            contentsOf: destinationLines(chat, matchedFromParticipants: matchedFromParticipants)
        )
        lines.append("Message:")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    /// Builds the final authorization prompt for one attachment submission.
    ///
    /// It authorizes an attachment, not a message body, and says so: this call cannot
    /// carry text. It shows the file's display name, public type description, and
    /// formatted size, because those are what the user is authorizing. It never shows the
    /// file's path or any of its contents, and none of these facts may reach a log,
    /// diagnostic, error, or tool result.
    private func attachmentConfirmationMessage(
        _ chat: MessagesResolvedChatDestination,
        attachment: MessagesAttachmentFacts,
        matchedFromParticipants: Bool = false
    ) -> String {
        var lines = ["Submit this attachment to the existing Messages conversation?"]
        lines.append(
            contentsOf: destinationLines(chat, matchedFromParticipants: matchedFromParticipants)
        )
        lines.append("Attachment: \(attachment.displayName)")
        lines.append("File type: \(attachment.typeDescription)")
        lines.append("Size: \(attachment.formattedSize)")
        lines.append("One file will be submitted as an attachment.")
        lines.append("No message text will be sent with it.")
        return lines.joined(separator: "\n")
    }

    /// The exact destination shown on every existing-conversation authorization surface.
    private func destinationLines(
        _ chat: MessagesResolvedChatDestination,
        matchedFromParticipants: Bool
    ) -> [String] {
        let fallback = chat.participantHandles.first ?? "Unnamed conversation"
        let name = chat.displayName ?? (chat.kind == .direct ? fallback : "Unnamed group")
        var lines = ["Conversation: \(name)"]
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
        return lines
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
            let nsError = error as NSError
            log.error(
                "Error accessing database with bookmark domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
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
            let nsError = error as NSError
            log.error(
                "Failed to create bookmark domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
        }
    }

    // NSOpenSavePanelDelegate method to constrain file selection
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.lastPathComponent == "chat.db"
    }
}

/// Redacted send outcome. It never carries the recipient, body, chat identifier,
/// chosen transport, account, message database identifier, or attachment path.
private struct MessageSendResult: Encodable {
    let status: String
    let service: String?
    let mode: String?

    /// Messages accepted one submission. This is never a delivery claim.
    static func submitted(service: String) -> MessageSendResult {
        MessageSendResult(status: "submitted", service: service, mode: nil)
    }

    /// Messages accepted one attachment submission.
    ///
    /// The mode names what was submitted, not what was in it: this carries no file name,
    /// path, type, size, or contents, and no more of a delivery claim than `submitted`.
    static func attachmentSubmitted(service: String) -> MessageSendResult {
        MessageSendResult(status: "submitted", service: service, mode: "attachment")
    }

    /// The human completed the system Messages composition flow.
    ///
    /// It asserts neither that the seeded recipient and body were the values
    /// ultimately used — the system panel leaves both editable — nor that anything
    /// was delivered.
    static let userCompletedComposition = MessageSendResult(
        status: "user_completed_composition",
        service: nil,
        mode: "system_messages_compose"
    )
}

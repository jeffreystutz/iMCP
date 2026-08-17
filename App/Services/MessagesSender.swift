// Direct Messages automation is adapted in part from mac_messages_mcp:
// https://github.com/carterlasalle/mac_messages_mcp
// Copyright (c) 2023 Carter Lasalle. Used under the MIT License.
// See THIRD_PARTY_NOTICES.md for the complete notice.

import AppKit
import Carbon
import Foundation

/// Messages Automation authority as reported without ever prompting the user.
///
/// This exists so the send flow can decide whether a harmless pre-confirmation
/// addressability check is safe. Only `.authorized` permits an Apple Event
/// before the user has authorized the send; every other value defers all
/// Messages automation until after final confirmation.
enum MessagesAutomationAuthorization: Equatable, Sendable {
    case authorized
    case consentRequired
    case denied
    case unknown
}

protocol MessagesSending: Sendable {
    /// Reports current Messages Automation authority without prompting.
    func automationAuthorization() async -> MessagesAutomationAuthorization

    /// Requests Messages Automation authority, prompting when macOS requires it.
    ///
    /// Call this only after the send has been authorized: it is the step that can
    /// present the system Automation prompt.
    func requestAutomationAuthorization() async throws

    /// Reports whether Messages currently exposes this exact chat to automation.
    ///
    /// Read-only and non-prompting. Messages publishes only a bounded,
    /// recency-biased subset of its conversations to scripting, so a perfectly
    /// valid database conversation can be temporarily unaddressable.
    func isChatAddressable(chatGUID: String) async throws -> Bool

    func submit(chatGUID: String, body: String) async throws

    /// Submits one attachment to this exact chat.
    ///
    /// Messages accepts one direct parameter that is either a file or text, so an
    /// attachment is its own submission rather than a file carried alongside a body.
    /// The file travels as a typed file-URL Apple Event descriptor, never as a path
    /// string and never as script source.
    func submitChatAttachment(chatGUID: String, attachmentFile: URL) async throws
}

enum MessageSendError: LocalizedError, Sendable {
    case missingInput
    case inputMalformed
    case missingSendPayload
    case conflictingSendPayload
    case invalidAttachmentPayload
    case invalidRecipient
    case invalidDestination
    case insufficientGroupParticipants
    case groupConversationNotFound
    case ambiguousDirectConversation
    case ambiguousGroupConversation
    case incompleteGroupMembership
    case incompleteDirectMembership
    case staleMatchedConversation
    case invalidChatIdentifier
    case staleChatIdentifier
    case ambiguousChatResolution
    case chatUnavailableInAutomation
    case emptyBody
    case confirmationDeclined
    case confirmationCancelled
    case confirmationMalformed
    case automationDenied
    case automationFailed
    case messagesUnavailable
    case ambiguousSubmission
    case attachmentRequiresExistingConversation

    var errorDescription: String? {
        switch self {
        case .missingInput:
            return "A recipient and non-empty message body are required."
        case .inputMalformed:
            return "Required message information was missing or malformed."
        case .missingSendPayload:
            return
                "Exactly one of body or attachment is required. Nothing was sent."
        case .conflictingSendPayload:
            return
                "Provide only one of body or attachment, not both. Nothing was sent."
        case .invalidAttachmentPayload:
            return
                "The attachment payload must be exactly {\"source\": \"picker\"}, the only currently supported source. Nothing was sent."
        case .invalidRecipient:
            return "The recipient must be one exact E.164 phone number or email address."
        case .invalidDestination:
            return "Exactly one message destination is required: recipient, recipients, or chat_id."
        case .insufficientGroupParticipants:
            return "A group destination requires at least two distinct valid participants."
        case .groupConversationNotFound:
            return "No existing group exactly matches the supplied participants. Nothing was sent."
        case .ambiguousDirectConversation:
            return "Multiple existing direct conversations match. Use chat_id to select one."
        case .ambiguousGroupConversation:
            return "Multiple existing groups match those participants. Use chat_id to select one."
        case .incompleteGroupMembership:
            return "Existing group membership cannot be resolved safely. Use chat_id to select a conversation."
        case .incompleteDirectMembership:
            return
                "Existing direct conversation membership cannot be resolved safely, so it is unknown whether this recipient already has a conversation. Nothing was sent. Use chat_id to select a conversation."
        case .staleMatchedConversation:
            return "The matched conversation changed before submission. Nothing was sent."
        case .invalidChatIdentifier:
            return "The chat identifier is invalid."
        case .staleChatIdentifier:
            return "The chat identifier no longer resolves to an existing conversation."
        case .ambiguousChatResolution:
            return "The chat identifier does not resolve unambiguously."
        case .chatUnavailableInAutomation:
            return
                "The selected conversation is not currently available through Messages automation, so iMCP cannot safely address it. Nothing was sent. Opening or using that conversation in Messages and trying again may make it available."
        case .emptyBody:
            return "The message body must not be empty."
        case .confirmationDeclined:
            return "Message submission was declined."
        case .confirmationCancelled:
            return "Message submission was cancelled."
        case .confirmationMalformed:
            return "Message submission was not explicitly confirmed."
        case .automationDenied:
            return "Messages automation permission was denied."
        case .automationFailed:
            return "Messages did not accept the submission. Its status is unknown."
        case .messagesUnavailable:
            return "Messages is unavailable."
        case .ambiguousSubmission:
            return "Messages returned an uncertain result. The submission may have occurred."
        case .attachmentRequiresExistingConversation:
            return
                "An attachment can only be submitted to an existing Messages conversation, and this recipient has none. Nothing was sent, and no compose window was opened. Send a message first, or select an existing conversation with chat_id."
        }
    }
}

struct AppleScriptMessagesSender: MessagesSending {
    private static let chatNotFoundError = -10_001
    private static let chatAmbiguousError = -10_002
    private static let applicationUnavailableError = -600

    /// The complete fixed script. Untrusted values only ever arrive as Apple Event
    /// descriptors, never as interpolated source. `chatIsAddressable` is read-only:
    /// it performs no participant, account, or history enumeration and no `send`.
    static let scriptSource = """
        on chatIsAddressable(chatGUID)
            tell application id "com.apple.MobileSMS"
                return (exists chat id chatGUID)
            end tell
        end chatIsAddressable

        on submitChatMessage(chatGUID, messageBody)
            tell application id "com.apple.MobileSMS"
                set targetChats to every chat whose id = chatGUID
                if (count of targetChats) is 0 then error "Chat unavailable" number -10001
                if (count of targetChats) is not 1 then error "Chat ambiguous" number -10002
                send messageBody to item 1 of targetChats
            end tell
        end submitChatMessage

        on submitChatAttachment(chatGUID, attachmentFile)
            tell application id "com.apple.MobileSMS"
                set targetChats to every chat whose id = chatGUID
                if (count of targetChats) is 0 then error "Chat unavailable" number -10001
                if (count of targetChats) is not 1 then error "Chat ambiguous" number -10002
                send attachmentFile to item 1 of targetChats
            end tell
        end submitChatAttachment
        """

    @MainActor
    func automationAuthorization() -> MessagesAutomationAuthorization {
        switch Self.determinePermission(askUserIfNeeded: false) {
        case noErr:
            return .authorized
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .consentRequired
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:
            // Messages not running, or any status this build does not recognize.
            // Treat it as unknown so the caller keeps the conservative sequence.
            return .unknown
        }
    }

    @MainActor
    func requestAutomationAuthorization() throws {
        try Task.checkCancellation()
        guard Self.determinePermission(askUserIfNeeded: true) == noErr else {
            throw MessageSendError.automationDenied
        }
    }

    @MainActor
    func isChatAddressable(chatGUID: String) throws -> Bool {
        try Task.checkCancellation()
        // Never prompts. The send flow either establishes authority beforehand or
        // skips this check entirely, so a harmless probe can never be the reason a
        // permission prompt appears.
        guard Self.determinePermission(askUserIfNeeded: false) == noErr else {
            throw MessageSendError.automationDenied
        }
        let result = try execute(
            handler: "chatIsAddressable",
            arguments: [Self.textDescriptor(chatGUID)],
            isChatSend: false
        )
        return result.booleanValue
    }

    @MainActor
    func submit(chatGUID: String, body: String) throws {
        try Task.checkCancellation()
        guard Self.determinePermission(askUserIfNeeded: true) == noErr else {
            throw MessageSendError.automationDenied
        }
        _ = try execute(
            handler: "submitChatMessage",
            arguments: [Self.textDescriptor(chatGUID), Self.textDescriptor(body)],
            isChatSend: true
        )
    }

    @MainActor
    func submitChatAttachment(chatGUID: String, attachmentFile: URL) throws {
        try Task.checkCancellation()
        guard Self.determinePermission(askUserIfNeeded: true) == noErr else {
            throw MessageSendError.automationDenied
        }
        _ = try execute(
            handler: "submitChatAttachment",
            arguments: [Self.textDescriptor(chatGUID), Self.fileDescriptor(attachmentFile)],
            isChatSend: true
        )
    }

    /// The chat GUID stays a plain text descriptor, exactly as the message path sends it.
    static func textDescriptor(_ value: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(string: value)
    }

    /// The attachment travels as a typed file-URL descriptor.
    ///
    /// Messages resolves the `file` direct parameter from the descriptor's own type. A
    /// path handed over as text would be a string the script had to interpret, which is
    /// precisely the class of input this architecture keeps out of AppleScript.
    static func fileDescriptor(_ url: URL) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(fileURL: url)
    }

    @MainActor
    private static func determinePermission(askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            AEEventClass(kCoreEventClass),
            AEEventID(kAEGetData),
            askUserIfNeeded
        )
    }

    @MainActor
    @discardableResult
    private func execute(
        handler: String,
        arguments: [NSAppleEventDescriptor],
        isChatSend: Bool
    ) throws -> NSAppleEventDescriptor {
        var compilationError: NSDictionary?
        guard let script = NSAppleScript(source: Self.scriptSource),
            script.compileAndReturnError(&compilationError)
        else {
            throw MessageSendError.automationFailed
        }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: handler),
            forKeyword: AEKeyword(keyASSubroutineName)
        )
        let parameters = NSAppleEventDescriptor.list()
        for (offset, argument) in arguments.enumerated() {
            parameters.insert(argument, at: offset + 1)
        }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))

        var executionError: NSDictionary?
        let result = script.executeAppleEvent(event, error: &executionError)
        if let executionError {
            let code = executionError[NSAppleScript.errorNumber] as? Int
            // Zero scripting matches means Messages is not currently exposing the
            // conversation, which is an addressability limit rather than anything
            // about its service type. This remains the last race defense even though
            // the flow already checked addressability immediately beforehand.
            if code == Self.chatNotFoundError {
                throw MessageSendError.chatUnavailableInAutomation
            }
            if code == Self.chatAmbiguousError {
                throw MessageSendError.ambiguousChatResolution
            }
            if code == Int(errAEEventNotPermitted) {
                throw MessageSendError.automationDenied
            }
            if code == Self.applicationUnavailableError {
                throw MessageSendError.messagesUnavailable
            }
            throw isChatSend
                ? MessageSendError.ambiguousSubmission : MessageSendError.automationFailed
        }
        return result
    }
}

extension String {
    var isExactMessageHandle: Bool {
        if wholeMatch(of: /^\+[1-9][0-9]{1,14}$/) != nil {
            return true
        }
        return wholeMatch(of: /^[^\s@]+@[^\s@]+\.[^\s@]+$/) != nil
    }
}

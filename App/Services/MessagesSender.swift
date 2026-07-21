// Direct Messages automation is adapted in part from mac_messages_mcp:
// https://github.com/carterlasalle/mac_messages_mcp
// Copyright (c) 2023 Carter Lasalle. Used under the MIT License.
// See THIRD_PARTY_NOTICES.md for the complete notice.

import AppKit
import Carbon
import Foundation

protocol MessagesSending: Sendable {
    func submit(recipient: String, body: String) async throws
    func submit(chatGUID: String, body: String) async throws
}

extension MessagesSending {
    func submit(chatGUID: String, body: String) async throws {
        throw MessageSendError.unsupportedChatType
    }
}

enum MessageSendError: LocalizedError, Sendable {
    case missingInput
    case inputDeclined
    case inputCancelled
    case inputMalformed
    case invalidRecipient
    case invalidDestination
    case invalidChatIdentifier
    case staleChatIdentifier
    case ambiguousChatResolution
    case unsupportedChatType
    case emptyBody
    case confirmationDeclined
    case confirmationCancelled
    case confirmationMalformed
    case automationDenied
    case automationFailed
    case messagesUnavailable
    case ambiguousSubmission

    var errorDescription: String? {
        switch self {
        case .missingInput:
            return "A recipient and non-empty message body are required."
        case .inputDeclined:
            return "Required message information was declined."
        case .inputCancelled:
            return "Required message information was cancelled."
        case .inputMalformed:
            return "Required message information was missing or malformed."
        case .invalidRecipient:
            return "The recipient must be one exact E.164 phone number or email address."
        case .invalidDestination:
            return "Exactly one message destination is required."
        case .invalidChatIdentifier:
            return "The chat identifier is invalid."
        case .staleChatIdentifier:
            return "The chat identifier no longer resolves to an existing conversation."
        case .ambiguousChatResolution:
            return "The chat identifier does not resolve unambiguously."
        case .unsupportedChatType:
            return "Messages does not expose this conversation for safe automation."
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
        }
    }
}

struct AppleScriptMessagesSender: MessagesSending {
    private static let chatNotFoundError = -10_001
    private static let chatAmbiguousError = -10_002
    private static let applicationUnavailableError = -600
    static let scriptSource = """
        on submitDirectMessage(recipientHandle, messageBody)
            tell application id "com.apple.MobileSMS"
                set targetService to first service whose service type = iMessage
                set targetParticipant to participant recipientHandle of targetService
                send messageBody to targetParticipant
            end tell
        end submitDirectMessage

        on submitChatMessage(chatGUID, messageBody)
            tell application id "com.apple.MobileSMS"
                set targetChats to every chat whose id = chatGUID
                if (count of targetChats) is 0 then error "Chat unavailable" number -10001
                if (count of targetChats) is not 1 then error "Chat ambiguous" number -10002
                send messageBody to item 1 of targetChats
            end tell
        end submitChatMessage
        """

    @MainActor
    func submit(recipient: String, body: String) throws {
        try execute(handler: "submitDirectMessage", destination: recipient, body: body, isChat: false)
    }

    @MainActor
    func submit(chatGUID: String, body: String) throws {
        try execute(handler: "submitChatMessage", destination: chatGUID, body: body, isChat: true)
    }

    @MainActor
    private func execute(
        handler: String,
        destination: String,
        body: String,
        isChat: Bool
    ) throws {
        try Task.checkCancellation()
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
        let permission = AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            AEEventClass(kCoreEventClass),
            AEEventID(kAEGetData),
            true
        )
        guard permission == noErr else {
            throw MessageSendError.automationDenied
        }

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
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: destination), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: body), at: 2)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var executionError: NSDictionary?
        _ = script.executeAppleEvent(event, error: &executionError)
        if let executionError {
            let code = executionError[NSAppleScript.errorNumber] as? Int
            if isChat, code == Self.chatNotFoundError {
                throw MessageSendError.unsupportedChatType
            }
            if isChat, code == Self.chatAmbiguousError {
                throw MessageSendError.ambiguousChatResolution
            }
            if code == Int(errAEEventNotPermitted) {
                throw MessageSendError.automationDenied
            }
            if code == Self.applicationUnavailableError {
                throw MessageSendError.messagesUnavailable
            }
            throw isChat ? MessageSendError.ambiguousSubmission : MessageSendError.automationFailed
        }
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

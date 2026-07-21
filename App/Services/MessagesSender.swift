// Direct Messages automation is adapted in part from mac_messages_mcp:
// https://github.com/carterlasalle/mac_messages_mcp
// Copyright (c) 2023 Carter Lasalle. Used under the MIT License.
// See THIRD_PARTY_NOTICES.md for the complete notice.

import AppKit
import Carbon
import Foundation

protocol MessagesSending: Sendable {
    func submit(recipient: String, body: String) async throws
}

enum MessageSendError: LocalizedError, Sendable {
    case missingInput
    case inputDeclined
    case inputCancelled
    case inputMalformed
    case invalidRecipient
    case emptyBody
    case confirmationDeclined
    case confirmationCancelled
    case confirmationMalformed
    case automationDenied
    case automationFailed

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
        }
    }
}

struct AppleScriptMessagesSender: MessagesSending {
    static let scriptSource = """
        on submitDirectMessage(recipientHandle, messageBody)
            tell application id "com.apple.MobileSMS"
                set targetService to first service whose service type = iMessage
                set targetParticipant to participant recipientHandle of targetService
                send messageBody to targetParticipant
            end tell
        end submitDirectMessage
        """

    @MainActor
    func submit(recipient: String, body: String) throws {
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
            NSAppleEventDescriptor(string: "submitDirectMessage"),
            forKeyword: AEKeyword(keyASSubroutineName)
        )
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: recipient), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: body), at: 2)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var executionError: NSDictionary?
        _ = script.executeAppleEvent(event, error: &executionError)
        guard executionError == nil else {
            throw MessageSendError.automationFailed
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

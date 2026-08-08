import AppKit
import Foundation
import MCP

enum MessagesSendConfirmationMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case mcpForm
    case appDialog

    static let storageKey = "me.mattt.iMCP.messagesSendConfirmationMode"
    static let defaultValue = MessagesSendConfirmationMode.automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .mcpForm: "MCP form"
        case .appDialog: "iMCP app"
        }
    }

    static func decode(_ storedValue: String?) -> MessagesSendConfirmationMode {
        storedValue.flatMap(MessagesSendConfirmationMode.init(rawValue:)) ?? defaultValue
    }

    static func load(from defaults: UserDefaults = .standard) -> MessagesSendConfirmationMode {
        decode(defaults.string(forKey: storageKey))
    }
}

struct MessagesSendConfirmationPresentation: Equatable, Sendable {
    let title: String
    let message: String
}

enum MessagesNativeSendConfirmationOutcome: Equatable, Sendable {
    case affirmed
    case cancelled
}

protocol MessagesNativeSendConfirmationPresenting: Sendable {
    @MainActor
    func requestConfirmation(
        _ presentation: MessagesSendConfirmationPresentation
    ) throws -> MessagesNativeSendConfirmationOutcome
}

struct AppKitMessagesSendConfirmationPresenter: MessagesNativeSendConfirmationPresenting {
    @MainActor
    func requestConfirmation(
        _ presentation: MessagesSendConfirmationPresentation
    ) throws -> MessagesNativeSendConfirmationOutcome {
        try Task.checkCancellation()
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .modalPanel
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()

        let response = alert.runModal()
        try Task.checkCancellation()
        return Self.outcome(for: response)
    }

    static func outcome(
        for response: NSApplication.ModalResponse
    ) -> MessagesNativeSendConfirmationOutcome {
        response == .alertFirstButtonReturn ? .affirmed : .cancelled
    }
}

protocol MessagesFinalSendConfirmationRequesting: Sendable {
    func requestConfirmation(
        _ presentation: MessagesSendConfirmationPresentation,
        elicitation: any ElicitationRequester
    ) async throws
}

struct MessagesFinalSendConfirmationRequester: MessagesFinalSendConfirmationRequesting {
    private enum Presenter {
        case mcpForm
        case appDialog
    }

    private let mode: @Sendable () -> MessagesSendConfirmationMode
    private let appPresenter: any MessagesNativeSendConfirmationPresenting

    init(
        mode: @escaping @Sendable () -> MessagesSendConfirmationMode = {
            MessagesSendConfirmationMode.load()
        },
        appPresenter: any MessagesNativeSendConfirmationPresenting =
            AppKitMessagesSendConfirmationPresenter()
    ) {
        self.mode = mode
        self.appPresenter = appPresenter
    }

    func requestConfirmation(
        _ presentation: MessagesSendConfirmationPresentation,
        elicitation: any ElicitationRequester
    ) async throws {
        let presenter: Presenter
        switch mode() {
        case .automatic:
            presenter = elicitation.supportsFormElicitation ? .mcpForm : .appDialog
        case .mcpForm:
            presenter = .mcpForm
        case .appDialog:
            presenter = .appDialog
        }

        switch presenter {
        case .mcpForm:
            try await requestMCPForm(presentation, elicitation: elicitation)
        case .appDialog:
            switch try await appPresenter.requestConfirmation(presentation) {
            case .affirmed:
                return
            case .cancelled:
                throw MessageSendError.confirmationCancelled
            }
        }
    }

    private func requestMCPForm(
        _ presentation: MessagesSendConfirmationPresentation,
        elicitation: any ElicitationRequester
    ) async throws {
        let confirmation = try await elicitation.requestForm(
            message: presentation.message,
            schema: .init(
                title: presentation.title,
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
    }
}

import AppKit
import Foundation

/// Outcome of a Messages composition the human drives in system-owned UI.
enum MessagesCompositionOutcome: Equatable, Sendable {
    /// The human completed the system Messages composition flow.
    ///
    /// This is not delivery, and it is not evidence that the seeded recipient or
    /// seeded body were the values actually used: both remain editable in the
    /// system panel up to the moment the human presses Send.
    case userCompleted
}

enum MessagesCompositionError: LocalizedError, Equatable, Sendable {
    /// The system compose service could not be created or could not accept the
    /// items. This happens before any panel is presented, so nothing was sent.
    case compositionUnavailable
    /// Another composition is already active, so this request presented no panel
    /// of its own and nothing was sent.
    case compositionBusy
    /// The human dismissed the panel without sending, reported as
    /// `NSUserCancelledError`. Verified by experiment to send nothing.
    case compositionCancelled
    /// The sharing service reported a non-cancellation failure after the panel was
    /// presented.
    ///
    /// This is an **ambiguous** outcome. The delegate callback documents only that
    /// an error occurred while sharing; it does not establish that no message was
    /// submitted first. iMCP therefore claims nothing about the send status and
    /// never retries or switches routes on it.
    case compositionFailed

    var errorDescription: String? {
        switch self {
        case .compositionUnavailable:
            return "The system Messages composition panel is unavailable. Nothing was sent."
        case .compositionBusy:
            return
                "Another Messages composition is already open. Finish or cancel it, then try again. Nothing was sent."
        case .compositionCancelled:
            return "The Messages composition was cancelled. Nothing was sent."
        case .compositionFailed:
            return
                "The Messages composition reported a failure. Whether a message was sent is unknown, and iMCP did not retry."
        }
    }
}

/// Seeds a system-owned Messages compose panel for a recipient with no existing
/// conversation.
///
/// This is a deliberately different authorization model from a programmatic
/// existing-chat send. iMCP supplies starting values and presents system UI; the
/// human reviews them, may edit either one, and personally invokes Send. There is
/// no iMCP final-send confirmation in front of it, because an earlier immutable
/// confirmation could not truthfully authorize values that stay editable.
protocol MessagesNewRecipientComposing: Sendable {
    func compose(
        seedRecipient: String,
        seedBody: String
    ) async throws -> MessagesCompositionOutcome
}

/// The AppKit edge of new-recipient composition, kept behind a protocol so the
/// composition lifecycle can be tested without presenting real system UI.
protocol MessagesCompositionPanelPresenting: AnyObject, Sendable {
    /// Presents the system-owned compose panel, retaining whatever system objects
    /// must outlive this call. Returns `false` when the system compose service is
    /// unavailable or cannot accept these items.
    @MainActor
    func present(recipient: String, items: [Any], delegate: NSSharingServiceDelegate) -> Bool

    /// Releases retained system objects once a terminal outcome has been reached.
    @MainActor
    func release()
}

/// Presents the public `NSSharingService.Name.composeMessage` panel.
///
/// This uses public AppKit only. It needs no Automation, Accessibility, Contacts,
/// or file consent, adds no entitlement, and sends nothing itself: the only
/// Messages interaction is presenting UI that the human then controls.
final class SharingServiceCompositionPanel:
    MessagesCompositionPanelPresenting, @unchecked Sendable
{
    // Only ever touched from the main actor, as the protocol requires.
    private var service: NSSharingService?

    @MainActor
    func present(recipient: String, items: [Any], delegate: NSSharingServiceDelegate) -> Bool {
        guard let service = NSSharingService(named: .composeMessage) else { return false }
        // Capability is only ever checked against the real item array. The
        // documented `nil` form reports false even when the service is usable, so
        // it must never be treated as an availability signal.
        guard service.canPerform(withItems: items) else { return false }

        service.delegate = delegate
        service.recipients = [recipient]
        // `delegate` is weak and the service must outlive this call, so hold it
        // until a terminal delegate callback releases it.
        self.service = service
        service.perform(withItems: items)
        return true
    }

    @MainActor
    func release() {
        service?.delegate = nil
        service = nil
    }
}

/// Owns one composition's lifecycle: single-active policy, delegate retention,
/// and exactly one terminal resume.
@MainActor
final class MessagesCompositionCoordinator: NSObject, NSSharingServiceDelegate {
    /// At most one system compose panel may be presented by this process at a time.
    /// A second request fails closed rather than queueing a human interaction that
    /// would surface later without context.
    private static var activeComposition: MessagesCompositionCoordinator?

    private let panel: any MessagesCompositionPanelPresenting
    private var continuation: CheckedContinuation<MessagesCompositionOutcome, Error>?
    /// Keeps the coordinator alive until a terminal callback even if the calling
    /// task goes away. Once system UI is visible, abandoning the delegate would
    /// lose the only truthful record of what the human did.
    private var selfReference: MessagesCompositionCoordinator?

    private init(panel: any MessagesCompositionPanelPresenting) {
        self.panel = panel
        super.init()
    }

    static func compose(
        recipient: String,
        body: String,
        panel: any MessagesCompositionPanelPresenting
    ) async throws -> MessagesCompositionOutcome {
        // A cancelled task must never present system UI.
        try Task.checkCancellation()
        guard activeComposition == nil else {
            throw MessagesCompositionError.compositionBusy
        }

        let coordinator = MessagesCompositionCoordinator(panel: panel)
        activeComposition = coordinator
        coordinator.selfReference = coordinator
        return try await coordinator.present(recipient: recipient, body: body)
    }

    private func present(
        recipient: String,
        body: String
    ) async throws -> MessagesCompositionOutcome {
        // Past this point the composition is not cancellable by iMCP. Cancelling the
        // caller cannot retract a panel the human may already be using, and iMCP
        // never synthesizes a Send or Cancel to close it.
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // The body travels as a pasteboard item because `messageBody` is
            // read-only. Attachments are deliberately not offered yet; supporting
            // approved item URLs later only appends to this array.
            let items: [Any] = [body]
            guard panel.present(recipient: recipient, items: items, delegate: self) else {
                finish(.failure(MessagesCompositionError.compositionUnavailable))
                return
            }
        }
    }

    /// Resolves the composition exactly once, whatever the delegate reports.
    private func finish(_ result: Result<MessagesCompositionOutcome, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        panel.release()
        if Self.activeComposition === self {
            Self.activeComposition = nil
        }
        continuation.resume(with: result)
        selfReference = nil
    }

    /// Maps a sharing-service failure without exposing items, recipient, body, or
    /// any underlying filesystem detail.
    ///
    /// Only the documented cancellation code establishes that nothing was sent.
    /// Every other failure collapses to the ambiguous case, which is deliberately
    /// terminal: an unknown outcome is exactly the situation in which a retry could
    /// duplicate a message.
    static func outcome(forFailure error: Error) -> MessagesCompositionError {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError {
            return .compositionCancelled
        }
        return .compositionFailed
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(.success(.userCompleted))
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        finish(.failure(Self.outcome(forFailure: error)))
    }
}

struct SystemMessagesComposer: MessagesNewRecipientComposing {
    private let makePanel: @Sendable () -> any MessagesCompositionPanelPresenting

    init(
        makePanel: @escaping @Sendable () -> any MessagesCompositionPanelPresenting = {
            SharingServiceCompositionPanel()
        }
    ) {
        self.makePanel = makePanel
    }

    func compose(
        seedRecipient: String,
        seedBody: String
    ) async throws -> MessagesCompositionOutcome {
        try Task.checkCancellation()
        return try await MessagesCompositionCoordinator.compose(
            recipient: seedRecipient,
            body: seedBody,
            panel: makePanel()
        )
    }
}

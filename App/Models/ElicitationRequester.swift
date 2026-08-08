import Foundation
import MCP

enum ElicitationRequestError: LocalizedError, Sendable {
    case formUnsupported
    case timedOut

    var errorDescription: String? {
        switch self {
        case .formUnsupported:
            return "Form elicitation is not supported by this MCP client."
        case .timedOut:
            return "The elicitation request timed out."
        }
    }
}

public protocol ElicitationRequester: Sendable {
    var supportsFormElicitation: Bool { get }

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result
}

struct MCPFormElicitationRequester: ElicitationRequester {
    private let supportsForm: Bool
    private let timeout: Duration
    private let request: @Sendable (String, Elicitation.RequestSchema) async throws -> CreateElicitation.Result

    var supportsFormElicitation: Bool { supportsForm }

    init(
        server: MCP.Server,
        clientCapabilities: MCP.Client.Capabilities,
        timeout: Duration = .seconds(300)
    ) {
        self.supportsForm = clientCapabilities.supportsFormElicitation
        self.timeout = timeout
        self.request = { message, schema in
            try await server.requestElicitation(
                message: message,
                requestedSchema: schema,
                mode: .form
            )
        }
    }

    init(
        supportsForm: Bool,
        timeout: Duration,
        request:
            @Sendable @escaping (
                String, Elicitation.RequestSchema
            ) async throws -> CreateElicitation.Result
    ) {
        self.supportsForm = supportsForm
        self.timeout = timeout
        self.request = request
    }

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        guard supportsForm else {
            throw ElicitationRequestError.formUnsupported
        }

        let race = ElicitationResultRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let requestTask = Task {
                    do {
                        race.resolve(.success(try await request(message, schema)))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                race.installRequestTask(requestTask)
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        race.resolve(.failure(ElicitationRequestError.timedOut))
                    } catch {
                        // The request completed first and cancelled this timer.
                    }
                }
                race.installTimeoutTask(timeoutTask)
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }
}

/// Resolves the first of four possible outcomes — response, request error, timeout, or
/// parent-task cancellation — exactly once, then cancels and releases both losing tasks.
///
/// Cancelling the request task abandons the wait and releases this wrapper's retained
/// state. It cannot retract an elicitation prompt the client has already displayed: the
/// pinned MCP Swift SDK exposes `Server.cancelRequest(_:reason:)` but never surfaces the
/// request ID that `Server.requestElicitation` generates, so no supported, spec-compliant
/// `notifications/cancelled` can be addressed to it. A late client response is therefore
/// still possible and is discarded here rather than allowed to replace the first outcome.
private final class ElicitationResultRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CreateElicitation.Result, Error>?
    private var completedResult: Result<CreateElicitation.Result, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<CreateElicitation.Result, Error>) {
        let result: Result<CreateElicitation.Result, Error>? = lock.withLock {
            if let completedResult {
                return completedResult
            }
            self.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            if completedResult != nil {
                return true
            }
            timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func installRequestTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            if completedResult != nil {
                return true
            }
            requestTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func resolve(_ result: Result<CreateElicitation.Result, Error>) {
        let state:
            (
                CheckedContinuation<CreateElicitation.Result, Error>?,
                Task<Void, Never>?,
                Task<Void, Never>?
            )? = lock.withLock {
                guard completedResult == nil else { return nil }
                completedResult = result
                let state = (continuation, timeoutTask, requestTask)
                continuation = nil
                timeoutTask = nil
                requestTask = nil
                return state
            }
        guard let state else { return }
        state.1?.cancel()
        state.2?.cancel()
        state.0?.resume(with: result)
    }
}

extension MCP.Client.Capabilities {
    var supportsFormElicitation: Bool {
        guard let elicitation else { return false }

        // MCP 2025-11-25 defines an empty elicitation capability as form-only
        // support for backwards compatibility.
        return elicitation.form != nil || (elicitation.form == nil && elicitation.url == nil)
    }
}

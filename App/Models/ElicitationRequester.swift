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
    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result
}

struct MCPFormElicitationRequester: ElicitationRequester {
    private let supportsForm: Bool
    private let timeout: Duration
    private let request: @Sendable (String, Elicitation.RequestSchema) async throws -> CreateElicitation.Result

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

        return try await withThrowingTaskGroup(of: CreateElicitation.Result.self) { group in
            group.addTask {
                try await request(message, schema)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ElicitationRequestError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MCPError.internalError("Elicitation request ended without a result")
            }
            return result
        }
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

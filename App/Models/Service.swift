@preconcurrency
protocol Service {
    @ToolBuilder var tools: [Tool] { get }

    var isActivated: Bool { get async }
    func activate() async throws
}

extension Service {
    var isActivated: Bool {
        get async {
            return true
        }
    }

    func activate() async throws {}

    /// The identifier the server gates this service's tools by.
    static var serviceID: String {
        String(describing: Self.self)
    }

    /// The identifier the server gates this service's tools by.
    var serviceID: String {
        String(describing: type(of: self))
    }

    func call(
        tool name: String,
        with arguments: [String: Value],
        context: ToolCallContext,
        enabledServices: EnabledServices
    ) async throws -> Value? {
        for tool in tools where tool.name == name {
            // A cross-service tool stays uncallable while any service it reads is
            // disabled, including for a client still holding an earlier tool listing.
            // Reporting it as absent is the same answer the client gets for a tool whose
            // own service is off.
            guard enabledServices.allows(tool) else { return nil }
            return try await tool.callAsFunction(arguments, context: context)
        }

        return nil
    }
}

/// The services the user currently has enabled.
///
/// Tool availability is a question about a set of services rather than about one service
/// at a time, because a tool may read more than one of them. Passing this set explicitly
/// keeps the answer derived from the user's settings at one place — the server — instead
/// of letting a service read the settings itself.
struct EnabledServices: Equatable, Sendable {
    private let identifiers: Set<String>

    init(_ identifiers: Set<String>) {
        self.identifiers = identifiers
    }

    func contains(_ serviceID: String) -> Bool {
        identifiers.contains(serviceID)
    }

    /// Whether every service this tool reads is enabled.
    ///
    /// A tool that declares no extra dependency is allowed by any set, so gating a tool
    /// remains entirely a question about its own service unless it says otherwise.
    func allows(_ tool: Tool) -> Bool {
        identifiers.isSuperset(of: tool.requiredServiceIDs)
    }
}

@resultBuilder
struct ToolBuilder {
    static func buildBlock(_ tools: Tool...) -> [Tool] {
        tools
    }
}

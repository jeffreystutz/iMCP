import Foundation
import JSONSchema
import MCP
import Ontology

public struct Tool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let annotations: MCP.Tool.Annotations
    /// Services besides this tool's own that must also be enabled before it is advertised
    /// or called.
    ///
    /// A tool belongs to one service, and that service is what the user enables or
    /// disables. A tool that also reads a second service's data names it here, so
    /// enabling the owning service never becomes a way around a service the user turned
    /// off. Almost every tool reads only its own service and leaves this empty.
    let requiredServiceIDs: [String]
    private let implementation: @Sendable ([String: Value], ToolCallContext) async throws -> Value

    public init<T: Encodable>(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: MCP.Tool.Annotations,
        requiredServiceIDs: [String] = [],
        implementation: @Sendable @escaping ([String: Value]) async throws -> T
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.requiredServiceIDs = requiredServiceIDs
        self.implementation = { input, _ in
            let result = try await implementation(input)

            return try Self.encode(result)
        }
    }

    public init<T: Encodable>(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: MCP.Tool.Annotations,
        requiredServiceIDs: [String] = [],
        implementation: @Sendable @escaping ([String: Value], ToolCallContext) async throws -> T
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.requiredServiceIDs = requiredServiceIDs
        self.implementation = { input, context in
            let result = try await implementation(input, context)

            return try Self.encode(result)
        }
    }

    private static func encode<T: Encodable>(_ result: T) throws -> Value {
        let encoder = JSONEncoder()
        encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
            TimeZone.current
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        return try decoder.decode(Value.self, from: data)
    }

    public func callAsFunction(
        _ input: [String: Value],
        context: ToolCallContext
    ) async throws -> Value {
        try await implementation(input, context)
    }
}

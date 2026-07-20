import MCP
import XCTest

@testable import iMCP

final class FormElicitationTests: XCTestCase {
    func testHandlersRegisteredDuringInitializeAreAvailableToFirstToolsList() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = MCP.Server(
            name: "test-server",
            version: "1",
            capabilities: .init(tools: .init())
        )
        let client = MCP.Client(name: "test-client", version: "1")

        try await server.start(transport: serverTransport) { _, _ in
            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: [
                    .init(
                        name: "test_tool",
                        description: "Test tool",
                        inputSchema: .object(["type": .string("object")])
                    )
                ])
            }
        }

        _ = try await client.connect(transport: clientTransport)
        let result = try await client.listTools()

        XCTAssertEqual(result.tools.map(\.name), ["test_tool"])
        await client.disconnect()
        await server.stop()
    }

    func testEmptyElicitationCapabilitySupportsForm() {
        let capabilities = MCP.Client.Capabilities(
            elicitation: .init(form: nil, url: nil)
        )

        XCTAssertTrue(capabilities.supportsFormElicitation)
    }

    func testURLOnlyCapabilityDoesNotSupportForm() {
        let capabilities = MCP.Client.Capabilities(
            elicitation: .init(form: nil, url: .init())
        )

        XCTAssertFalse(capabilities.supportsFormElicitation)
    }

    func testUnsupportedFormFailsBeforeRequest() async {
        let requestCalled = LockedFlag()
        let requester = MCPFormElicitationRequester(
            supportsForm: false,
            timeout: .seconds(1)
        ) { _, _ in
            requestCalled.set()
            return .init(action: .accept)
        }

        do {
            _ = try await requester.requestForm(message: "Confirm", schema: .init())
            XCTFail("Expected unsupported form elicitation to throw")
        } catch ElicitationRequestError.formUnsupported {
            XCTAssertFalse(requestCalled.value)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAcceptedResponseIsReturned() async throws {
        let requester = MCPFormElicitationRequester(
            supportsForm: true,
            timeout: .seconds(1)
        ) { message, _ in
            XCTAssertEqual(message, "Confirm")
            return .init(action: .accept, content: ["confirmed": .bool(true)])
        }

        let result = try await requester.requestForm(message: "Confirm", schema: .init())

        XCTAssertEqual(result.action, .accept)
        XCTAssertEqual(result.content?["confirmed"], .bool(true))
    }

    func testRequestTimesOut() async {
        let requester = MCPFormElicitationRequester(
            supportsForm: true,
            timeout: .milliseconds(10)
        ) { _, _ in
            try await Task.sleep(for: .seconds(10))
            return .init(action: .accept)
        }

        do {
            _ = try await requester.requestForm(message: "Confirm", schema: .init())
            XCTFail("Expected elicitation to time out")
        } catch ElicitationRequestError.timedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutDoesNotWaitForRequestThatIgnoresCancellation() async {
        let clock = ContinuousClock()
        let requester = MCPFormElicitationRequester(
            supportsForm: true,
            timeout: .milliseconds(10)
        ) { _, _ in
            try? await Task.sleep(for: .milliseconds(250))
            return .init(action: .accept)
        }

        let elapsed = await clock.measure {
            do {
                _ = try await requester.requestForm(message: "Confirm", schema: .init())
                XCTFail("Expected elicitation to time out")
            } catch ElicitationRequestError.timedOut {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testTaskCancellationDoesNotWaitForRequestThatIgnoresCancellation() async {
        let requester = MCPFormElicitationRequester(
            supportsForm: true,
            timeout: .seconds(10)
        ) { _, _ in
            try? await Task.sleep(for: .milliseconds(250))
            return .init(action: .accept)
        }
        let task = Task {
            try await requester.requestForm(message: "Confirm", schema: .init())
        }

        try? await Task.sleep(for: .milliseconds(10))
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected elicitation to be cancelled")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertLessThan(elapsed, .milliseconds(100))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}

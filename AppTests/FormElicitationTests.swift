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

    func testTimeoutCancelsTheUnderlyingRequestTask() async {
        let observedCancellation = LockedFlag()
        let requestFinished = AsyncSignal()
        let requester = MCPFormElicitationRequester(
            supportsForm: true,
            timeout: .milliseconds(10)
        ) { _, _ in
            defer { requestFinished.signal() }
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                observedCancellation.set()
            }
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

        await requestFinished.wait()
        XCTAssertTrue(
            observedCancellation.value,
            "The timeout must cancel the underlying request task, not merely abandon it"
        )
    }

    func testParentCancellationCancelsTheUnderlyingRequestTask() async {
        let observedCancellation = LockedFlag()
        let requestStarted = AsyncSignal()
        let requestFinished = AsyncSignal()
        let requester = MCPFormElicitationRequester(
            supportsForm: true,
            timeout: .seconds(30)
        ) { _, _ in
            requestStarted.signal()
            defer { requestFinished.signal() }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                observedCancellation.set()
            }
            return .init(action: .accept)
        }

        let task = Task {
            try await requester.requestForm(message: "Confirm", schema: .init())
        }
        await requestStarted.wait()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected elicitation to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await requestFinished.wait()
        XCTAssertTrue(
            observedCancellation.value,
            "Parent cancellation must cancel the underlying request task"
        )
    }

    func testSuccessfulRequestCancelsTheTimeoutTask() async throws {
        // A 30 second timeout that survived would keep the process alive well past the
        // response; the test completing promptly proves the timer was cancelled.
        let clock = ContinuousClock()
        let requester = MCPFormElicitationRequester(
            supportsForm: true,
            timeout: .seconds(30)
        ) { _, _ in
            .init(action: .accept, content: ["confirmed": .bool(true)])
        }

        var result: CreateElicitation.Result?
        let elapsed = await clock.measure {
            result = try? await requester.requestForm(message: "Confirm", schema: .init())
        }

        XCTAssertEqual(result?.action, .accept)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testLateResponseAfterTimeoutCannotReplaceTheTimeoutOutcome() async {
        // The request ignores cancellation and answers after the deadline. The first
        // outcome must stand, and the continuation must resume exactly once.
        let requester = MCPFormElicitationRequester(
            supportsForm: true,
            timeout: .milliseconds(10)
        ) { _, _ in
            try? await Task.sleep(for: .milliseconds(150))
            return .init(action: .accept, content: ["confirmed": .bool(true)])
        }

        do {
            _ = try await requester.requestForm(message: "Confirm", schema: .init())
            XCTFail("Expected elicitation to time out")
        } catch ElicitationRequestError.timedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Outlive the late response. A second resume of the continuation would trap here.
        try? await Task.sleep(for: .milliseconds(300))
    }
}

/// One-shot signal used instead of a fixed sleep so cancellation tests stay deterministic.
private final class AsyncSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var signalled = false

    func signal() {
        lock.withLock {
            guard !signalled else { return }
            signalled = true
            semaphore.signal()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.semaphore.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
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

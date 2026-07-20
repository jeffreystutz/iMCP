import MCP
import XCTest

@testable import iMCP

final class FormElicitationTests: XCTestCase {
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

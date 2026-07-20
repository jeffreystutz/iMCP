import AppKit
import MCP
import XCTest

@testable import iMCP

final class MessageSendTests: XCTestCase {
    func testAcceptedEmailSubmissionDispatchesOnceAndReturnsRedactedStatus() async throws {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(result: confirmedResult)
        let result = try await sendTool(sender: sender)(
            ["recipient": .string("recipient@example.invalid"), "body": .string("test-body")],
            context: ToolCallContext(elicitation: requester)
        )

        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "submitted")
        XCTAssertEqual(result.objectValue?["service"]?.stringValue, "iMessage")
        let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("recipient@example.invalid"))
        XCTAssertFalse(encoded.contains("test-body"))
        XCTAssertFalse(requester.lastMessage.contains("recipient@example.invalid"))
        XCTAssertFalse(requester.lastMessage.contains("test-body"))
    }

    func testExactE164HandleIsAcceptedWithoutNormalization() async throws {
        let sender = RecordingMessagesSender()
        let recipient = "+" + "1555" + "0100001"
        _ = try await sendTool(sender: sender)(
            ["recipient": .string(recipient), "body": .string("test-body")],
            context: ToolCallContext(
                elicitation: StubElicitationRequester(result: confirmedResult)
            )
        )

        let submissionCount = await sender.submissionCount
        let lastRecipient = await sender.lastRecipient
        XCTAssertEqual(submissionCount, 1)
        XCTAssertTrue(lastRecipient == recipient)
    }

    func testInvalidHandleFailsBeforeConfirmationOrDispatch() async {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(result: confirmedResult)

        await assertSendError(.invalidRecipient) {
            _ = try await self.sendTool(sender: sender)(
                ["recipient": .string("not-a-handle"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }

        XCTAssertEqual(requester.requestCount, 0)
        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 0)
    }

    func testMissingInputIsElicitedBeforeSeparateConfirmation() async throws {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(results: [
            .init(
                action: .accept,
                content: [
                    "recipient": .string("recipient@example.invalid"),
                    "body": .string("test-body"),
                ]
            ),
            confirmedResult,
        ])

        _ = try await sendTool(sender: sender)(
            [:],
            context: ToolCallContext(elicitation: requester)
        )

        XCTAssertEqual(requester.requestCount, 2)
        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 1)
    }

    func testDeclinedMissingInputAndEmptyBodyNeverDispatch() async {
        let missingSender = RecordingMessagesSender()
        await assertSendError(.inputDeclined) {
            _ = try await self.sendTool(sender: missingSender)(
                [:],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: .init(action: .decline))
                )
            )
        }
        let missingSubmissionCount = await missingSender.submissionCount
        XCTAssertEqual(missingSubmissionCount, 0)

        let emptySender = RecordingMessagesSender()
        let requester = StubElicitationRequester(result: confirmedResult)
        await assertSendError(.emptyBody) {
            _ = try await self.sendTool(sender: emptySender)(
                ["recipient": .string("recipient@example.invalid"), "body": .string("")],
                context: ToolCallContext(elicitation: requester)
            )
        }
        XCTAssertEqual(requester.requestCount, 0)
        let emptySubmissionCount = await emptySender.submissionCount
        XCTAssertEqual(emptySubmissionCount, 0)
    }

    func testDeclineCancelAndMalformedConfirmationNeverDispatch() async {
        let results: [(CreateElicitation.Result, MessageSendError)] = [
            (.init(action: .decline), .confirmationDeclined),
            (.init(action: .cancel), .confirmationCancelled),
            (
                .init(action: .accept, content: ["confirmed": .bool(false)]),
                .confirmationMalformed
            ),
            (.init(action: .accept), .confirmationMalformed),
        ]

        for (result, expectedError) in results {
            let sender = RecordingMessagesSender()
            await assertSendError(expectedError) {
                _ = try await self.sendTool(sender: sender)(
                    [
                        "recipient": .string("recipient@example.invalid"),
                        "body": .string("test-body"),
                    ],
                    context: ToolCallContext(
                        elicitation: StubElicitationRequester(result: result)
                    )
                )
            }
            let submissionCount = await sender.submissionCount
            XCTAssertEqual(submissionCount, 0)
        }
    }

    func testUnsupportedElicitationFailsClosed() async {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(error: ElicitationRequestError.formUnsupported)

        do {
            _ = try await sendTool(sender: sender)(
                [
                    "recipient": .string("recipient@example.invalid"),
                    "body": .string("test-body"),
                ],
                context: ToolCallContext(elicitation: requester)
            )
            XCTFail("Expected unsupported elicitation to fail")
        } catch ElicitationRequestError.formUnsupported {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 0)
    }

    func testDisabledConfirmationDispatchesWithoutElicitation() async throws {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(error: ElicitationRequestError.formUnsupported)

        _ = try await sendTool(sender: sender, requiresSendConfirmation: false)(
            [
                "recipient": .string("recipient@example.invalid"),
                "body": .string("test-body"),
            ],
            context: ToolCallContext(elicitation: requester)
        )

        XCTAssertEqual(requester.requestCount, 0)
        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 1)
    }

    func testDisabledConfirmationStillElicitsMissingInput() async {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(error: ElicitationRequestError.formUnsupported)

        do {
            _ = try await sendTool(sender: sender, requiresSendConfirmation: false)(
                [:],
                context: ToolCallContext(elicitation: requester)
            )
            XCTFail("Expected missing input elicitation to fail")
        } catch ElicitationRequestError.formUnsupported {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(requester.requestCount, 1)
        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 0)
    }

    func testAmbiguousAutomationFailureIsNotRetried() async {
        let sender = RecordingMessagesSender(error: MessageSendError.automationFailed)

        await assertSendError(.automationFailed) {
            _ = try await self.sendTool(sender: sender)(
                [
                    "recipient": .string("recipient@example.invalid"),
                    "body": .string("test-body"),
                ],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }

        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 1)
    }

    func testCancelledToolCallDoesNotDispatch() async throws {
        let sender = RecordingMessagesSender()
        let tool = try sendTool(sender: sender)
        let task = Task {
            try await tool(
                [
                    "recipient": .string("recipient@example.invalid"),
                    "body": .string("test-body"),
                ],
                context: ToolCallContext(elicitation: SlowElicitationRequester())
            )
        }

        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected the tool call to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 0)
    }

    func testToolAnnotationsDescribeSideEffect() throws {
        let tool = try XCTUnwrap(
            MessageService(sender: RecordingMessagesSender()).tools.first {
                $0.name == "messages_send"
            }
        )

        XCTAssertEqual(tool.annotations.readOnlyHint, false)
        XCTAssertEqual(tool.annotations.destructiveHint, false)
        XCTAssertEqual(tool.annotations.idempotentHint, false)
        XCTAssertEqual(tool.annotations.openWorldHint, true)
    }

    func testAppleScriptIsFixedAndUsesDescriptorParameters() {
        XCTAssertTrue(AppleScriptMessagesSender.scriptSource.contains("recipientHandle"))
        XCTAssertTrue(AppleScriptMessagesSender.scriptSource.contains("messageBody"))
        XCTAssertFalse(AppleScriptMessagesSender.scriptSource.contains("recipient@example.invalid"))
        XCTAssertFalse(AppleScriptMessagesSender.scriptSource.contains("test-body"))

        var error: NSDictionary?
        let script = NSAppleScript(source: AppleScriptMessagesSender.scriptSource)
        XCTAssertTrue(script?.compileAndReturnError(&error) == true, String(describing: error))
    }

    private var confirmedResult: CreateElicitation.Result {
        .init(action: .accept, content: ["confirmed": .bool(true)])
    }

    private func sendTool(
        sender: RecordingMessagesSender,
        requiresSendConfirmation: Bool = true
    ) throws -> iMCP.Tool {
        try XCTUnwrap(
            MessageService(
                sender: sender,
                requiresSendConfirmation: { requiresSendConfirmation }
            ).tools.first { $0.name == "messages_send" }
        )
    }

    private func assertSendError(
        _ expected: MessageSendError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected message submission to fail")
        } catch let error as MessageSendError {
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor RecordingMessagesSender: MessagesSending {
    private(set) var submissionCount = 0
    private(set) var lastRecipient: String?
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func submit(recipient: String, body: String) throws {
        submissionCount += 1
        lastRecipient = recipient
        if let error { throw error }
    }
}

private final class StubElicitationRequester: ElicitationRequester, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CreateElicitation.Result]
    private let error: Error?
    private var storedRequestCount = 0
    private var storedLastMessage = ""

    var requestCount: Int { lock.withLock { storedRequestCount } }
    var lastMessage: String { lock.withLock { storedLastMessage } }

    init(result: CreateElicitation.Result) {
        self.results = [result]
        self.error = nil
    }

    init(results: [CreateElicitation.Result]) {
        self.results = results
        self.error = nil
    }

    init(error: Error) {
        self.results = []
        self.error = error
    }

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        let result = lock.withLock {
            storedRequestCount += 1
            storedLastMessage = message
            return results.isEmpty ? nil : results.removeFirst()
        }
        if let error { throw error }
        guard let result else { throw MessageSendError.inputMalformed }
        return result
    }
}

private struct SlowElicitationRequester: ElicitationRequester {
    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        try await Task.sleep(for: .seconds(10))
        return .init(action: .accept, content: ["confirmed": .bool(true)])
    }
}

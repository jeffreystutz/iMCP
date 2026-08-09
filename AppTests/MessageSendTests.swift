import AppKit
import MCP
import XCTest

@testable import iMCP

final class MessageSendTests: XCTestCase {
    func testConfirmationModeDefaultsAndUnknownValuesFailSafeToAutomatic() {
        let suiteName = "MessageSendTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MessagesSendConfirmationMode.load(from: defaults), .automatic)
        defaults.set(false, forKey: "messagesSendConfirmationRequired")
        XCTAssertEqual(MessagesSendConfirmationMode.load(from: defaults), .automatic)
        defaults.set("corrupt", forKey: MessagesSendConfirmationMode.storageKey)
        XCTAssertEqual(MessagesSendConfirmationMode.load(from: defaults), .automatic)
        XCTAssertEqual(
            Set(MessagesSendConfirmationMode.allCases.map(\.rawValue)),
            Set(["automatic", "mcpForm", "appDialog"])
        )
    }

    func testConfirmationModeSelectsExactlyOnePresenter() async throws {
        let presentation = MessagesSendConfirmationPresentation(
            title: "Synthetic confirmation",
            message: "Synthetic exact destination and body"
        )

        let automaticForm = StubElicitationRequester(result: confirmedResult, supportsForm: true)
        let unusedNative = RecordingNativeConfirmationPresenter(outcome: .affirmed)
        try await MessagesFinalSendConfirmationRequester(
            mode: { .automatic },
            appPresenter: unusedNative
        ).requestConfirmation(presentation, elicitation: automaticForm)
        XCTAssertEqual(automaticForm.requestCount, 1)
        XCTAssertEqual(unusedNative.requestCount, 0)

        let unsupportedForm = StubElicitationRequester(
            error: ElicitationRequestError.formUnsupported,
            supportsForm: false
        )
        let automaticNative = RecordingNativeConfirmationPresenter(outcome: .affirmed)
        try await MessagesFinalSendConfirmationRequester(
            mode: { .automatic },
            appPresenter: automaticNative
        ).requestConfirmation(presentation, elicitation: unsupportedForm)
        XCTAssertEqual(unsupportedForm.requestCount, 0)
        XCTAssertEqual(automaticNative.requestCount, 1)

        let explicitForm = StubElicitationRequester(result: confirmedResult, supportsForm: true)
        let explicitFormNative = RecordingNativeConfirmationPresenter(outcome: .affirmed)
        try await MessagesFinalSendConfirmationRequester(
            mode: { .mcpForm },
            appPresenter: explicitFormNative
        ).requestConfirmation(presentation, elicitation: explicitForm)
        XCTAssertEqual(explicitForm.requestCount, 1)
        XCTAssertEqual(explicitFormNative.requestCount, 0)

        let explicitAppForm = StubElicitationRequester(result: confirmedResult, supportsForm: true)
        let explicitApp = RecordingNativeConfirmationPresenter(outcome: .affirmed)
        try await MessagesFinalSendConfirmationRequester(
            mode: { .appDialog },
            appPresenter: explicitApp
        ).requestConfirmation(presentation, elicitation: explicitAppForm)
        XCTAssertEqual(explicitAppForm.requestCount, 0)
        XCTAssertEqual(explicitApp.requestCount, 1)
    }

    func testExplicitMCPModeUnsupportedFailsClosedWithoutNativeFallback() async {
        let form = StubElicitationRequester(
            error: ElicitationRequestError.formUnsupported,
            supportsForm: false
        )
        let native = RecordingNativeConfirmationPresenter(outcome: .affirmed)
        let requester = MessagesFinalSendConfirmationRequester(
            mode: { .mcpForm },
            appPresenter: native
        )

        do {
            try await requester.requestConfirmation(
                .init(title: "Synthetic", message: "Synthetic"),
                elicitation: form
            )
            XCTFail("Expected unsupported MCP form confirmation to fail")
        } catch ElicitationRequestError.formUnsupported {
            XCTAssertEqual(native.requestCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAutomaticMCPFailuresAreTerminalWithoutNativeFallback() async {
        let forms = [
            StubElicitationRequester(result: .init(action: .decline)),
            StubElicitationRequester(result: .init(action: .cancel)),
            StubElicitationRequester(
                result: .init(action: .accept, content: ["confirmed": .bool(false)])
            ),
            StubElicitationRequester(error: ElicitationRequestError.timedOut),
            StubElicitationRequester(error: SyntheticConfirmationError.requestFailed),
        ]

        for form in forms {
            let native = RecordingNativeConfirmationPresenter(outcome: .affirmed)
            let requester = MessagesFinalSendConfirmationRequester(
                mode: { .automatic },
                appPresenter: native
            )
            do {
                try await requester.requestConfirmation(
                    .init(title: "Synthetic", message: "Synthetic"),
                    elicitation: form
                )
                XCTFail("Expected MCP confirmation failure")
            } catch {
                XCTAssertEqual(form.requestCount, 1)
                XCTAssertEqual(native.requestCount, 0)
            }
        }
    }

    func testAutomaticMCPParentCancellationNeverFallsBackToNative() async throws {
        let native = RecordingNativeConfirmationPresenter(outcome: .affirmed)
        let requester = MessagesFinalSendConfirmationRequester(
            mode: { .automatic },
            appPresenter: native
        )
        let task = Task {
            try await requester.requestConfirmation(
                .init(title: "Synthetic", message: "Synthetic"),
                elicitation: SlowElicitationRequester()
            )
        }

        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected confirmation cancellation")
        } catch is CancellationError {
            XCTAssertEqual(native.requestCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

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
        // The confirmation is the authorization surface and must show both values.
        XCTAssertTrue(requester.lastMessage.contains("recipient@example.invalid"))
        XCTAssertTrue(requester.lastMessage.contains("test-body"))
    }

    func testRawRecipientConfirmationShowsExactDestinationBodyAndNewConversation() async throws {
        let sender = RecordingMessagesSender()
        let repository = RecordingSendChatRepository(results: [], matches: [.none])
        let requester = StubElicitationRequester(result: confirmedResult)

        let result = try await sendTool(sender: sender, chatRepository: repository)(
            [
                "recipient": .string("brand-new@example.invalid"),
                "body": .string("exact-authorized-body"),
            ],
            context: ToolCallContext(elicitation: requester)
        )

        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertTrue(requester.lastMessage.contains("Recipient: brand-new@example.invalid"))
        XCTAssertTrue(requester.lastMessage.contains("exact-authorized-body"))
        XCTAssertTrue(requester.lastMessage.contains("new direct conversation"))
        XCTAssertFalse(requester.lastMessage.contains("existing Messages conversation"))

        // The sender receives exactly the confirmed values.
        let lastRecipient = await sender.lastRecipient
        let lastBody = await sender.lastBody
        XCTAssertEqual(lastRecipient, "brand-new@example.invalid")
        XCTAssertEqual(lastBody, "exact-authorized-body")

        // Neither value may appear in the tool result.
        let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("brand-new@example.invalid"))
        XCTAssertFalse(encoded.contains("exact-authorized-body"))
    }

    func testMCPAndNativeReceiveTheSameAuthoritativeConfirmationPresentation() async throws {
        let mcpSender = RecordingMessagesSender()
        let mcp = StubElicitationRequester(result: confirmedResult)
        _ = try await sendTool(
            sender: mcpSender,
            chatRepository: RecordingSendChatRepository(results: [
                .success(groupChat), .success(groupChat),
            ])
        )(
            ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("same-exact-body")],
            context: ToolCallContext(elicitation: mcp)
        )

        let nativeSender = RecordingMessagesSender()
        let native = RecordingNativeConfirmationPresenter(outcome: .affirmed)
        let appRequester = MessagesFinalSendConfirmationRequester(
            mode: { .appDialog },
            appPresenter: native
        )
        _ = try await sendTool(
            sender: nativeSender,
            chatRepository: RecordingSendChatRepository(results: [
                .success(groupChat), .success(groupChat),
            ]),
            sendConfirmationRequester: appRequester
        )(
            ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("same-exact-body")],
            context: ToolCallContext(
                elicitation: StubElicitationRequester(result: confirmedResult)
            )
        )

        XCTAssertEqual(native.lastPresentation?.title, mcp.lastTitle)
        XCTAssertEqual(native.lastPresentation?.message, mcp.lastMessage)
        XCTAssertTrue(native.lastPresentation?.message.contains("Synthetic Group") == true)
        XCTAssertTrue(native.lastPresentation?.message.contains("first@example.invalid") == true)
        XCTAssertTrue(native.lastPresentation?.message.contains("second@example.invalid") == true)
        XCTAssertTrue(native.lastPresentation?.message.contains("same-exact-body") == true)
    }

    func testNativeCancelAndUnexpectedResponsesDispatchZero() async {
        let native = RecordingNativeConfirmationPresenter(outcome: .cancelled)
        let sender = RecordingMessagesSender()
        await assertSendError(.confirmationCancelled) {
            _ = try await self.sendTool(
                sender: sender,
                sendConfirmationRequester: MessagesFinalSendConfirmationRequester(
                    mode: { .appDialog },
                    appPresenter: native
                )
            )(
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
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(native.requestCount, 1)
        XCTAssertEqual(
            AppKitMessagesSendConfirmationPresenter.outcome(for: .abort),
            .cancelled
        )
    }

    func testNativeAffirmationRevalidatesThenDispatchesExactlyOnce() async throws {
        let repository = RecordingSendChatRepository(results: [
            .success(directChat), .success(directChat),
        ])
        let native = RecordingNativeConfirmationPresenter(outcome: .affirmed) {
            XCTAssertEqual(repository.resolveCount, 1)
        }
        let sender = RecordingMessagesSender()
        _ = try await sendTool(
            sender: sender,
            chatRepository: repository,
            sendConfirmationRequester: MessagesFinalSendConfirmationRequester(
                mode: { .appDialog },
                appPresenter: native
            )
        )(
            ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
            context: ToolCallContext(
                elicitation: StubElicitationRequester(result: confirmedResult)
            )
        )

        XCTAssertEqual(repository.resolveCount, 2)
        let chatSubmissionCount = await sender.chatSubmissionCount
        let rawSubmissionCount = await sender.submissionCount
        XCTAssertEqual(chatSubmissionCount, 1)
        XCTAssertEqual(rawSubmissionCount, 0)
    }

    func testNativeAffirmationStillFailsClosedForStaleDestination() async {
        let changed = MessagesResolvedChatDestination(
            chatGuid: directChat.chatGuid,
            displayName: directChat.displayName,
            roomName: directChat.roomName,
            kind: directChat.kind,
            participantCount: 2,
            participantHandles: directChat.participantHandles + ["changed@example.invalid"],
            service: directChat.service
        )
        let repository = RecordingSendChatRepository(results: [
            .success(directChat), .success(changed),
        ])
        let sender = RecordingMessagesSender()
        await assertSendError(.staleChatIdentifier) {
            _ = try await self.sendTool(
                sender: sender,
                chatRepository: repository,
                sendConfirmationRequester: MessagesFinalSendConfirmationRequester(
                    mode: { .appDialog },
                    appPresenter: RecordingNativeConfirmationPresenter(outcome: .affirmed)
                )
            )(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }
        let chatSubmissionCount = await sender.chatSubmissionCount
        XCTAssertEqual(chatSubmissionCount, 0)
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

    func testMissingBodyIsElicitedBeforeSeparateConfirmation() async throws {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(results: [
            .init(
                action: .accept,
                content: [
                    "body": .string("test-body")
                ]
            ),
            confirmedResult,
        ])

        _ = try await sendTool(sender: sender)(
            ["recipient": .string("recipient@example.invalid")],
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
                ["recipient": .string("recipient@example.invalid")],
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

    func testCompleteRawRecipientCallStillRequestsExactlyOneFinalConfirmation() async throws {
        let sender = RecordingMessagesSender()
        let repository = RecordingSendChatRepository(results: [], matches: [.none])
        let requester = StubElicitationRequester(result: confirmedResult)

        _ = try await sendTool(sender: sender, chatRepository: repository)(
            [
                "recipient": .string("recipient@example.invalid"),
                "body": .string("test-body"),
            ],
            context: ToolCallContext(elicitation: requester)
        )

        // Nothing supplies every input up front well enough to skip confirmation.
        XCTAssertEqual(requester.requestCount, 1)
        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 1)
    }

    func testMissingInputElicitationIsNeverTreatedAsFinalConfirmation() async {
        // A client that supplies the body but cannot show a form must dispatch zero: the
        // input round trip is not authorization.
        let sender = RecordingMessagesSender()
        let repository = RecordingSendChatRepository(results: [], matches: [.none])
        let requester = StubElicitationRequester(
            results: [.init(action: .accept, content: ["body": .string("test-body")])]
        )

        await assertSendError(.inputMalformed) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["recipient": .string("recipient@example.invalid")],
                context: ToolCallContext(elicitation: requester)
            )
        }

        // Two requests: one for the missing body, one for the separate final confirmation.
        XCTAssertEqual(requester.requestCount, 2)
        let submissionCount = await sender.submissionCount
        XCTAssertEqual(submissionCount, 0)
    }

    func testNoProductionCodePathCanBypassSendConfirmation() throws {
        // The confirmation-disable preference key, its Settings UI, and the injectable
        // predicate were removed. Guard against any of them returning.
        let sources = [
            "App/Services/Messages.swift",
            "App/Services/MessagesSendConfirmation.swift",
            "App/Views/SettingsView.swift",
            "App/Services/MessagesSender.swift",
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for source in sources {
            let contents = try String(
                contentsOf: root.appendingPathComponent(source),
                encoding: .utf8
            )
            for symbol in [
                "messagesSendConfirmationRequired",
                "requiresSendConfirmation",
                "Disable Confirmation",
                "confirmation is disabled",
            ] {
                XCTAssertFalse(
                    contents.contains(symbol),
                    "\(source) still references the removed confirmation bypass: \(symbol)"
                )
            }
        }

        let nativeSource = try String(
            contentsOf: root.appendingPathComponent(
                "App/Services/MessagesSendConfirmation.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(nativeSource.contains("@MainActor"))
        XCTAssertTrue(nativeSource.contains("activate(ignoringOtherApps: true)"))
        XCTAssertTrue(nativeSource.contains("orderFrontRegardless()"))
        XCTAssertTrue(nativeSource.contains("addButton(withTitle: \"Send\")"))
        XCTAssertTrue(nativeSource.contains("addButton(withTitle: \"Cancel\")"))
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
        XCTAssertTrue(AppleScriptMessagesSender.scriptSource.contains("chatGUID"))
        XCTAssertTrue(AppleScriptMessagesSender.scriptSource.contains("messageBody"))
        XCTAssertFalse(AppleScriptMessagesSender.scriptSource.contains("recipient@example.invalid"))
        XCTAssertFalse(AppleScriptMessagesSender.scriptSource.contains("test-body"))
        XCTAssertFalse(AppleScriptMessagesSender.scriptSource.contains("synthetic-guid.example"))

        var error: NSDictionary?
        let script = NSAppleScript(source: AppleScriptMessagesSender.scriptSource)
        XCTAssertTrue(script?.compileAndReturnError(&error) == true, String(describing: error))
    }

    func testChatInputRequiresExactlyOneNonemptyRecognizedDestination() async {
        let sender = RecordingMessagesSender()
        let repository = RecordingSendChatRepository(results: [.success(directChat)])
        let requester = StubElicitationRequester(result: confirmedResult)

        await assertSendError(.invalidDestination) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                [
                    "recipient": .string("recipient@example.invalid"),
                    "chat_id": .string("imcp-chat-v1_synthetic"),
                    "body": .string("test-body"),
                ],
                context: ToolCallContext(elicitation: requester)
            )
        }
        await assertSendError(.invalidChatIdentifier) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("  "), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }
        let malformed = RecordingSendChatRepository(results: [
            .failure(MessagesChatRepositoryError.invalidIdentifier)
        ])
        await assertSendError(.invalidChatIdentifier) {
            _ = try await self.sendTool(sender: sender, chatRepository: malformed)(
                ["chat_id": .string("not-an-imcp-id"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }
        let recipientSubmissions = await sender.submissionCount
        let chatSubmissions = await sender.chatSubmissionCount
        XCTAssertEqual(recipientSubmissions, 0)
        XCTAssertEqual(chatSubmissions, 0)
    }

    func testAcceptedDirectChatConfirmsMetadataRevalidatesAndDispatchesOnce() async throws {
        let sender = RecordingMessagesSender()
        let repository = RecordingSendChatRepository(results: [
            .success(directChat), .success(directChat),
        ])
        let requester = StubElicitationRequester(result: confirmedResult)
        let result = try await sendTool(sender: sender, chatRepository: repository)(
            ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
            context: ToolCallContext(elicitation: requester)
        )

        XCTAssertEqual(repository.resolveCount, 2)
        let chatSubmissions = await sender.chatSubmissionCount
        let recipientSubmissions = await sender.submissionCount
        let lastChatGUID = await sender.lastChatGUID
        XCTAssertEqual(chatSubmissions, 1)
        XCTAssertEqual(recipientSubmissions, 0)
        XCTAssertTrue(lastChatGUID == "synthetic-guid.example")
        XCTAssertTrue(requester.lastMessage.contains("Synthetic Direct"))
        XCTAssertTrue(requester.lastMessage.contains("Type: direct"))
        XCTAssertTrue(requester.lastMessage.contains("Participant count: 1"))
        XCTAssertTrue(requester.lastMessage.contains("recipient@example.invalid"))
        XCTAssertTrue(requester.lastMessage.contains("test-body"))
        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "submitted")
        XCTAssertEqual(result.objectValue?["service"]?.stringValue, "Messages")
        let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("synthetic"))
        XCTAssertFalse(encoded.contains("recipient@example.invalid"))
        XCTAssertFalse(encoded.contains("test-body"))
    }

    func testGroupChatConfirmationIsMandatory() async {
        let sender = RecordingMessagesSender()
        let repository = RecordingSendChatRepository(results: [.success(groupChat)])
        let requester = StubElicitationRequester(result: .init(action: .decline))

        await assertSendError(.confirmationDeclined) {
            _ = try await self.sendTool(
                sender: sender,
                chatRepository: repository
            )(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }
        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertTrue(requester.lastMessage.contains("Synthetic Group"))
        XCTAssertTrue(requester.lastMessage.contains("Synthetic Room"))
        XCTAssertTrue(requester.lastMessage.contains("Type: group"))
        XCTAssertTrue(requester.lastMessage.contains("Participant count: 2"))
        XCTAssertTrue(requester.lastMessage.contains("first@example.invalid"))
        XCTAssertTrue(requester.lastMessage.contains("second@example.invalid"))
        XCTAssertTrue(requester.lastMessage.contains("test-body"))
        let chatSubmissions = await sender.chatSubmissionCount
        XCTAssertEqual(chatSubmissions, 0)
    }

    func testChatDeclineCancelMalformedUnsupportedAndTimeoutDispatchZero() async {
        let outcomes: [StubElicitationRequester] = [
            .init(result: .init(action: .decline)),
            .init(result: .init(action: .cancel)),
            .init(result: .init(action: .accept, content: ["confirmed": .bool(false)])),
            .init(error: ElicitationRequestError.formUnsupported),
        ]
        for requester in outcomes {
            let sender = RecordingMessagesSender()
            let repository = RecordingSendChatRepository(results: [.success(directChat)])
            do {
                _ = try await sendTool(sender: sender, chatRepository: repository)(
                    ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                    context: ToolCallContext(elicitation: requester)
                )
                XCTFail("Expected chat confirmation to fail")
            } catch {}
            let chatSubmissions = await sender.chatSubmissionCount
            XCTAssertEqual(chatSubmissions, 0)
        }

        let timeoutSender = RecordingMessagesSender()
        let timeoutRepository = RecordingSendChatRepository(results: [.success(directChat)])
        let task = Task {
            try await self.sendTool(sender: timeoutSender, chatRepository: timeoutRepository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: SlowElicitationRequester())
            )
        }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        _ = try? await task.value
        let timeoutSubmissions = await timeoutSender.chatSubmissionCount
        XCTAssertEqual(timeoutSubmissions, 0)
    }

    func testChatResolutionErrorsAndChangedMetadataDispatchZero() async {
        for error in [
            MessagesChatRepositoryError.staleIdentifier,
            MessagesChatRepositoryError.queryFailed(stage: "resolve-duplicate", code: 1),
        ] {
            let sender = RecordingMessagesSender()
            let repository = RecordingSendChatRepository(results: [.failure(error)])
            do {
                _ = try await sendTool(sender: sender, chatRepository: repository)(
                    ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                    context: ToolCallContext(
                        elicitation: StubElicitationRequester(result: confirmedResult)
                    )
                )
                XCTFail("Expected chat resolution to fail")
            } catch {}
            let chatSubmissions = await sender.chatSubmissionCount
            XCTAssertEqual(chatSubmissions, 0)
        }

        let changed = MessagesResolvedChatDestination(
            chatGuid: directChat.chatGuid,
            displayName: directChat.displayName,
            roomName: directChat.roomName,
            kind: directChat.kind,
            participantCount: 2,
            participantHandles: directChat.participantHandles + ["second@example.invalid"],
            service: directChat.service
        )
        let sender = RecordingMessagesSender()
        let repository = RecordingSendChatRepository(results: [
            .success(directChat), .success(changed),
        ])
        await assertSendError(.staleChatIdentifier) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }
        let changedChatSubmissions = await sender.chatSubmissionCount
        XCTAssertEqual(changedChatSubmissions, 0)
    }

    func testChatAutomationAmbiguityIsNotRetriedOrFallenBack() async {
        let sender = RecordingMessagesSender(error: MessageSendError.ambiguousSubmission)
        let repository = RecordingSendChatRepository(results: [
            .success(groupChat), .success(groupChat),
        ])
        await assertSendError(.ambiguousSubmission) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }
        let chatSubmissions = await sender.chatSubmissionCount
        let recipientSubmissions = await sender.submissionCount
        XCTAssertEqual(chatSubmissions, 1)
        XCTAssertEqual(recipientSubmissions, 0)
    }

    func testChatServicesResolveWithoutCallerSelectedTransport() async throws {
        for service in ["iMessage", "SMS", "RCS"] {
            let chat = MessagesResolvedChatDestination(
                chatGuid: "synthetic-guid.example",
                displayName: "Synthetic Direct",
                roomName: nil,
                kind: .direct,
                participantCount: 1,
                participantHandles: ["recipient@example.invalid"],
                service: service
            )
            let sender = RecordingMessagesSender()
            let repository = RecordingSendChatRepository(results: [
                .success(chat), .success(chat),
            ])
            _ = try await sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: confirmedResult)
                )
            )
            let chatSubmissions = await sender.chatSubmissionCount
            XCTAssertEqual(chatSubmissions, 1)
        }
    }

    func testAdvertisedToolExplainsExistingGroupOnlySemantics() throws {
        let tool = try XCTUnwrap(
            MessageService(sender: RecordingMessagesSender()).tools.first {
                $0.name == "messages_send"
            }
        )
        let description = tool.description.lowercased()
        XCTAssertTrue(description.contains("existing group"))
        XCTAssertTrue(description.contains("cannot create a new group"))
        XCTAssertTrue(description.contains("exactly match"))
        XCTAssertTrue(description.contains("fails without sending"))
        XCTAssertTrue(description.contains("use chat_id"))

        let encoded = try JSONEncoder().encode(tool.inputSchema)
        let schemaText = try XCTUnwrap(String(data: encoded, encoding: .utf8)).lowercased()
        XCTAssertTrue(schemaText.contains("complete set of remote participants"))
        XCTAssertTrue(schemaText.contains("does not create a new group"))
        XCTAssertTrue(schemaText.contains("exactly match one existing group"))
        XCTAssertTrue(schemaText.contains("fails without sending"))
        XCTAssertTrue(schemaText.contains("existing direct or group conversation"))
    }

    func testDestinationFormsAndGroupValidation() async {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(result: confirmedResult)
        await assertSendError(.invalidDestination) {
            _ = try await self.sendTool(sender: sender)(
                ["body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }
        let combinations: [[String: Value]] = [
            [
                "recipient": .string("one@example.invalid"),
                "recipients": .array([.string("one@example.invalid"), .string("two@example.invalid")]),
                "body": .string("test-body"),
            ],
            [
                "recipient": .string("one@example.invalid"),
                "chat_id": .string("imcp-chat-v1_synthetic"),
                "body": .string("test-body"),
            ],
            [
                "recipients": .array([.string("one@example.invalid"), .string("two@example.invalid")]),
                "chat_id": .string("imcp-chat-v1_synthetic"),
                "body": .string("test-body"),
            ],
        ]
        for arguments in combinations {
            await assertSendError(.invalidDestination) {
                _ = try await self.sendTool(sender: sender)(
                    arguments,
                    context: ToolCallContext(elicitation: requester)
                )
            }
        }
        for recipients in [
            ["one@example.invalid"],
            ["ONE@example.invalid", "one@example.invalid"],
        ] {
            await assertSendError(.insufficientGroupParticipants) {
                _ = try await self.sendTool(sender: sender)(
                    [
                        "recipients": .array(recipients.map(Value.string)),
                        "body": .string("test-body"),
                    ],
                    context: ToolCallContext(elicitation: requester)
                )
            }
        }
        await assertSendError(.invalidRecipient) {
            _ = try await self.sendTool(sender: sender)(
                [
                    "recipients": .array([.string("invalid"), .string("two@example.invalid")]),
                    "body": .string("test-body"),
                ],
                context: ToolCallContext(elicitation: requester)
            )
        }
    }

    func testUniqueDirectMatchUsesExistingChatAndRevalidates() async throws {
        let sender = RecordingMessagesSender()
        let match = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic",
            destination: directChat
        )
        let repository = RecordingSendChatRepository(results: [], matches: [match, match])
        let requester = StubElicitationRequester(result: confirmedResult)
        _ = try await sendTool(sender: sender, chatRepository: repository)(
            ["recipient": .string("RECIPIENT@example.invalid"), "body": .string("test-body")],
            context: ToolCallContext(elicitation: requester)
        )
        XCTAssertEqual(repository.matchCount, 2)
        let chatCount = await sender.chatSubmissionCount
        let rawCount = await sender.submissionCount
        XCTAssertEqual(chatCount, 1)
        XCTAssertEqual(rawCount, 0)
        XCTAssertTrue(requester.lastMessage.contains("existing Messages conversation"))
        XCTAssertTrue(requester.lastMessage.contains("recipient@example.invalid"))
        XCTAssertTrue(requester.lastMessage.contains("test-body"))
    }

    func testUnmatchedDirectPreservesRawPathAndAmbiguityFailsClosed() async throws {
        let rawSender = RecordingMessagesSender()
        let rawRepository = RecordingSendChatRepository(results: [], matches: [.none])
        _ = try await sendTool(sender: rawSender, chatRepository: rawRepository)(
            ["recipient": .string("new@example.invalid"), "body": .string("test-body")],
            context: ToolCallContext(
                elicitation: StubElicitationRequester(result: confirmedResult)
            )
        )
        let rawSubmissionCount = await rawSender.submissionCount
        let rawChatCount = await rawSender.chatSubmissionCount
        XCTAssertEqual(rawSubmissionCount, 1)
        XCTAssertEqual(rawChatCount, 0)

        let ambiguousSender = RecordingMessagesSender()
        let ambiguousRepository = RecordingSendChatRepository(results: [], matches: [.ambiguous])
        await assertSendError(.ambiguousDirectConversation) {
            _ = try await self.sendTool(
                sender: ambiguousSender,
                chatRepository: ambiguousRepository
            )(
                ["recipient": .string("one@example.invalid"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: StubElicitationRequester(result: confirmedResult))
            )
        }
        let ambiguousRawCount = await ambiguousSender.submissionCount
        let ambiguousChatCount = await ambiguousSender.chatSubmissionCount
        XCTAssertEqual(ambiguousRawCount, 0)
        XCTAssertEqual(ambiguousChatCount, 0)
    }

    func testIncompleteDirectMembershipFailsClosedWithoutConfirmationOrDispatch() async {
        // Unresolved membership is not proof that no conversation exists, so it must not
        // silently become a raw-recipient send on a possibly different route.
        let sender = RecordingMessagesSender()
        let repository = RecordingSendChatRepository(results: [], matches: [.incomplete])
        let requester = StubElicitationRequester(result: confirmedResult)

        await assertSendError(.incompleteDirectMembership) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["recipient": .string("unknown@example.invalid"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }

        XCTAssertEqual(requester.requestCount, 0)
        let rawCount = await sender.submissionCount
        let chatCount = await sender.chatSubmissionCount
        XCTAssertEqual(rawCount, 0)
        XCTAssertEqual(chatCount, 0)
    }

    func testIncompleteDirectMembershipUsesItsOwnErrorNotTheGroupWording() {
        XCTAssertNotEqual(
            MessageSendError.incompleteDirectMembership.localizedDescription,
            MessageSendError.incompleteGroupMembership.localizedDescription
        )
        XCTAssertTrue(
            MessageSendError.incompleteDirectMembership.localizedDescription
                .contains("direct conversation")
        )
    }

    func testUniqueDirectMatchThatBecomesUnresolvableBeforeDispatchFailsWithoutFallback() async {
        // Confirmed against a matched chat, then revalidation degrades. Nothing may be sent,
        // and the call must not switch to the raw-recipient path it originally rejected.
        for degraded in [
            MessagesConversationMatch.incomplete,
            .none,
            .ambiguous,
        ] {
            let sender = RecordingMessagesSender()
            let repository = RecordingSendChatRepository(
                results: [],
                matches: [
                    .unique(publicChatID: "imcp-chat-v1_synthetic", destination: directChat),
                    degraded,
                ]
            )
            await assertSendError(.staleMatchedConversation) {
                _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                    [
                        "recipient": .string("recipient@example.invalid"),
                        "body": .string("test-body"),
                    ],
                    context: ToolCallContext(
                        elicitation: StubElicitationRequester(result: self.confirmedResult)
                    )
                )
            }
            let rawCount = await sender.submissionCount
            let chatCount = await sender.chatSubmissionCount
            XCTAssertEqual(rawCount, 0, "raw-recipient fallback after confirmation")
            XCTAssertEqual(chatCount, 0)
        }
    }

    func testExactGroupMatchIgnoresOrderConfirmsAndDispatchesOnce() async throws {
        let sender = RecordingMessagesSender()
        let match = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic",
            destination: groupChat
        )
        let repository = RecordingSendChatRepository(results: [], matches: [match, match])
        let requester = StubElicitationRequester(result: confirmedResult)
        _ = try await sendTool(sender: sender, chatRepository: repository)(
            [
                "recipients": .array([
                    .string("SECOND@example.invalid"), .string("first@example.invalid"),
                ]),
                "body": .string("test-body"),
            ],
            context: ToolCallContext(elicitation: requester)
        )
        XCTAssertEqual(repository.matchCount, 2)
        let chatCount = await sender.chatSubmissionCount
        let rawCount = await sender.submissionCount
        XCTAssertEqual(chatCount, 1)
        XCTAssertEqual(rawCount, 0)
        XCTAssertTrue(requester.lastMessage.contains("exactly matches"))
        XCTAssertTrue(requester.lastMessage.contains("No new group will be created"))
        XCTAssertTrue(requester.lastMessage.contains("first@example.invalid"))
        XCTAssertTrue(requester.lastMessage.contains("second@example.invalid"))
    }

    func testGroupNoMatchIncompleteAmbiguousAndStaleDispatchZero() async {
        let cases: [(MessagesConversationMatch, MessageSendError)] = [
            (.none, .groupConversationNotFound),
            (.incomplete, .incompleteGroupMembership),
            (.ambiguous, .ambiguousGroupConversation),
        ]
        for (match, expected) in cases {
            let sender = RecordingMessagesSender()
            let repository = RecordingSendChatRepository(results: [], matches: [match])
            await assertSendError(expected) {
                _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                    [
                        "recipients": .array([
                            .string("first@example.invalid"), .string("second@example.invalid"),
                        ]),
                        "body": .string("test-body"),
                    ],
                    context: ToolCallContext(elicitation: StubElicitationRequester(result: confirmedResult))
                )
            }
            let chatCount = await sender.chatSubmissionCount
            let rawCount = await sender.submissionCount
            XCTAssertEqual(chatCount, 0)
            XCTAssertEqual(rawCount, 0)
        }

        let sender = RecordingMessagesSender()
        let initial = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic",
            destination: groupChat
        )
        let repository = RecordingSendChatRepository(results: [], matches: [initial, .none])
        await assertSendError(.staleMatchedConversation) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                [
                    "recipients": .array([
                        .string("first@example.invalid"), .string("second@example.invalid"),
                    ]),
                    "body": .string("test-body"),
                ],
                context: ToolCallContext(elicitation: StubElicitationRequester(result: confirmedResult))
            )
        }
        let staleChatCount = await sender.chatSubmissionCount
        XCTAssertEqual(staleChatCount, 0)
    }

    // MARK: - Existing-chat automation addressability

    func testAlreadyAuthorizedUnavailableChatSkipsConfirmationAndDispatch() async {
        let sender = RecordingMessagesSender(authorization: .authorized, addressability: [false])
        let repository = RecordingSendChatRepository(results: [.success(directChat)])
        let requester = StubElicitationRequester(result: confirmedResult)

        await assertSendError(.chatUnavailableInAutomation) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }

        XCTAssertEqual(requester.requestCount, 0, "unavailable chat still asked for authorization")
        let probes = await sender.addressabilityCount
        let authorizationRequests = await sender.authorizationRequestCount
        let chatSubmissions = await sender.chatSubmissionCount
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(authorizationRequests, 0, "a failed pre-check must not request TCC")
        XCTAssertEqual(chatSubmissions, 0)
    }

    func testAlreadyAuthorizedAvailableChatProceedsToConfirmationAndDispatch() async throws {
        let sender = RecordingMessagesSender(authorization: .authorized)
        let repository = RecordingSendChatRepository(results: [
            .success(directChat), .success(directChat),
        ])
        let requester = StubElicitationRequester(result: confirmedResult)

        _ = try await sendTool(sender: sender, chatRepository: repository)(
            ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
            context: ToolCallContext(elicitation: requester)
        )

        XCTAssertEqual(requester.requestCount, 1)
        let probes = await sender.addressabilityCount
        let guids = await sender.addressabilityGUIDs
        let chatSubmissions = await sender.chatSubmissionCount
        // Once before confirmation, once immediately before dispatch.
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(guids, ["synthetic-guid.example", "synthetic-guid.example"])
        XCTAssertEqual(chatSubmissions, 1)
    }

    func testDeniedAutomationFailsClosedWithoutConfirmationOrPrompt() async {
        let sender = RecordingMessagesSender(authorization: .denied)
        let repository = RecordingSendChatRepository(results: [.success(directChat)])
        let requester = StubElicitationRequester(result: confirmedResult)

        await assertSendError(.automationDenied) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }

        XCTAssertEqual(requester.requestCount, 0)
        let probes = await sender.addressabilityCount
        let authorizationRequests = await sender.authorizationRequestCount
        let chatSubmissions = await sender.chatSubmissionCount
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(authorizationRequests, 0)
        XCTAssertEqual(chatSubmissions, 0)
    }

    func testConsentRequiredNeverAutomatesBeforeConfirmationAndPromptsAfterIt() async throws {
        for status in [MessagesAutomationAuthorization.consentRequired, .unknown] {
            let log = SendEventLog()
            let sender = RecordingMessagesSender(authorization: status, eventLog: log)
            let repository = RecordingSendChatRepository(results: [
                .success(directChat), .success(directChat),
            ])
            let requester = StubElicitationRequester(result: confirmedResult, eventLog: log)

            _ = try await sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )

            // The status check itself cannot prompt. Nothing that can prompt, and no
            // Apple Event at all, may precede the immutable confirmation.
            XCTAssertEqual(
                log.events,
                [
                    "automation-status",
                    "elicitation",
                    "automation-request",
                    "addressability",
                    "chat-submit",
                ],
                "TCC or addressability moved ahead of confirmation for \(status)"
            )
        }
    }

    func testConsentRequiredDeclineRequestsNoPermissionAndDispatchesZero() async {
        let sender = RecordingMessagesSender(authorization: .consentRequired)
        let repository = RecordingSendChatRepository(results: [.success(directChat)])
        let requester = StubElicitationRequester(result: .init(action: .decline))

        await assertSendError(.confirmationDeclined) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(elicitation: requester)
            )
        }

        let authorizationRequests = await sender.authorizationRequestCount
        let probes = await sender.addressabilityCount
        let chatSubmissions = await sender.chatSubmissionCount
        XCTAssertEqual(authorizationRequests, 0)
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(chatSubmissions, 0)
    }

    func testDeniedPermissionAfterConfirmationDispatchesZero() async {
        let sender = RecordingMessagesSender(
            authorization: .consentRequired,
            authorizationError: MessageSendError.automationDenied
        )
        let repository = RecordingSendChatRepository(results: [
            .success(directChat), .success(directChat),
        ])

        await assertSendError(.automationDenied) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }

        let authorizationRequests = await sender.authorizationRequestCount
        let probes = await sender.addressabilityCount
        let chatSubmissions = await sender.chatSubmissionCount
        XCTAssertEqual(authorizationRequests, 1)
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(chatSubmissions, 0)
    }

    func testUnavailableAfterConfirmationDispatchesZeroAndIsNotRetried() async {
        // Consent-required discovers unavailability only after TCC; the already-authorized
        // case proves the early probe never authorizes or reserves the conversation.
        let cases: [(MessagesAutomationAuthorization, [Bool], Int)] = [
            (.consentRequired, [false], 1),
            (.authorized, [true, false], 2),
        ]
        for (status, addressability, expectedProbes) in cases {
            let sender = RecordingMessagesSender(
                authorization: status,
                addressability: addressability
            )
            let repository = RecordingSendChatRepository(results: [
                .success(directChat), .success(directChat),
            ])

            await assertSendError(.chatUnavailableInAutomation) {
                _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                    ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                    context: ToolCallContext(
                        elicitation: StubElicitationRequester(result: self.confirmedResult)
                    )
                )
            }

            let probes = await sender.addressabilityCount
            let chatSubmissions = await sender.chatSubmissionCount
            let rawSubmissions = await sender.submissionCount
            XCTAssertEqual(probes, expectedProbes)
            XCTAssertEqual(chatSubmissions, 0)
            XCTAssertEqual(rawSubmissions, 0, "an unaddressable chat must not change route")
        }
    }

    func testStaleDestinationAfterConfirmationFailsBeforeAnyPermissionRequest() async {
        let changed = MessagesResolvedChatDestination(
            chatGuid: directChat.chatGuid,
            displayName: directChat.displayName,
            roomName: directChat.roomName,
            kind: directChat.kind,
            participantCount: 2,
            participantHandles: directChat.participantHandles + ["changed@example.invalid"],
            service: directChat.service
        )
        let sender = RecordingMessagesSender(authorization: .authorized)
        let repository = RecordingSendChatRepository(results: [
            .success(directChat), .success(changed),
        ])

        await assertSendError(.staleChatIdentifier) {
            _ = try await self.sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }

        let authorizationRequests = await sender.authorizationRequestCount
        let chatSubmissions = await sender.chatSubmissionCount
        XCTAssertEqual(authorizationRequests, 0, "stale destination must fail before TCC")
        XCTAssertEqual(chatSubmissions, 0)
    }

    func testAddressabilityIsIndependentOfChatServiceType() async throws {
        // Recent iMessage, SMS, and RCS conversations all resolve through the same
        // public `chat` abstraction, so no branch may key on service.
        for service in ["iMessage", "SMS", "RCS", "Unknown"] {
            let chat = MessagesResolvedChatDestination(
                chatGuid: "synthetic-guid.example",
                displayName: "Synthetic Direct",
                roomName: nil,
                kind: .direct,
                participantCount: 1,
                participantHandles: ["recipient@example.invalid"],
                service: service
            )
            let sender = RecordingMessagesSender(authorization: .authorized)
            let repository = RecordingSendChatRepository(results: [
                .success(chat), .success(chat),
            ])
            _ = try await sendTool(sender: sender, chatRepository: repository)(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: confirmedResult)
                )
            )
            let chatSubmissions = await sender.chatSubmissionCount
            XCTAssertEqual(chatSubmissions, 1, "service \(service) was treated differently")
        }

        let unavailableSender = RecordingMessagesSender(
            authorization: .authorized,
            addressability: [false]
        )
        let smsChat = MessagesResolvedChatDestination(
            chatGuid: "synthetic-guid.example",
            displayName: "Synthetic Direct",
            roomName: nil,
            kind: .direct,
            participantCount: 1,
            participantHandles: ["recipient@example.invalid"],
            service: "SMS"
        )
        await assertSendError(.chatUnavailableInAutomation) {
            _ = try await self.sendTool(
                sender: unavailableSender,
                chatRepository: RecordingSendChatRepository(results: [.success(smsChat)])
            )(
                ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }
    }

    func testMatchedRecipientAndGroupSendsAlsoVerifyAddressability() async throws {
        for (chat, arguments) in [
            (
                directChat,
                [
                    "recipient": Value.string("recipient@example.invalid"),
                    "body": .string("test-body"),
                ]
            ),
            (
                groupChat,
                [
                    "recipients": Value.array([
                        .string("first@example.invalid"), .string("second@example.invalid"),
                    ]),
                    "body": .string("test-body"),
                ]
            ),
        ] {
            let sender = RecordingMessagesSender(authorization: .authorized)
            let match = MessagesConversationMatch.unique(
                publicChatID: "imcp-chat-v1_synthetic",
                destination: chat
            )
            let repository = RecordingSendChatRepository(results: [], matches: [match, match])
            _ = try await sendTool(sender: sender, chatRepository: repository)(
                arguments,
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: confirmedResult)
                )
            )
            let probes = await sender.addressabilityCount
            let guids = await sender.addressabilityGUIDs
            let chatSubmissions = await sender.chatSubmissionCount
            XCTAssertEqual(probes, 2)
            XCTAssertEqual(guids, [chat.chatGuid, chat.chatGuid])
            XCTAssertEqual(chatSubmissions, 1)
        }
    }

    func testAutomationAddressabilityErrorNamesTheRealConditionWithoutPrivateValues() throws {
        let description = MessageSendError.chatUnavailableInAutomation.localizedDescription
        XCTAssertTrue(description.contains("not currently available through Messages automation"))
        XCTAssertTrue(description.contains("Nothing was sent."))
        for leaked in [
            "synthetic-guid.example", "recipient@example.invalid", "test-body", "SMS", "RCS",
            "iMessage",
        ] {
            XCTAssertFalse(
                description.contains(leaked),
                "the addressability error must not expose \(leaked)"
            )
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for source in ["App/Services/MessagesSender.swift", "App/Services/Messages.swift"] {
            let contents = try String(
                contentsOf: root.appendingPathComponent(source),
                encoding: .utf8
            )
            XCTAssertFalse(
                contents.contains("unsupportedChatType"),
                "\(source) still uses the misleading chat-type error name"
            )
        }
    }

    func testFixedScriptExposesAReadOnlyAddressabilityHandler() {
        let source = AppleScriptMessagesSender.scriptSource
        XCTAssertTrue(source.contains("on chatIsAddressable(chatGUID)"))
        XCTAssertTrue(source.contains("exists chat id chatGUID"))
        // The probe reads addressability and nothing else.
        let handler = source.components(separatedBy: "on chatIsAddressable(chatGUID)")[1]
            .components(separatedBy: "end chatIsAddressable")[0]
        for forbidden in ["send", "participant", "account", "message", "delete", "set "] {
            XCTAssertFalse(
                handler.contains(forbidden),
                "the addressability handler must not reference \(forbidden)"
            )
        }
        // The zero-match guard remains the last race defense before dispatch.
        XCTAssertTrue(source.contains("if (count of targetChats) is 0 then error"))
    }

    private var directChat: MessagesResolvedChatDestination {
        MessagesResolvedChatDestination(
            chatGuid: "synthetic-guid.example",
            displayName: "Synthetic Direct",
            roomName: nil,
            kind: .direct,
            participantCount: 1,
            participantHandles: ["recipient@example.invalid"],
            service: "iMessage"
        )
    }

    private var groupChat: MessagesResolvedChatDestination {
        MessagesResolvedChatDestination(
            chatGuid: "synthetic-group-guid.example",
            displayName: "Synthetic Group",
            roomName: "Synthetic Room",
            kind: .group,
            participantCount: 2,
            participantHandles: ["first@example.invalid", "second@example.invalid"],
            service: "RCS"
        )
    }

    private var confirmedResult: CreateElicitation.Result {
        .init(action: .accept, content: ["confirmed": .bool(true)])
    }

    private func sendTool(
        sender: RecordingMessagesSender,
        chatRepository: (any MessagesChatListing)? = nil,
        sendConfirmationRequester: any MessagesFinalSendConfirmationRequesting =
            MessagesFinalSendConfirmationRequester(mode: { .mcpForm })
    ) throws -> iMCP.Tool {
        let repository = chatRepository ?? RecordingSendChatRepository(results: [])
        return try XCTUnwrap(
            MessageService(
                sender: sender,
                chatRepository: repository,
                sendConfirmationRequester: sendConfirmationRequester,
                chatDatabasePathOverride: "/synthetic/chat.db"
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
    private(set) var chatSubmissionCount = 0
    private(set) var lastRecipient: String?
    private(set) var lastChatGUID: String?
    private(set) var lastBody: String?
    private(set) var authorizationStatusCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var addressabilityCount = 0
    private(set) var addressabilityGUIDs: [String] = []
    private let error: Error?
    private let authorization: MessagesAutomationAuthorization
    private let authorizationError: Error?
    private var addressability: [Bool]
    private let eventLog: SendEventLog?

    init(
        error: Error? = nil,
        authorization: MessagesAutomationAuthorization = .consentRequired,
        authorizationError: Error? = nil,
        addressability: [Bool] = [],
        eventLog: SendEventLog? = nil
    ) {
        self.error = error
        self.authorization = authorization
        self.authorizationError = authorizationError
        self.addressability = addressability
        self.eventLog = eventLog
    }

    func automationAuthorization() -> MessagesAutomationAuthorization {
        authorizationStatusCount += 1
        eventLog?.record("automation-status")
        return authorization
    }

    func requestAutomationAuthorization() throws {
        authorizationRequestCount += 1
        eventLog?.record("automation-request")
        if let authorizationError { throw authorizationError }
    }

    func isChatAddressable(chatGUID: String) throws -> Bool {
        addressabilityCount += 1
        addressabilityGUIDs.append(chatGUID)
        eventLog?.record("addressability")
        return addressability.isEmpty ? true : addressability.removeFirst()
    }

    func submit(recipient: String, body: String) throws {
        submissionCount += 1
        lastRecipient = recipient
        lastBody = body
        eventLog?.record("raw-submit")
        if let error { throw error }
    }

    func submit(chatGUID: String, body: String) throws {
        chatSubmissionCount += 1
        lastChatGUID = chatGUID
        lastBody = body
        eventLog?.record("chat-submit")
        if let error { throw error }
    }
}

/// Orders events across the confirmation router and the automation adapter so tests
/// can assert sequencing invariants, not just call counts.
private final class SendEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] { lock.withLock { storedEvents } }

    func record(_ event: String) {
        lock.withLock { storedEvents.append(event) }
    }
}

private final class RecordingSendChatRepository: MessagesChatListing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<MessagesResolvedChatDestination, Error>]
    private var storedResolveCount = 0
    private var matches: [MessagesConversationMatch]
    private var storedMatchCount = 0
    var resolveCount: Int { lock.withLock { storedResolveCount } }
    var matchCount: Int { lock.withLock { storedMatchCount } }

    init(
        results: [Result<MessagesResolvedChatDestination, Error>],
        matches: [MessagesConversationMatch] = []
    ) {
        self.results = results
        self.matches = matches
    }

    func listChats(
        databasePath: String,
        limit: Int,
        kind: MessagesChatKind?,
        participants: Set<String>?,
        detail: MessagesChatDetail
    ) throws -> MessagesConversationIndex {
        MessagesConversationIndex(detail: detail, metadataAvailability: [:], chats: [])
    }

    func resolveChatIdentifier(_ identifier: String, databasePath: String) throws -> String {
        try resolveChatDestination(identifier, databasePath: databasePath).chatGuid
    }

    func resolveChatDestination(
        _ identifier: String,
        databasePath: String
    ) throws -> MessagesResolvedChatDestination {
        let result: Result<MessagesResolvedChatDestination, Error>? = lock.withLock {
            storedResolveCount += 1
            return results.isEmpty ? nil : results.removeFirst()
        }
        guard let result else { throw MessagesChatRepositoryError.staleIdentifier }
        return try result.get()
    }

    func matchConversation(
        normalizedParticipants: Set<String>,
        kind: MessagesChatKind,
        databasePath: String
    ) throws -> MessagesConversationMatch {
        lock.withLock {
            storedMatchCount += 1
            return matches.isEmpty ? .none : matches.removeFirst()
        }
    }
}

private final class StubElicitationRequester: ElicitationRequester, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CreateElicitation.Result]
    private let error: Error?
    private var storedRequestCount = 0
    private var storedLastMessage = ""
    private var storedLastTitle: String?
    private let eventLog: SendEventLog?

    let supportsFormElicitation: Bool

    var requestCount: Int { lock.withLock { storedRequestCount } }
    var lastMessage: String { lock.withLock { storedLastMessage } }
    var lastTitle: String? { lock.withLock { storedLastTitle } }

    init(
        result: CreateElicitation.Result,
        supportsForm: Bool = true,
        eventLog: SendEventLog? = nil
    ) {
        self.results = [result]
        self.error = nil
        self.supportsFormElicitation = supportsForm
        self.eventLog = eventLog
    }

    init(results: [CreateElicitation.Result], supportsForm: Bool = true) {
        self.results = results
        self.error = nil
        self.supportsFormElicitation = supportsForm
        self.eventLog = nil
    }

    init(error: Error, supportsForm: Bool = true) {
        self.results = []
        self.error = error
        self.supportsFormElicitation = supportsForm
        self.eventLog = nil
    }

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        let result = lock.withLock {
            storedRequestCount += 1
            storedLastMessage = message
            storedLastTitle = schema.title
            return results.isEmpty ? nil : results.removeFirst()
        }
        eventLog?.record("elicitation")
        if let error { throw error }
        guard let result else { throw MessageSendError.inputMalformed }
        return result
    }
}

private struct SlowElicitationRequester: ElicitationRequester {
    let supportsFormElicitation = true

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        try await Task.sleep(for: .seconds(10))
        return .init(action: .accept, content: ["confirmed": .bool(true)])
    }
}

private enum SyntheticConfirmationError: Error {
    case requestFailed
}

private final class RecordingNativeConfirmationPresenter:
    MessagesNativeSendConfirmationPresenting, @unchecked Sendable
{
    private let lock = NSLock()
    private let outcome: MessagesNativeSendConfirmationOutcome
    private let onRequest: @Sendable () -> Void
    private var storedRequestCount = 0
    private var storedLastPresentation: MessagesSendConfirmationPresentation?

    var requestCount: Int { lock.withLock { storedRequestCount } }
    var lastPresentation: MessagesSendConfirmationPresentation? {
        lock.withLock { storedLastPresentation }
    }

    init(
        outcome: MessagesNativeSendConfirmationOutcome,
        onRequest: @escaping @Sendable () -> Void = {}
    ) {
        self.outcome = outcome
        self.onRequest = onRequest
    }

    @MainActor
    func requestConfirmation(
        _ presentation: MessagesSendConfirmationPresentation
    ) throws -> MessagesNativeSendConfirmationOutcome {
        lock.withLock {
            storedRequestCount += 1
            storedLastPresentation = presentation
        }
        onRequest()
        return outcome
    }
}

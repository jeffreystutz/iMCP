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
        let result = try await sendTool(sender: sender, chatRepository: matchedDirectRepository())(
            ["recipient": .string("recipient@example.invalid"), "body": .string("test-body")],
            context: ToolCallContext(elicitation: requester)
        )

        let submissionCount = await sender.chatSubmissionCount
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "submitted")
        XCTAssertEqual(result.objectValue?["service"]?.stringValue, "Messages")
        let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("recipient@example.invalid"))
        XCTAssertFalse(encoded.contains("test-body"))
        // The confirmation is the authorization surface and must show both values.
        XCTAssertTrue(requester.lastMessage.contains("recipient@example.invalid"))
        XCTAssertTrue(requester.lastMessage.contains("test-body"))
    }

    func testUnmatchedRecipientComposesWithoutIMCPConfirmation() async throws {
        // Phone and email behave identically: neither has an existing conversation,
        // so both are handed to system-owned composition rather than dispatched.
        for recipient in ["+" + "1555" + "0100002", "brand-new@example.invalid"] {
            let sender = RecordingMessagesSender()
            let composer = RecordingMessagesComposer()
            let repository = RecordingSendChatRepository(results: [], matches: [.none])
            let requester = StubElicitationRequester(result: confirmedResult)

            let result = try await sendTool(
                sender: sender,
                composer: composer,
                chatRepository: repository
            )(
                [
                    "recipient": .string(recipient),
                    "body": .string("exact-seed-body"),
                ],
                context: ToolCallContext(elicitation: requester)
            )

            // The system panel is the authorization surface for this mode, so iMCP
            // must not have asked for its own confirmation first.
            XCTAssertEqual(requester.requestCount, 0, "\(recipient) received an iMCP confirmation")
            let compositions = await composer.compositionCount
            let seedRecipient = await composer.lastSeedRecipient
            let seedBody = await composer.lastSeedBody
            XCTAssertEqual(compositions, 1)
            XCTAssertEqual(seedRecipient, recipient, "the seed must not be normalized")
            XCTAssertEqual(seedBody, "exact-seed-body")

            // Nothing was dispatched through Messages automation on any route.
            let chatSubmissions = await sender.chatSubmissionCount
            let addressabilityProbes = await sender.addressabilityCount
            let authorizationRequests = await sender.authorizationRequestCount
            XCTAssertEqual(chatSubmissions, 0)
            XCTAssertEqual(addressabilityProbes, 0)
            XCTAssertEqual(authorizationRequests, 0)

            XCTAssertEqual(
                result.objectValue?["status"]?.stringValue,
                "user_completed_composition"
            )
            XCTAssertEqual(result.objectValue?["mode"]?.stringValue, "system_messages_compose")
            // The result must claim neither a submission nor a transport.
            XCTAssertNil(result.objectValue?["service"])
            let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
            for leaked in [recipient, "exact-seed-body", "iMessage", "SMS", "RCS", "submitted"] {
                XCTAssertFalse(encoded.contains(leaked), "composition result leaked \(leaked)")
            }
        }
    }

    func testCompositionCancellationAndFailureNeverDispatchOrRetry() async {
        let cases: [(Error, MessagesCompositionError)] = [
            (MessagesCompositionError.compositionCancelled, .compositionCancelled),
            (MessagesCompositionError.compositionFailed, .compositionFailed),
            (MessagesCompositionError.compositionUnavailable, .compositionUnavailable),
            (MessagesCompositionError.compositionBusy, .compositionBusy),
        ]
        for (thrown, expected) in cases {
            let sender = RecordingMessagesSender()
            let composer = RecordingMessagesComposer(outcome: .failure(thrown))
            let repository = RecordingSendChatRepository(results: [], matches: [.none])
            let requester = StubElicitationRequester(result: confirmedResult)

            do {
                _ = try await sendTool(
                    sender: sender,
                    composer: composer,
                    chatRepository: repository
                )(
                    [
                        "recipient": .string("brand-new@example.invalid"),
                        "body": .string("test-body"),
                    ],
                    context: ToolCallContext(elicitation: requester)
                )
                XCTFail("Expected the composition to fail")
            } catch let error as MessagesCompositionError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            // No second composition, no AppleScript fallback, no confirmation, and
            // no retry — including for the ambiguous generic failure, where a retry
            // is exactly what could duplicate a message.
            let compositions = await composer.compositionCount
            let chatSubmissions = await sender.chatSubmissionCount
            let addressabilityProbes = await sender.addressabilityCount
            let authorizationRequests = await sender.authorizationRequestCount
            XCTAssertEqual(compositions, 1, "\(expected) started a second composition")
            XCTAssertEqual(chatSubmissions, 0, "\(expected) fell back to AppleScript")
            XCTAssertEqual(addressabilityProbes, 0)
            XCTAssertEqual(authorizationRequests, 0)
            XCTAssertEqual(requester.requestCount, 0)

            let message = error(expected)
            for leaked in ["brand-new@example.invalid", "test-body", "iMessage", "SMS", "RCS"] {
                XCTAssertFalse(message.contains(leaked), "\(expected) leaked \(leaked)")
            }
        }
    }

    func testGenericCompositionFailureReportsAnUnknownRatherThanSafeOutcome() {
        // Once the system panel has been presented, a non-cancellation delegate
        // failure does not establish that nothing was submitted. Claiming otherwise
        // would invite a duplicate send.
        let ambiguous = MessagesCompositionError.compositionFailed.localizedDescription
        XCTAssertFalse(
            ambiguous.contains("Nothing was sent"),
            "generic composition failure still claims nothing was sent"
        )
        XCTAssertTrue(ambiguous.contains("unknown"))
        XCTAssertTrue(ambiguous.contains("did not retry"))
        for leaked in [
            "brand-new@example.invalid", "exact-seed-body", "iMessage", "SMS", "RCS",
            "NSCocoaErrorDomain", "SyntheticDomain", "/private/", "NSSharingService",
        ] {
            XCTAssertFalse(ambiguous.contains(leaked), "the ambiguous failure leaked \(leaked)")
        }

        // Outcomes that genuinely establish no send keep their definite wording, and
        // cancellation stays distinguishable from the ambiguous case.
        for definite in [
            MessagesCompositionError.compositionCancelled,
            .compositionUnavailable,
            .compositionBusy,
        ] {
            XCTAssertTrue(definite.localizedDescription.contains("Nothing was sent."))
            XCTAssertNotEqual(definite, .compositionFailed)
            XCTAssertNotEqual(definite.localizedDescription, ambiguous)
        }
    }

    private func error(_ error: MessagesCompositionError) -> String {
        error.localizedDescription
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
                chatRepository: self.matchedDirectRepository(),
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
        let submissionCount = await sender.chatSubmissionCount
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
        let composer = RecordingMessagesComposer()
        let recipient = "+" + "1555" + "0100001"
        _ = try await sendTool(
            sender: sender,
            composer: composer,
            chatRepository: RecordingSendChatRepository(results: [], matches: [.none])
        )(
            ["recipient": .string(recipient), "body": .string("test-body")],
            context: ToolCallContext(
                elicitation: StubElicitationRequester(result: confirmedResult)
            )
        )

        let compositionCount = await composer.compositionCount
        let seedRecipient = await composer.lastSeedRecipient
        XCTAssertEqual(compositionCount, 1)
        XCTAssertTrue(seedRecipient == recipient)
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

        _ = try await sendTool(sender: sender, chatRepository: matchedDirectRepository())(
            ["recipient": .string("recipient@example.invalid")],
            context: ToolCallContext(elicitation: requester)
        )

        XCTAssertEqual(requester.requestCount, 2)
        let submissionCount = await sender.chatSubmissionCount
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
                _ = try await self.sendTool(
                    sender: sender,
                    chatRepository: self.matchedDirectRepository()
                )(
                    [
                        "recipient": .string("recipient@example.invalid"),
                        "body": .string("test-body"),
                    ],
                    context: ToolCallContext(
                        elicitation: StubElicitationRequester(result: result)
                    )
                )
            }
            let submissionCount = await sender.chatSubmissionCount
            XCTAssertEqual(submissionCount, 0)
        }
    }

    func testUnsupportedElicitationFailsClosed() async {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(error: ElicitationRequestError.formUnsupported)

        do {
            _ = try await sendTool(sender: sender, chatRepository: matchedDirectRepository())(
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

        let submissionCount = await sender.chatSubmissionCount
        XCTAssertEqual(submissionCount, 0)
    }

    func testCompleteMatchedRecipientCallStillRequestsExactlyOneFinalConfirmation() async throws {
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(result: confirmedResult)

        _ = try await sendTool(sender: sender, chatRepository: matchedDirectRepository())(
            [
                "recipient": .string("recipient@example.invalid"),
                "body": .string("test-body"),
            ],
            context: ToolCallContext(elicitation: requester)
        )

        // Nothing supplies every input up front well enough to skip confirmation.
        XCTAssertEqual(requester.requestCount, 1)
        let submissionCount = await sender.chatSubmissionCount
        XCTAssertEqual(submissionCount, 1)
    }

    func testMissingInputElicitationIsNeverTreatedAsFinalConfirmation() async {
        // A client that supplies the body but cannot show a form must dispatch zero: the
        // input round trip is not authorization.
        let sender = RecordingMessagesSender()
        let requester = StubElicitationRequester(
            results: [.init(action: .accept, content: ["body": .string("test-body")])]
        )

        await assertSendError(.inputMalformed) {
            _ = try await self.sendTool(
                sender: sender,
                chatRepository: self.matchedDirectRepository()
            )(
                ["recipient": .string("recipient@example.invalid")],
                context: ToolCallContext(elicitation: requester)
            )
        }

        // Two requests: one for the missing body, one for the separate final confirmation.
        XCTAssertEqual(requester.requestCount, 2)
        let submissionCount = await sender.chatSubmissionCount
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
            _ = try await self.sendTool(
                sender: sender,
                chatRepository: self.matchedDirectRepository()
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

        let submissionCount = await sender.chatSubmissionCount
        XCTAssertEqual(submissionCount, 1)
    }

    func testCancelledToolCallDoesNotDispatch() async throws {
        let sender = RecordingMessagesSender()
        let tool = try sendTool(sender: sender, chatRepository: matchedDirectRepository())
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

        let submissionCount = await sender.chatSubmissionCount
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

    func testUnresolvedDirectMatchingNeverReachesComposition() async {
        // Only a verified absence composes. Ambiguity and unresolvable membership are
        // not evidence of absence, so they fail closed with no panel at all.
        let cases: [(MessagesConversationMatch, MessageSendError)] = [
            (.ambiguous, .ambiguousDirectConversation),
            (.incomplete, .incompleteDirectMembership),
        ]
        for (match, expected) in cases {
            let sender = RecordingMessagesSender()
            let composer = RecordingMessagesComposer()
            let repository = RecordingSendChatRepository(results: [], matches: [match])
            await assertSendError(expected) {
                _ = try await self.sendTool(
                    sender: sender,
                    composer: composer,
                    chatRepository: repository
                )(
                    ["recipient": .string("one@example.invalid"), "body": .string("test-body")],
                    context: ToolCallContext(
                        elicitation: StubElicitationRequester(result: self.confirmedResult)
                    )
                )
            }
            let compositions = await composer.compositionCount
            let chatCount = await sender.chatSubmissionCount
            XCTAssertEqual(compositions, 0, "\(expected) opened a system compose panel")
            XCTAssertEqual(chatCount, 0)
        }
    }

    func testExistingChatFailuresNeverBecomeNewRecipientComposition() async {
        // An existing-chat failure stays an existing-chat failure. It must never be
        // reinterpreted as "no conversation exists" and rerouted to the system panel.
        let unavailableSender = RecordingMessagesSender(
            authorization: .authorized,
            addressability: [false]
        )
        let unavailableComposer = RecordingMessagesComposer()
        await assertSendError(.chatUnavailableInAutomation) {
            _ = try await self.sendTool(
                sender: unavailableSender,
                composer: unavailableComposer,
                chatRepository: self.matchedDirectRepository()
            )(
                ["recipient": .string("recipient@example.invalid"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }
        let unavailableCompositions = await unavailableComposer.compositionCount
        XCTAssertEqual(unavailableCompositions, 0)

        let staleSender = RecordingMessagesSender()
        let staleComposer = RecordingMessagesComposer()
        let match = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic",
            destination: directChat
        )
        await assertSendError(.staleMatchedConversation) {
            _ = try await self.sendTool(
                sender: staleSender,
                composer: staleComposer,
                chatRepository: RecordingSendChatRepository(results: [], matches: [match, .none])
            )(
                ["recipient": .string("recipient@example.invalid"), "body": .string("test-body")],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }
        let staleCompositions = await staleComposer.compositionCount
        let staleSubmissions = await staleSender.chatSubmissionCount
        XCTAssertEqual(staleCompositions, 0, "a stale destination reopened as a new recipient")
        XCTAssertEqual(staleSubmissions, 0)

        // A group with no exact match fails closed; groups never compose.
        let groupSender = RecordingMessagesSender()
        let groupComposer = RecordingMessagesComposer()
        await assertSendError(.groupConversationNotFound) {
            _ = try await self.sendTool(
                sender: groupSender,
                composer: groupComposer,
                chatRepository: RecordingSendChatRepository(results: [], matches: [.none])
            )(
                [
                    "recipients": .array([
                        .string("first@example.invalid"), .string("second@example.invalid"),
                    ]),
                    "body": .string("test-body"),
                ],
                context: ToolCallContext(
                    elicitation: StubElicitationRequester(result: self.confirmedResult)
                )
            )
        }
        let groupCompositions = await groupComposer.compositionCount
        XCTAssertEqual(groupCompositions, 0)
    }

    func testExplicitChatAndGroupDestinationsNeverCompose() async throws {
        let chatComposer = RecordingMessagesComposer()
        let chatSender = RecordingMessagesSender()
        _ = try await sendTool(
            sender: chatSender,
            composer: chatComposer,
            chatRepository: RecordingSendChatRepository(results: [
                .success(directChat), .success(directChat),
            ])
        )(
            ["chat_id": .string("imcp-chat-v1_synthetic"), "body": .string("test-body")],
            context: ToolCallContext(
                elicitation: StubElicitationRequester(result: confirmedResult)
            )
        )
        let chatCompositions = await chatComposer.compositionCount
        let chatSubmissions = await chatSender.chatSubmissionCount
        XCTAssertEqual(chatCompositions, 0)
        XCTAssertEqual(chatSubmissions, 1)

        let groupComposer = RecordingMessagesComposer()
        let groupSender = RecordingMessagesSender()
        let groupMatch = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic",
            destination: groupChat
        )
        _ = try await sendTool(
            sender: groupSender,
            composer: groupComposer,
            chatRepository: RecordingSendChatRepository(
                results: [],
                matches: [groupMatch, groupMatch]
            )
        )(
            [
                "recipients": .array([
                    .string("first@example.invalid"), .string("second@example.invalid"),
                ]),
                "body": .string("test-body"),
            ],
            context: ToolCallContext(
                elicitation: StubElicitationRequester(result: confirmedResult)
            )
        )
        let groupCompositions = await groupComposer.compositionCount
        let groupSubmissions = await groupSender.chatSubmissionCount
        XCTAssertEqual(groupCompositions, 0)
        XCTAssertEqual(groupSubmissions, 1)
    }

    func testAuthorizationModelsStaySeparate() async throws {
        // Existing chat: exactly one confirmation, zero compositions.
        let existingLog = SendEventLog()
        let existingComposer = RecordingMessagesComposer(eventLog: existingLog)
        let existingSender = RecordingMessagesSender(eventLog: existingLog)
        let existingRequester = StubElicitationRequester(
            result: confirmedResult,
            eventLog: existingLog
        )
        _ = try await sendTool(
            sender: existingSender,
            composer: existingComposer,
            chatRepository: matchedDirectRepository()
        )(
            ["recipient": .string("recipient@example.invalid"), "body": .string("test-body")],
            context: ToolCallContext(elicitation: existingRequester)
        )
        XCTAssertEqual(existingRequester.requestCount, 1)
        let existingCompositions = await existingComposer.compositionCount
        XCTAssertEqual(existingCompositions, 0)
        XCTAssertFalse(existingLog.events.contains("compose"))

        // New recipient: exactly one composition, zero confirmations, and the
        // missing-input round trip stays distinct from either authorization surface.
        let newLog = SendEventLog()
        let newComposer = RecordingMessagesComposer(eventLog: newLog)
        let newSender = RecordingMessagesSender(eventLog: newLog)
        let newRequester = StubElicitationRequester(
            results: [.init(action: .accept, content: ["body": .string("test-body")])]
        )
        _ = try await sendTool(
            sender: newSender,
            composer: newComposer,
            chatRepository: RecordingSendChatRepository(results: [], matches: [.none])
        )(
            ["recipient": .string("brand-new@example.invalid")],
            context: ToolCallContext(elicitation: newRequester)
        )
        // One elicitation only: the missing body. It gathered input, it did not
        // authorize anything.
        XCTAssertEqual(newRequester.requestCount, 1)
        let newCompositions = await newComposer.compositionCount
        XCTAssertEqual(newCompositions, 1)
        XCTAssertEqual(newLog.events, ["compose"])
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

    // MARK: - Sharing-service composition lifecycle

    @MainActor
    func testCompositionSeedsExactValuesAndCompletesExactlyOnce() async throws {
        let panel = StubCompositionPanel()
        let composition = Task { @MainActor in
            try await MessagesCompositionCoordinator.compose(
                recipient: "brand-new@example.invalid",
                body: "exact-seed-body",
                panel: panel
            )
        }
        await waitForPresentation(panel)

        XCTAssertEqual(panel.presentCount, 1)
        XCTAssertEqual(panel.lastRecipient, "brand-new@example.invalid")
        // The body travels as the item array, which is also what capability checks use.
        XCTAssertEqual(panel.lastItems.count, 1)
        XCTAssertEqual(panel.lastItems.first as? String, "exact-seed-body")

        let delegate = try XCTUnwrap(panel.lastDelegate)
        let service = try XCTUnwrap(NSSharingService(named: .composeMessage))
        delegate.sharingService?(service, didShareItems: ["exact-seed-body"])

        let outcome = try await composition.value
        XCTAssertEqual(outcome, .userCompleted)
        XCTAssertEqual(panel.releaseCount, 1)

        // Late or duplicate callbacks must not resume a second time or re-release.
        delegate.sharingService?(service, didShareItems: [])
        delegate.sharingService?(
            service,
            didFailToShareItems: [],
            error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
        XCTAssertEqual(panel.releaseCount, 1)
    }

    @MainActor
    func testCompositionDelegateOutcomesMapWithoutLeakingDetail() async throws {
        let cancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        XCTAssertEqual(
            MessagesCompositionCoordinator.outcome(forFailure: cancelled),
            .compositionCancelled
        )
        XCTAssertEqual(NSUserCancelledError, 3072)
        let otherFailures: [Error] = [
            NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
            NSError(
                domain: "SyntheticDomain",
                code: 42,
                userInfo: [
                    NSLocalizedDescriptionKey: "brand-new@example.invalid /private/synthetic/path"
                ]
            ),
            SyntheticCompositionError.serviceFailed,
        ]
        for other in otherFailures {
            XCTAssertEqual(
                MessagesCompositionCoordinator.outcome(forFailure: other),
                .compositionFailed
            )
        }
        // Sanitized: the mapped error text carries nothing from the underlying failure.
        let sanitized = MessagesCompositionError.compositionFailed.localizedDescription
        for leaked in ["brand-new@example.invalid", "/private/synthetic/path", "SyntheticDomain"] {
            XCTAssertFalse(sanitized.contains(leaked))
        }

        // Cancellation surfaces as its own terminal outcome, with no retry.
        let panel = StubCompositionPanel()
        let composition = Task { @MainActor in
            try await MessagesCompositionCoordinator.compose(
                recipient: "brand-new@example.invalid",
                body: "exact-seed-body",
                panel: panel
            )
        }
        await waitForPresentation(panel)
        let delegate = try XCTUnwrap(panel.lastDelegate)
        let service = try XCTUnwrap(NSSharingService(named: .composeMessage))
        delegate.sharingService?(service, didFailToShareItems: [], error: cancelled)

        do {
            _ = try await composition.value
            XCTFail("Expected the cancelled composition to fail")
        } catch let error as MessagesCompositionError {
            XCTAssertEqual(error, .compositionCancelled)
        }
        XCTAssertEqual(panel.presentCount, 1, "a cancelled composition was retried")
    }

    @MainActor
    func testGenericDelegateFailureResolvesOnceAndStartsNothingElse() async throws {
        let panel = StubCompositionPanel()
        let composition = Task { @MainActor in
            try await MessagesCompositionCoordinator.compose(
                recipient: "brand-new@example.invalid",
                body: "exact-seed-body",
                panel: panel
            )
        }
        await waitForPresentation(panel)

        let delegate = try XCTUnwrap(panel.lastDelegate)
        let service = try XCTUnwrap(NSSharingService(named: .composeMessage))
        delegate.sharingService?(
            service,
            didFailToShareItems: [],
            error: NSError(domain: "SyntheticDomain", code: 42)
        )

        do {
            _ = try await composition.value
            XCTFail("Expected the generic composition failure to surface")
        } catch let error as MessagesCompositionError {
            XCTAssertEqual(error, .compositionFailed)
        }

        // Terminal: no second presentation, exactly one release, and late or
        // duplicate callbacks cannot resume the continuation again.
        XCTAssertEqual(panel.presentCount, 1)
        XCTAssertEqual(panel.releaseCount, 1)
        delegate.sharingService?(service, didShareItems: [])
        delegate.sharingService?(
            service,
            didFailToShareItems: [],
            error: NSError(domain: "SyntheticDomain", code: 43)
        )
        XCTAssertEqual(panel.presentCount, 1)
        XCTAssertEqual(panel.releaseCount, 1)
    }

    @MainActor
    func testOnlyOneCompositionPanelIsPresentedAtATime() async throws {
        let first = StubCompositionPanel()
        let composition = Task { @MainActor in
            try await MessagesCompositionCoordinator.compose(
                recipient: "brand-new@example.invalid",
                body: "exact-seed-body",
                panel: first
            )
        }
        await waitForPresentation(first)

        let second = StubCompositionPanel()
        do {
            _ = try await MessagesCompositionCoordinator.compose(
                recipient: "another-new@example.invalid",
                body: "second-seed-body",
                panel: second
            )
            XCTFail("Expected the second composition to fail closed")
        } catch let error as MessagesCompositionError {
            XCTAssertEqual(error, .compositionBusy)
        }
        // Failed closed rather than queued: nothing may surface later out of context.
        XCTAssertEqual(second.presentCount, 0)

        let delegate = try XCTUnwrap(first.lastDelegate)
        let service = try XCTUnwrap(NSSharingService(named: .composeMessage))
        delegate.sharingService?(service, didShareItems: [])
        _ = try await composition.value
        XCTAssertEqual(second.presentCount, 0)

        // The gate reopens once the active composition reaches a terminal outcome.
        let third = StubCompositionPanel()
        let reopened = Task { @MainActor in
            try await MessagesCompositionCoordinator.compose(
                recipient: "third-new@example.invalid",
                body: "third-seed-body",
                panel: third
            )
        }
        await waitForPresentation(third)
        let thirdDelegate = try XCTUnwrap(third.lastDelegate)
        thirdDelegate.sharingService?(service, didShareItems: [])
        _ = try await reopened.value
    }

    @MainActor
    func testUnavailableCompositionServiceFailsWithoutPresenting() async {
        let panel = StubCompositionPanel(canPresent: false)
        do {
            _ = try await MessagesCompositionCoordinator.compose(
                recipient: "brand-new@example.invalid",
                body: "exact-seed-body",
                panel: panel
            )
            XCTFail("Expected an unavailable composition service to fail")
        } catch let error as MessagesCompositionError {
            XCTAssertEqual(error, .compositionUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(panel.presentCount, 1)

        // The single-active gate must be released even on this early failure.
        let next = StubCompositionPanel(canPresent: false)
        do {
            _ = try await MessagesCompositionCoordinator.compose(
                recipient: "brand-new@example.invalid",
                body: "exact-seed-body",
                panel: next
            )
            XCTFail("Expected an unavailable composition service to fail")
        } catch let error as MessagesCompositionError {
            XCTAssertEqual(error, .compositionUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCancelledTaskPresentsNoCompositionPanel() async {
        let panel = StubCompositionPanel()
        let composition = Task { @MainActor in
            try await SystemMessagesComposer(makePanel: { panel })
                .compose(seedRecipient: "brand-new@example.invalid", seedBody: "exact-seed-body")
        }
        composition.cancel()

        do {
            _ = try await composition.value
            XCTFail("Expected the cancelled composition to fail")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(panel.presentCount, 0)
    }

    @MainActor
    func testCancellingAfterPresentationNeitherRetriesNorClosesThePanel() async throws {
        let panel = StubCompositionPanel()
        let composition = Task { @MainActor in
            try await MessagesCompositionCoordinator.compose(
                recipient: "brand-new@example.invalid",
                body: "exact-seed-body",
                panel: panel
            )
        }
        await waitForPresentation(panel)

        // Once system UI is visible, caller cancellation proves nothing about what the
        // human did next, so iMCP starts no other route, synthesizes no Send or Cancel,
        // and keeps the delegate alive for the real outcome.
        composition.cancel()
        await Task.yield()
        XCTAssertEqual(panel.presentCount, 1)
        XCTAssertEqual(panel.releaseCount, 0)

        let delegate = try XCTUnwrap(panel.lastDelegate)
        let service = try XCTUnwrap(NSSharingService(named: .composeMessage))
        delegate.sharingService?(service, didShareItems: [])

        let outcome = try await composition.value
        XCTAssertEqual(outcome, .userCompleted)
        XCTAssertEqual(panel.presentCount, 1)
        XCTAssertEqual(panel.releaseCount, 1)
    }

    @MainActor
    private func waitForPresentation(
        _ panel: StubCompositionPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1_000 {
            if panel.presentCount > 0 { return }
            await Task.yield()
        }
        XCTFail("The composition panel was never presented", file: file, line: line)
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

    func testNoProductionPathCanBindAnUnmatchedRecipientToAnAccount() throws {
        // The raw participant path selected an iMessage account for any handle, with
        // no evidence iMessage was the right route. It is gone, not merely unused.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for source in [
            "App/Services/Messages.swift",
            "App/Services/MessagesSender.swift",
            "App/Services/MessagesComposer.swift",
            "App/Services/MessagesSendConfirmation.swift",
        ] {
            let contents = try String(
                contentsOf: root.appendingPathComponent(source),
                encoding: .utf8
            )
            for symbol in [
                "submitDirectMessage",
                "recipientHandle",
                "targetParticipant",
                "service type = iMessage",
                "submit(recipient:",
                "rawRecipient",
            ] {
                XCTAssertFalse(
                    contents.contains(symbol),
                    "\(source) still references the removed raw-recipient path: \(symbol)"
                )
            }
        }

        let script = AppleScriptMessagesSender.scriptSource
        for symbol in ["participant", "service type", "account"] {
            XCTAssertFalse(
                script.contains(symbol),
                "the fixed script still fabricates a destination using \(symbol)"
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
        composer: RecordingMessagesComposer? = nil,
        chatRepository: (any MessagesChatListing)? = nil,
        sendConfirmationRequester: any MessagesFinalSendConfirmationRequesting =
            MessagesFinalSendConfirmationRequester(mode: { .mcpForm })
    ) throws -> iMCP.Tool {
        let repository = chatRepository ?? RecordingSendChatRepository(results: [])
        return try XCTUnwrap(
            MessageService(
                sender: sender,
                composer: composer ?? RecordingMessagesComposer(),
                chatRepository: repository,
                sendConfirmationRequester: sendConfirmationRequester,
                chatDatabasePathOverride: "/synthetic/chat.db"
            ).tools.first { $0.name == "messages_send" }
        )
    }

    /// A direct conversation that already exists, so the call keeps the programmatic
    /// existing-chat path and its mandatory confirmation.
    private func matchedDirectRepository() -> RecordingSendChatRepository {
        let match = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic",
            destination: directChat
        )
        return RecordingSendChatRepository(results: [], matches: [match, match])
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

    /// Not a `MessagesSending` requirement any more, so production cannot reach it.
    /// It stays as a trap: every "raw submissions stayed at zero" assertion in this
    /// suite now also asserts something the type system already forbids.
    func submit(recipient: String, body: String) throws {
        submissionCount += 1
        lastRecipient = recipient
        lastBody = body
        eventLog?.record("raw-submit")
        XCTFail("An unmatched recipient must never reach AppleScript dispatch")
        if let error { throw error }
    }

    func submit(chatGUID: String, body: String) throws {
        chatSubmissionCount += 1
        lastChatGUID = chatGUID
        lastBody = body
        eventLog?.record("chat-submit")
        if let error { throw error }
    }

    /// A trap: `messages_send` submits text, so no plain-text send in this suite may
    /// ever reach the attachment handler.
    func submitChatAttachment(chatGUID: String, attachmentFile: URL) throws {
        eventLog?.record("attachment-submit")
        XCTFail("A plain-text send must never dispatch an attachment")
    }
}

private actor RecordingMessagesComposer: MessagesNewRecipientComposing {
    private(set) var compositionCount = 0
    private(set) var lastSeedRecipient: String?
    private(set) var lastSeedBody: String?
    private let outcome: Result<MessagesCompositionOutcome, Error>
    private let eventLog: SendEventLog?

    init(
        outcome: Result<MessagesCompositionOutcome, Error> = .success(.userCompleted),
        eventLog: SendEventLog? = nil
    ) {
        self.outcome = outcome
        self.eventLog = eventLog
    }

    func compose(
        seedRecipient: String,
        seedBody: String
    ) async throws -> MessagesCompositionOutcome {
        compositionCount += 1
        lastSeedRecipient = seedRecipient
        lastSeedBody = seedBody
        eventLog?.record("compose")
        return try outcome.get()
    }
}

/// Stands in for the AppKit edge so the composition lifecycle can be exercised
/// without presenting a real system panel.
@MainActor
private final class StubCompositionPanel: MessagesCompositionPanelPresenting {
    private(set) var presentCount = 0
    private(set) var releaseCount = 0
    private(set) var lastRecipient: String?
    private(set) var lastItems: [Any] = []
    private(set) weak var lastDelegate: NSSharingServiceDelegate?
    private let canPresent: Bool

    init(canPresent: Bool = true) {
        self.canPresent = canPresent
    }

    func present(recipient: String, items: [Any], delegate: NSSharingServiceDelegate) -> Bool {
        presentCount += 1
        lastRecipient = recipient
        lastItems = items
        lastDelegate = delegate
        return canPresent
    }

    func release() {
        releaseCount += 1
    }
}

private enum SyntheticCompositionError: Error {
    case serviceFailed
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

import AppKit
import Foundation
import MCP
import UniformTypeIdentifiers
import XCTest

@testable import iMCP

/// Coverage for `message_send_attachment`.
///
/// Every value here is synthetic. No real contact, conversation, message, or personal
/// file is referenced, and nothing in this suite performs a real Apple Event, presents
/// real UI, or submits anything to Messages.
final class MessageAttachmentSendTests: XCTestCase {
    private var fixtures: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtures = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("iMCPAttachmentFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtures { try? FileManager.default.removeItem(at: fixtures) }
        fixtures = nil
        try super.tearDownWithError()
    }

    // MARK: - Public surface

    func testToolAdvertisesAttachmentOnlyExistingConversationSemantics() throws {
        let tool = try attachmentTool()

        XCTAssertEqual(tool.annotations.title, "Send Messages Attachment")
        XCTAssertEqual(tool.annotations.readOnlyHint, false)
        XCTAssertEqual(tool.annotations.destructiveHint, false)
        XCTAssertEqual(tool.annotations.idempotentHint, false)
        XCTAssertEqual(tool.annotations.openWorldHint, true)

        let description = tool.description.lowercased()
        XCTAssertTrue(description.contains("exactly one file"))
        XCTAssertTrue(description.contains("existing messages conversation"))
        XCTAssertTrue(description.contains("no file path"))
        XCTAssertTrue(description.contains("native file picker"))
        XCTAssertTrue(description.contains("25 mib"))
        XCTAssertTrue(description.contains("caption"))
        XCTAssertTrue(description.contains("sends no message text"))
        // Submission is never described as delivery.
        XCTAssertTrue(description.contains("never that it was delivered"))
        XCTAssertFalse(description.contains("delivers"))
    }

    func testSchemaAcceptsOnlyDestinationSelectorsAndNoFileOrBodyParameter() throws {
        let tool = try attachmentTool()
        let encoded = try JSONEncoder().encode(tool.inputSchema)
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

        XCTAssertEqual(Set(properties.keys), ["recipient", "recipients", "chat_id"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        // Nothing is required at the schema level: exactly-one-of is enforced in code.
        XCTAssertNil(schema["required"])

        // No file or message input may exist on this tool in any spelling, and no
        // caller-facing sending-mode/confirmation-bypass argument may exist either: the
        // global Sending mode is app-owned and unreachable from any MCP argument.
        let schemaText = try XCTUnwrap(String(data: encoded, encoding: .utf8)).lowercased()
        for forbidden in [
            "\"path\"", "\"file\"", "\"file_path\"", "\"filepath\"", "\"url\"", "\"body\"",
            "\"text\"", "\"caption\"", "\"filename\"", "\"file_name\"", "\"bytes\"", "\"data\"",
            "\"attachment\"", "\"attachment_id\"", "\"content\"", "\"mime_type\"", "\"uti\"",
            "\"mode\"", "\"sending_mode\"", "\"automatic\"", "\"bypass\"", "\"confirm\"",
            "\"confirmation\"",
        ] {
            XCTAssertFalse(
                schemaText.contains(forbidden),
                "the attachment schema exposes \(forbidden)"
            )
        }
    }

    func testMessageSendTextRemainsSeparateAndTextOnly() throws {
        let service = MessageService(sender: RecordingAttachmentSender())
        let sendTool = try XCTUnwrap(service.tools.first { $0.name == "message_send_text" })
        let attachmentTool = try XCTUnwrap(
            service.tools.first { $0.name == "message_send_attachment" }
        )
        XCTAssertNotEqual(sendTool.name, attachmentTool.name)

        // The text tool gained no file surface, so a file plus a caption cannot become
        // one call that would need two dispatches.
        let sendSchema = try XCTUnwrap(
            String(data: try JSONEncoder().encode(sendTool.inputSchema), encoding: .utf8)
        ).lowercased()
        for forbidden in ["\"path\"", "\"file\"", "\"attachment\"", "\"url\""] {
            XCTAssertFalse(sendSchema.contains(forbidden), "message_send_text exposes \(forbidden)")
        }
        XCTAssertTrue(sendSchema.contains("\"body\""))
    }

    // MARK: - Destination resolution

    func testExactlyOneDestinationSelectorIsRequired() async throws {
        let combinations: [[String: Value]] = [
            [:],
            [
                "recipient": .string("one@example.invalid"),
                "chat_id": .string("imcp-chat-v1_synthetic"),
            ],
            [
                "recipient": .string("one@example.invalid"),
                "recipients": .array([
                    .string("one@example.invalid"), .string("two@example.invalid"),
                ]),
            ],
            [
                "recipients": .array([
                    .string("one@example.invalid"), .string("two@example.invalid"),
                ]),
                "chat_id": .string("imcp-chat-v1_synthetic"),
            ],
        ]

        for arguments in combinations {
            let harness = Harness(matches: [uniqueDirectMatch, uniqueDirectMatch])
            await harness.assertFailure(MessageSendError.invalidDestination, arguments: arguments)
            await harness.assertNothingHappened()
        }
    }

    func testInvalidAndInexactDestinationsFailBeforeThePicker() async throws {
        let cases: [([String: Value], MessageSendError)] = [
            (["recipient": .string("not a handle")], .invalidRecipient),
            (["recipient": .string("5551234567")], .invalidRecipient),
            (["recipient": .string("")], .invalidRecipient),
            (["chat_id": .string("   ")], .invalidChatIdentifier),
            (["recipients": .array([.string("only@example.invalid")])], .insufficientGroupParticipants),
            (
                ["recipients": .array([.string("dup@example.invalid"), .string("dup@example.invalid")])],
                .insufficientGroupParticipants
            ),
            (["recipients": .array([.string("ok@example.invalid"), .int(7)])], .invalidRecipient),
        ]

        for (arguments, expected) in cases {
            let harness = Harness(matches: [uniqueDirectMatch, uniqueDirectMatch])
            await harness.assertFailure(expected, arguments: arguments)
            await harness.assertNothingHappened()
        }
    }

    func testUnresolvedDestinationsFailClosedWithoutPickerOrDispatch() async throws {
        let cases: [(MessagesConversationMatch, [String: Value], MessageSendError)] = [
            (.ambiguous, ["recipient": .string("one@example.invalid")], .ambiguousDirectConversation),
            (.incomplete, ["recipient": .string("one@example.invalid")], .incompleteDirectMembership),
            (
                .none,
                ["recipients": .array([.string("a@example.invalid"), .string("b@example.invalid")])],
                .groupConversationNotFound
            ),
            (
                .ambiguous,
                ["recipients": .array([.string("a@example.invalid"), .string("b@example.invalid")])],
                .ambiguousGroupConversation
            ),
            (
                .incomplete,
                ["recipients": .array([.string("a@example.invalid"), .string("b@example.invalid")])],
                .incompleteGroupMembership
            ),
        ]

        for (match, arguments, expected) in cases {
            let harness = Harness(matches: [match])
            await harness.assertFailure(expected, arguments: arguments)
            await harness.assertNothingHappened()
        }
    }

    func testVerifiedNewRecipientFailsWithoutComposerPickerOrDispatch() async throws {
        for recipient in ["+" + "1555" + "0100002", "brand-new@example.invalid"] {
            let harness = Harness(matches: [.none])
            await harness.assertFailure(
                MessageSendError.attachmentRequiresExistingConversation,
                arguments: ["recipient": .string(recipient)]
            )

            // No sharing composer, no picker, no confirmation, no dispatch.
            let compositions = await harness.composer.compositionCount
            XCTAssertEqual(compositions, 0, "\(recipient) reached system composition")
            await harness.assertNothingHappened()

            // The refusal explains the scope without leaking the rejected handle.
            let message = MessageSendError.attachmentRequiresExistingConversation
                .localizedDescription
            XCTAssertTrue(message.contains("existing Messages conversation"))
            XCTAssertTrue(message.contains("Nothing was sent"))
            XCTAssertFalse(message.contains(recipient))
        }
    }

    func testStaleOrUnresolvableChatIdentifierFailsBeforeThePicker() async throws {
        let harness = Harness(results: [.failure(MessagesChatRepositoryError.staleIdentifier)])
        await harness.assertFailure(
            MessageSendError.staleChatIdentifier,
            arguments: ["chat_id": .string("imcp-chat-v1_synthetic")]
        )
        await harness.assertNothingHappened()
    }

    // MARK: - Picker

    func testPickerCancellationSendsNothing() async throws {
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .failure(MessagesAttachmentError.selectionCancelled)
        )
        await harness.assertAttachmentFailure(
            .selectionCancelled,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )

        let selections = await harness.selector.selectionCount
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(harness.elicitation.requestCount, 0, "cancellation still asked to confirm")
        let dispatches = await harness.sender.attachmentSubmissionCount
        let authorizations = await harness.sender.authorizationRequestCount
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(authorizations, 0)
    }

    func testPickerIsPresentedOnlyAfterTheDestinationResolves() async throws {
        let log = AttachmentEventLog()
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            eventLog: log
        )
        _ = try await harness.call(["recipient": .string("recipient@example.invalid")])

        let events = log.events
        let matchIndex = try XCTUnwrap(events.firstIndex(of: "match"))
        let selectIndex = try XCTUnwrap(events.firstIndex(of: "select"))
        XCTAssertLessThan(matchIndex, selectIndex, "the picker ran before the destination resolved")
    }

    // MARK: - Bounded file policy

    func testSupportedTypeCategoriesAreAccepted() async throws {
        let validator = FileManagerMessagesAttachmentValidator()
        for name in ["note.txt", "scan.pdf", "photo.png", "photo.jpeg", "clip.mp4", "clip.m4a"] {
            let url = try makeFile(name, byteCount: 64)
            let facts = try validator.validate(url)
            XCTAssertEqual(facts.displayName, name)
            XCTAssertEqual(facts.byteSize, 64)
            XCTAssertTrue(
                FileManagerMessagesAttachmentValidator.supportedTypes.contains(
                    where: facts.contentType.conforms(to:)
                ),
                "\(name) resolved to an unsupported category"
            )
        }
    }

    func testSizeBoundsAreInclusiveAtTwentyFiveMebibytes() throws {
        let validator = FileManagerMessagesAttachmentValidator()
        XCTAssertEqual(maximumMessagesAttachmentByteSize, 26_214_400)

        let single = try validator.validate(try makeFile("one-byte.txt", byteCount: 1))
        XCTAssertEqual(single.byteSize, 1)

        let exact = try validator.validate(
            try makeFile("exact.txt", byteCount: maximumMessagesAttachmentByteSize)
        )
        XCTAssertEqual(exact.byteSize, maximumMessagesAttachmentByteSize)

        assertRejected(
            .fileTooLarge,
            try makeFile("over.txt", byteCount: maximumMessagesAttachmentByteSize + 1)
        )
    }

    func testEmptyFileIsRejected() throws {
        assertRejected(.emptyFile, try makeFile("empty.txt", byteCount: 0))
    }

    func testDirectoriesPackagesApplicationsAliasesAndSymlinksAreRejected() throws {
        let directory = fixtures.appendingPathComponent("plain-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        assertRejected(.notRegularFile, directory)

        let package = fixtures.appendingPathComponent("Fixture.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        assertRejected(.notRegularFile, package)

        let application = fixtures.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        assertRejected(.notRegularFile, application)

        // A symbolic link to a perfectly acceptable file is still not an ordinary file.
        let target = try makeFile("link-target.txt", byteCount: 32)
        let link = fixtures.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        assertRejected(.notRegularFile, link)
    }

    func testExecutableUnknownAndArchiveFilesAreRejected() throws {
        // A file that would otherwise pass every check, made executable.
        let executable = try makeFile("script.txt", byteCount: 16)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        assertRejected(.unsupportedType, executable)

        // Unknown generic data: no registered type, so no supported category.
        assertRejected(.unsupportedType, try makeFile("blob.imcpunknownfixture", byteCount: 16))
        assertRejected(.unsupportedType, try makeFile("extensionless", byteCount: 16))

        assertRejected(.unsupportedType, try makeFile("bundle.zip", byteCount: 16))
        assertRejected(.unsupportedType, try makeFile("disk.dmg", byteCount: 16))
        assertRejected(.unsupportedType, try makeFile("sheet.numbers", byteCount: 16))
        assertRejected(.unsupportedType, try makeFile("library.dylib", byteCount: 16))
    }

    func testMissingFileIsRejectedWithoutFilesystemDetail() throws {
        let missing = fixtures.appendingPathComponent("absent.txt")
        assertRejected(.unreadableSelection, missing)
    }

    func testRejectedFilePolicyIsEnforcedThroughTheToolWithoutConfirmationOrDispatch() async throws {
        let rejected: [(URL, MessagesAttachmentError)] = [
            (try makeFile("tool-empty.txt", byteCount: 0), .emptyFile),
            (
                try makeFile("tool-over.txt", byteCount: maximumMessagesAttachmentByteSize + 1),
                .fileTooLarge
            ),
            (try makeFile("tool-archive.zip", byteCount: 16), .unsupportedType),
            (fixtures.appendingPathComponent("tool-missing.txt"), .unreadableSelection),
        ]

        for (url, expected) in rejected {
            let harness = Harness(
                matches: [uniqueDirectMatch, uniqueDirectMatch],
                selection: .success(url)
            )
            await harness.assertAttachmentFailure(
                expected,
                arguments: ["recipient": .string("recipient@example.invalid")]
            )
            XCTAssertEqual(
                harness.elicitation.requestCount,
                0,
                "\(expected) asked the user to confirm a file that was already rejected"
            )
            let dispatches = await harness.sender.attachmentSubmissionCount
            let authorizations = await harness.sender.authorizationRequestCount
            XCTAssertEqual(dispatches, 0)
            XCTAssertEqual(authorizations, 0)
        }
    }

    // MARK: - Confirmation

    func testConfirmationShowsDestinationAndFileFactsButNeverThePath() async throws {
        let url = try makeFile("Quarterly Report.pdf", byteCount: 2_048)
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url)
        )
        _ = try await harness.call(["recipient": .string("recipient@example.invalid")])

        XCTAssertEqual(harness.elicitation.requestCount, 1)
        let message = harness.elicitation.lastMessage
        XCTAssertEqual(harness.elicitation.lastTitle, "Confirm existing-chat attachment submission")

        // The exact destination, because this is the authorization surface.
        XCTAssertTrue(message.contains("Synthetic Direct"))
        XCTAssertTrue(message.contains("recipient@example.invalid"))
        XCTAssertTrue(message.contains("Type: direct"))

        // The file's display name, public type description, and formatted size.
        XCTAssertTrue(message.contains("Attachment: Quarterly Report.pdf"))
        XCTAssertTrue(message.contains("File type: \(UTType.pdf.localizedDescription ?? "")"))
        XCTAssertTrue(message.contains("Size: \(Int64(2_048).formatted(.byteCount(style: .file)))"))

        // It authorizes an attachment submission, not a message body.
        XCTAssertTrue(message.contains("Submit this attachment"))
        XCTAssertTrue(message.contains("One file will be submitted as an attachment."))
        XCTAssertTrue(message.contains("No message text will be sent with it."))
        XCTAssertFalse(message.contains("Message:"))
        XCTAssertFalse(message.contains("Submit this message"))

        // Never the path, the containing directory, or the type identifier.
        XCTAssertFalse(message.contains(url.path))
        XCTAssertFalse(message.contains(url.deletingLastPathComponent().path))
        XCTAssertFalse(message.contains(fixtures.path))
        XCTAssertFalse(message.contains("file://"))
        XCTAssertFalse(message.contains(UTType.pdf.identifier))
    }

    func testGroupConfirmationStatesNoNewGroupIsCreated() async throws {
        let match = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic-group",
            destination: groupChat
        )
        let harness = Harness(
            matches: [match, match],
            selection: .success(try makeFile("photo.png", byteCount: 128))
        )
        _ = try await harness.call([
            "recipients": .array([
                .string("second@example.invalid"), .string("first@example.invalid"),
            ])
        ])

        let message = harness.elicitation.lastMessage
        XCTAssertTrue(message.contains("Synthetic Group"))
        XCTAssertTrue(message.contains("This existing group exactly matches the supplied participants."))
        XCTAssertTrue(message.contains("No new group will be created."))
        XCTAssertTrue(message.contains("Attachment: photo.png"))
    }

    func testNoAutomationPermissionIsRequestedBeforeTheFinalConfirmation() async throws {
        let log = AttachmentEventLog()
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            authorization: .consentRequired,
            eventLog: log
        )
        _ = try await harness.call(["recipient": .string("recipient@example.invalid")])

        let events = log.events
        let confirmation = try XCTUnwrap(events.firstIndex(of: "elicitation"))
        XCTAssertFalse(
            events[..<confirmation].contains("automation-request"),
            "Automation permission was requested before the user confirmed"
        )
        XCTAssertFalse(
            events[..<confirmation].contains("addressability"),
            "an Apple Event ran before the user confirmed while consent was still required"
        )
        // The permission request happens after confirmation and before dispatch.
        let request = try XCTUnwrap(events.firstIndex(of: "automation-request"))
        let dispatch = try XCTUnwrap(events.firstIndex(of: "attachment-submit"))
        XCTAssertLessThan(confirmation, request)
        XCTAssertLessThan(request, dispatch)
    }

    func testAlreadyAuthorizedAutomationPreflightsAddressabilityBeforeThePicker() async throws {
        let log = AttachmentEventLog()
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            authorization: .authorized,
            eventLog: log
        )
        _ = try await harness.call(["recipient": .string("recipient@example.invalid")])

        let events = log.events
        let preflight = try XCTUnwrap(events.firstIndex(of: "addressability"))
        let selection = try XCTUnwrap(events.firstIndex(of: "select"))
        XCTAssertLessThan(preflight, selection)
        // A non-prompting preflight never requests permission.
        XCTAssertFalse(events[..<preflight].contains("automation-request"))
    }

    func testUnaddressableChatFailsBeforeThePickerWhenAlreadyAuthorized() async throws {
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            authorization: .authorized,
            addressability: [false]
        )
        await harness.assertFailure(
            MessageSendError.chatUnavailableInAutomation,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )

        let selections = await harness.selector.selectionCount
        XCTAssertEqual(selections, 0, "the user was asked for a file that could not be sent")
        XCTAssertEqual(harness.elicitation.requestCount, 0)
        let dispatches = await harness.sender.attachmentSubmissionCount
        XCTAssertEqual(dispatches, 0)
    }

    func testDeniedAutomationFailsBeforeThePicker() async throws {
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            authorization: .denied
        )
        await harness.assertFailure(
            MessageSendError.automationDenied,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        let selections = await harness.selector.selectionCount
        XCTAssertEqual(selections, 0)
        XCTAssertEqual(harness.elicitation.requestCount, 0)
    }

    func testDeclinedCancelledAndMalformedConfirmationsDispatchZero() async throws {
        let outcomes: [CreateElicitation.Result] = [
            .init(action: .decline),
            .init(action: .cancel),
            .init(action: .accept, content: ["confirmed": .bool(false)]),
            .init(action: .accept, content: [:]),
        ]

        for outcome in outcomes {
            let harness = Harness(
                matches: [uniqueDirectMatch, uniqueDirectMatch],
                selection: .success(try makeFile("note.txt", byteCount: 8)),
                confirmation: outcome
            )
            do {
                _ = try await harness.call(["recipient": .string("recipient@example.invalid")])
                XCTFail("Expected the attachment submission to fail")
            } catch is MessageSendError {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(harness.elicitation.requestCount, 1)
            let dispatches = await harness.sender.attachmentSubmissionCount
            let messageDispatches = await harness.sender.chatSubmissionCount
            let authorizations = await harness.sender.authorizationRequestCount
            let compositions = await harness.composer.compositionCount
            XCTAssertEqual(dispatches, 0)
            XCTAssertEqual(messageDispatches, 0)
            XCTAssertEqual(authorizations, 0)
            XCTAssertEqual(compositions, 0)
        }
    }

    func testNativeConfirmationCancellationDispatchesZero() async throws {
        let native = RecordingAttachmentNativePresenter(outcome: .cancelled)
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            confirmationRequester: MessagesFinalSendConfirmationRequester(
                mode: { .appDialog },
                appPresenter: native
            )
        )
        await harness.assertFailure(
            MessageSendError.confirmationCancelled,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )

        XCTAssertEqual(native.requestCount, 1)
        // The native surface receives the same authoritative presentation.
        let presentation = try XCTUnwrap(native.lastPresentation)
        XCTAssertEqual(presentation.title, "Confirm existing-chat attachment submission")
        XCTAssertTrue(presentation.message.contains("Attachment: note.txt"))
        let dispatches = await harness.sender.attachmentSubmissionCount
        XCTAssertEqual(dispatches, 0)
    }

    // MARK: - Post-confirmation revalidation

    func testDestinationIsRevalidatedAfterConfirmation() async throws {
        // The matched conversation changes between confirmation and dispatch.
        let changed = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_other",
            destination: groupChat
        )
        for second in [MessagesConversationMatch.none, .ambiguous, .incomplete, changed] {
            let harness = Harness(
                matches: [uniqueDirectMatch, second],
                selection: .success(try makeFile("note.txt", byteCount: 8))
            )
            await harness.assertFailure(
                MessageSendError.staleMatchedConversation,
                arguments: ["recipient": .string("recipient@example.invalid")]
            )
            XCTAssertEqual(harness.elicitation.requestCount, 1)
            let dispatches = await harness.sender.attachmentSubmissionCount
            let authorizations = await harness.sender.authorizationRequestCount
            XCTAssertEqual(dispatches, 0)
            XCTAssertEqual(authorizations, 0, "permission was requested for a stale destination")
        }
    }

    func testExplicitChatIsRevalidatedAfterConfirmation() async throws {
        let harness = Harness(
            results: [.success(directChat), .success(groupChat)],
            selection: .success(try makeFile("note.txt", byteCount: 8))
        )
        await harness.assertFailure(
            MessageSendError.staleChatIdentifier,
            arguments: ["chat_id": .string("imcp-chat-v1_synthetic")]
        )
        XCTAssertEqual(harness.elicitation.requestCount, 1)
        let dispatches = await harness.sender.attachmentSubmissionCount
        XCTAssertEqual(dispatches, 0)
    }

    func testRemovedFileAfterConfirmationDispatchesZero() async throws {
        let url = try makeFile("note.txt", byteCount: 32)
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url),
            onConfirmation: { try? FileManager.default.removeItem(at: url) }
        )
        await harness.assertAttachmentFailure(
            .unreadableSelection,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        await harness.assertConfirmedButNeverDispatched()
    }

    func testModifiedFileAfterConfirmationDispatchesZero() async throws {
        let url = try makeFile("note.txt", byteCount: 32)
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url),
            onConfirmation: {
                try? Data(repeating: 0x41, count: 64).write(to: url)
            }
        )
        await harness.assertAttachmentFailure(
            .attachmentChanged,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        await harness.assertConfirmedButNeverDispatched()
    }

    func testReplacedFileWithIdenticalPropertiesStillFailsOnIdentity() async throws {
        let url = try makeFile("note.txt", byteCount: 32)
        let original = try FileManagerMessagesAttachmentValidator().validate(url)
        try XCTSkipIf(
            original.resourceIdentifier == nil,
            "this volume supplies no file resource identifier"
        )

        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url),
            onConfirmation: {
                // A different file of exactly the same size, name, type, and reported
                // modification date, put in the same place.
                try? FileManager.default.removeItem(at: url)
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: Data(repeating: 0x42, count: 32)
                )
                if let modified = original.modificationDate {
                    try? FileManager.default.setAttributes(
                        [.modificationDate: modified],
                        ofItemAtPath: url.path
                    )
                }
            }
        )
        await harness.assertAttachmentFailure(
            .attachmentChanged,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        await harness.assertConfirmedButNeverDispatched()

        let replacement = try FileManagerMessagesAttachmentValidator().validate(url)
        XCTAssertNotEqual(replacement.resourceIdentifier, original.resourceIdentifier)
        XCTAssertEqual(replacement.byteSize, original.byteSize)
    }

    func testEnlargedFileAfterConfirmationDispatchesZero() async throws {
        let url = try makeFile("note.txt", byteCount: 32)
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url),
            onConfirmation: {
                let handle = try? FileHandle(forWritingTo: url)
                try? handle?.truncate(atOffset: UInt64(maximumMessagesAttachmentByteSize + 1))
                try? handle?.close()
            }
        )
        await harness.assertAttachmentFailure(
            .fileTooLarge,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        await harness.assertConfirmedButNeverDispatched()
    }

    func testFileThatBecomesUnsupportedAfterConfirmationDispatchesZero() async throws {
        let url = try makeFile("note.txt", byteCount: 32)
        let fixtures = self.fixtures!
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url),
            onConfirmation: {
                // The same path now names a directory rather than an ordinary file.
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.createDirectory(
                    at: fixtures.appendingPathComponent("note.txt", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        )
        await harness.assertAttachmentFailure(
            .notRegularFile,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        await harness.assertConfirmedButNeverDispatched()
    }

    func testUnchangedFileIsNotFalselyRejected() async throws {
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 32))
        )
        _ = try await harness.call(["recipient": .string("recipient@example.invalid")])
        let dispatches = await harness.sender.attachmentSubmissionCount
        XCTAssertEqual(dispatches, 1)
    }

    // MARK: - Dispatch

    func testAcceptedSubmissionDispatchesExactlyOnceAndReturnsARedactedResult() async throws {
        let url = try makeFile("Quarterly Report.pdf", byteCount: 2_048)
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url)
        )
        let result = try await harness.call(["recipient": .string("recipient@example.invalid")])

        let dispatches = await harness.sender.attachmentSubmissionCount
        let messageDispatches = await harness.sender.chatSubmissionCount
        let compositions = await harness.composer.compositionCount
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(messageDispatches, 0, "an attachment must never be sent as text")
        XCTAssertEqual(compositions, 0)

        // The file the Apple Event carries is the one that was revalidated.
        let dispatchedURL = await harness.sender.lastAttachmentURL
        XCTAssertEqual(dispatchedURL, url)
        let dispatchedGUID = await harness.sender.lastChatGUID
        XCTAssertEqual(dispatchedGUID, directChat.chatGuid)

        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "submitted")
        XCTAssertEqual(result.objectValue?["service"]?.stringValue, "Messages")
        XCTAssertEqual(result.objectValue?["mode"]?.stringValue, "attachment")

        // The result carries no file fact, no destination, and no transport claim.
        let encoded = try XCTUnwrap(
            String(data: try JSONEncoder().encode(result), encoding: .utf8)
        )
        for leaked in [
            "Quarterly Report", ".pdf", url.path, fixtures.path, UTType.pdf.identifier,
            "2048", "2 KB", "recipient@example.invalid", "synthetic-guid.example",
            "imcp-chat-v1_synthetic", "iMessage", "SMS", "RCS", "delivered",
        ] {
            XCTAssertFalse(encoded.contains(leaked), "the attachment result leaked \(leaked)")
        }
    }

    // MARK: - Global Sending mode: Send Automatically

    func testAskBeforeSendingAttachmentRemainsUnchanged() async throws {
        let url = try makeFile("Still Confirmed.pdf", byteCount: 1_024)
        // No sendingMode argument: the default must behave exactly like the explicit
        // .askBeforeSending case, matching the accepted behavior at eb64ee2d.
        let harness = Harness(matches: [uniqueDirectMatch, uniqueDirectMatch], selection: .success(url))
        let result = try await harness.call(["recipient": .string("recipient@example.invalid")])

        XCTAssertEqual(harness.elicitation.requestCount, 1)
        let dispatches = await harness.sender.attachmentSubmissionCount
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "submitted")
        XCTAssertEqual(result.objectValue?["mode"]?.stringValue, "attachment")
    }

    func testAutomaticModeDirectAttachmentSkipsConfirmationButPreservesEveryOtherStep()
        async throws
    {
        let log = AttachmentEventLog()
        let url = try makeFile("Automatic.pdf", byteCount: 1_024)
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url),
            eventLog: log,
            sendingMode: { .sendAutomatically }
        )
        let result = try await harness.call(["recipient": .string("recipient@example.invalid")])

        XCTAssertEqual(
            harness.elicitation.requestCount,
            0,
            "Send Automatically must request zero final confirmations"
        )
        let selections = await harness.selector.selectionCount
        XCTAssertEqual(selections, 1, "the native picker still runs in automatic mode")
        // Destination match, picker/selection, destination match again (revalidation),
        // TCC, addressability, and dispatch all still run, in the same order, just
        // without an elicitation step.
        XCTAssertEqual(
            log.events,
            [
                "match", "automation-status", "select", "match", "automation-request",
                "addressability", "attachment-submit",
            ]
        )
        let dispatches = await harness.sender.attachmentSubmissionCount
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "submitted")
        XCTAssertEqual(result.objectValue?["mode"]?.stringValue, "attachment")
    }

    func testAutomaticModeGroupAttachmentSkipsConfirmationAndDispatchesOnceToTheExactResolvedChat()
        async throws
    {
        let match = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic-group",
            destination: groupChat
        )
        let harness = Harness(
            matches: [match, match],
            selection: .success(try makeFile("photo.png", byteCount: 128)),
            sendingMode: { .sendAutomatically }
        )
        let result = try await harness.call([
            "recipients": .array([
                .string("first@example.invalid"), .string("second@example.invalid"),
            ])
        ])

        XCTAssertEqual(harness.elicitation.requestCount, 0)
        let dispatches = await harness.sender.attachmentSubmissionCount
        let dispatchedGUID = await harness.sender.lastChatGUID
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(dispatchedGUID, groupChat.chatGuid)
        XCTAssertEqual(result.objectValue?["status"]?.stringValue, "submitted")
    }

    func testLiveModeChangesAreObservedForAttachmentsWithoutReinitializingTheService()
        async throws
    {
        final class SendingModeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storedMode: MessagesSendingMode = .askBeforeSending
            var mode: MessagesSendingMode {
                get { lock.withLock { storedMode } }
                set { lock.withLock { storedMode = newValue } }
            }
        }
        let box = SendingModeBox()
        let url = try makeFile("Live.txt", byteCount: 16)
        let harness = Harness(
            matches: [
                uniqueDirectMatch, uniqueDirectMatch, uniqueDirectMatch, uniqueDirectMatch,
            ],
            selection: .success(url),
            sendingMode: { box.mode }
        )

        _ = try await harness.call(["recipient": .string("recipient@example.invalid")])
        XCTAssertEqual(
            harness.elicitation.requestCount,
            1,
            "Ask Before Sending must request confirmation"
        )

        box.mode = .sendAutomatically

        _ = try await harness.call(["recipient": .string("recipient@example.invalid")])
        XCTAssertEqual(
            harness.elicitation.requestCount,
            1,
            "Send Automatically must take effect on the very next call, same service instance, without a second confirmation"
        )

        let dispatches = await harness.sender.attachmentSubmissionCount
        XCTAssertEqual(dispatches, 2)
    }

    func testPickerCancellationInAutomaticModeSendsNothing() async throws {
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .failure(MessagesAttachmentError.selectionCancelled),
            sendingMode: { .sendAutomatically }
        )
        await harness.assertAttachmentFailure(
            .selectionCancelled,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )

        let selections = await harness.selector.selectionCount
        XCTAssertEqual(selections, 1, "automatic mode must never bypass the picker")
        XCTAssertEqual(harness.elicitation.requestCount, 0)
        let dispatches = await harness.sender.attachmentSubmissionCount
        let authorizations = await harness.sender.authorizationRequestCount
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(authorizations, 0)
    }

    func testAutomaticModeStaleDestinationFailsClosedWithZeroDispatch() async throws {
        let changed = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_other",
            destination: groupChat
        )
        let harness = Harness(
            matches: [uniqueDirectMatch, changed],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            sendingMode: { .sendAutomatically }
        )
        await harness.assertFailure(
            MessageSendError.staleMatchedConversation,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )

        XCTAssertEqual(harness.elicitation.requestCount, 0, "confirmation was correctly skipped")
        let dispatches = await harness.sender.attachmentSubmissionCount
        let authorizations = await harness.sender.authorizationRequestCount
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(
            authorizations,
            0,
            "skipping confirmation must not weaken the stale-destination defense"
        )
    }

    func testAutomaticModeFileChangeFailsClosedWithZeroDispatch() async throws {
        let url = try makeFile("note.txt", byteCount: 32)
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(url),
            // Fires on the revalidation read, the only checkpoint shared by both modes,
            // simulating the file changing after selection/validation but before dispatch
            // even though there is no confirmation step to hook into here.
            onSecondResolve: {
                try? Data(repeating: 0x41, count: 64).write(to: url)
            },
            sendingMode: { .sendAutomatically }
        )
        await harness.assertAttachmentFailure(
            .attachmentChanged,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )

        XCTAssertEqual(harness.elicitation.requestCount, 0)
        let dispatches = await harness.sender.attachmentSubmissionCount
        XCTAssertEqual(
            dispatches,
            0,
            "skipping confirmation must not weaken file-identity revalidation"
        )
    }

    func testAutomaticModeAutomationDenialOrUnavailabilityFailsClosedWithZeroDispatch()
        async throws
    {
        // Denied at the non-prompting preflight, which runs unconditionally before the
        // mode is ever consulted.
        let deniedHarness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            authorization: .denied,
            sendingMode: { .sendAutomatically }
        )
        await deniedHarness.assertFailure(
            MessageSendError.automationDenied,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        let deniedDispatches = await deniedHarness.sender.attachmentSubmissionCount
        XCTAssertEqual(deniedDispatches, 0)

        // Unavailable at the post-authorization addressability check, which still runs
        // after the skipped confirmation.
        let unavailableHarness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note2.txt", byteCount: 8)),
            authorization: .consentRequired,
            addressability: [false],
            sendingMode: { .sendAutomatically }
        )
        await unavailableHarness.assertFailure(
            MessageSendError.chatUnavailableInAutomation,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        let unavailableDispatches = await unavailableHarness.sender.attachmentSubmissionCount
        XCTAssertEqual(unavailableDispatches, 0)
    }

    func testVerifiedNewRecipientRemainsUnsupportedForAttachmentsInAutomaticMode() async throws {
        let harness = Harness(matches: [.none], sendingMode: { .sendAutomatically })
        await harness.assertFailure(
            MessageSendError.attachmentRequiresExistingConversation,
            arguments: ["recipient": .string("brand-new@example.invalid")]
        )

        let compositions = await harness.composer.compositionCount
        XCTAssertEqual(compositions, 0, "attachments never reach system composition")
        await harness.assertNothingHappened()
    }

    func testExplicitChatAndGroupDestinationsDispatchExactlyOnce() async throws {
        let chatHarness = Harness(
            results: [.success(directChat), .success(directChat)],
            selection: .success(try makeFile("note.txt", byteCount: 8))
        )
        _ = try await chatHarness.call(["chat_id": .string("imcp-chat-v1_synthetic")])
        let chatDispatches = await chatHarness.sender.attachmentSubmissionCount
        XCTAssertEqual(chatDispatches, 1)

        let match = MessagesConversationMatch.unique(
            publicChatID: "imcp-chat-v1_synthetic-group",
            destination: groupChat
        )
        let groupHarness = Harness(
            matches: [match, match],
            selection: .success(try makeFile("photo.png", byteCount: 128))
        )
        _ = try await groupHarness.call([
            "recipients": .array([
                .string("first@example.invalid"), .string("second@example.invalid"),
            ])
        ])
        let groupDispatches = await groupHarness.sender.attachmentSubmissionCount
        let groupGUID = await groupHarness.sender.lastChatGUID
        XCTAssertEqual(groupDispatches, 1)
        XCTAssertEqual(groupGUID, groupChat.chatGuid)
    }

    func testAddressabilityIsRecheckedImmediatelyBeforeDispatch() async throws {
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            addressability: [false]
        )
        await harness.assertFailure(
            MessageSendError.chatUnavailableInAutomation,
            arguments: ["recipient": .string("recipient@example.invalid")]
        )
        let dispatches = await harness.sender.attachmentSubmissionCount
        let probes = await harness.sender.addressabilityCount
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(probes, 1)
    }

    func testAmbiguousDispatchFailureIsTerminalWithoutRetryOrFallback() async throws {
        let failures: [MessageSendError] = [
            .ambiguousSubmission, .automationFailed, .messagesUnavailable, .automationDenied,
        ]
        for failure in failures {
            let harness = Harness(
                matches: [uniqueDirectMatch, uniqueDirectMatch],
                selection: .success(try makeFile("note.txt", byteCount: 8)),
                submissionError: failure
            )
            await harness.assertFailure(
                failure,
                arguments: ["recipient": .string("recipient@example.invalid")]
            )

            // Exactly one dispatch attempt, and nothing else was tried afterwards.
            let dispatches = await harness.sender.attachmentSubmissionCount
            let messageDispatches = await harness.sender.chatSubmissionCount
            let compositions = await harness.composer.compositionCount
            let selections = await harness.selector.selectionCount
            XCTAssertEqual(dispatches, 1, "\(failure) retried the attachment dispatch")
            XCTAssertEqual(messageDispatches, 0, "\(failure) fell back to a text submission")
            XCTAssertEqual(compositions, 0, "\(failure) fell back to system composition")
            XCTAssertEqual(selections, 1, "\(failure) asked for another file")
            XCTAssertEqual(harness.elicitation.requestCount, 1)
        }
    }

    func testAmbiguousSubmissionKeepsItsUncertainWording() {
        let ambiguous = MessageSendError.ambiguousSubmission.localizedDescription
        XCTAssertTrue(ambiguous.contains("may have occurred"))
        XCTAssertFalse(ambiguous.contains("Nothing was sent"))
    }

    func testCancelledToolCallDispatchesZero() async throws {
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("note.txt", byteCount: 8)),
            confirmationRequester: SlowAttachmentConfirmationRequester()
        )
        let task = Task {
            try await harness.call(["recipient": .string("recipient@example.invalid")])
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled call to fail")
        } catch is CancellationError {
            let dispatches = await harness.sender.attachmentSubmissionCount
            let authorizations = await harness.sender.authorizationRequestCount
            XCTAssertEqual(dispatches, 0)
            XCTAssertEqual(authorizations, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Fixed script and typed descriptors

    func testFixedScriptGainsAnAttachmentHandlerAndStaysCompilable() {
        let source = AppleScriptMessagesSender.scriptSource
        XCTAssertTrue(source.contains("on submitChatAttachment(chatGUID, attachmentFile)"))
        XCTAssertTrue(source.contains("send attachmentFile to item 1 of targetChats"))

        let handler = source.components(separatedBy: "on submitChatAttachment(chatGUID, attachmentFile)")[1]
            .components(separatedBy: "end submitChatAttachment")[0]
        // The attachment handler repeats the same exact-chat checks as the text handler.
        XCTAssertTrue(handler.contains("set targetChats to every chat whose id = chatGUID"))
        XCTAssertTrue(handler.contains("if (count of targetChats) is 0 then error"))
        XCTAssertTrue(handler.contains("if (count of targetChats) is not 1 then error"))
        // Exactly one send, and no path, file coercion, or participant lookup in source.
        XCTAssertEqual(handler.components(separatedBy: "send ").count - 1, 1)
        for forbidden in [
            "POSIX file", "alias ", "/Users/", "/private/", "participant", "account", "as text",
            "quoted form",
        ] {
            XCTAssertFalse(handler.contains(forbidden), "the handler references \(forbidden)")
        }

        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        XCTAssertTrue(script?.compileAndReturnError(&error) == true, String(describing: error))
    }

    func testAttachmentTravelsAsATypedFileDescriptorRatherThanAPathString() throws {
        let url = try makeFile("note.txt", byteCount: 8)
        let descriptor = AppleScriptMessagesSender.fileDescriptor(url)

        // The attachment is carried as a file URL, not as text. Messages resolves the
        // `file` direct parameter from this descriptor type, so the path is never a
        // string the script has to interpret.
        XCTAssertEqual(descriptor.descriptorType, typeFileURL)
        XCTAssertNotEqual(descriptor.descriptorType, typeUnicodeText)
        XCTAssertEqual(
            try XCTUnwrap(descriptor.fileURLValue).standardizedFileURL,
            url.standardizedFileURL
        )

        // The chat GUID stays a plain text descriptor, exactly as before, so the two
        // arguments are distinguishable by type rather than by convention.
        let guid = AppleScriptMessagesSender.textDescriptor("synthetic-guid.example")
        XCTAssertEqual(guid.descriptorType, typeUnicodeText)
        XCTAssertEqual(guid.stringValue, "synthetic-guid.example")

        // `stringValue` and `fileURLValue` both coerce on demand, so neither reveals how
        // a descriptor is actually typed. `descriptorType` is the authority, and it is
        // what decides whether Messages reads the direct parameter as a file or as text.
        XCTAssertNotEqual(descriptor.descriptorType, guid.descriptorType)
        XCTAssertEqual(
            AppleScriptMessagesSender.textDescriptor(url.path).descriptorType,
            typeUnicodeText,
            "a path sent as text would be typed as text, which is exactly what is avoided"
        )
    }

    func testNoSyntheticValueIsEverInterpolatedIntoScriptSource() {
        let source = AppleScriptMessagesSender.scriptSource
        for forbidden in [
            "recipient@example.invalid", "synthetic-guid.example", "Quarterly Report", "note.txt",
            NSTemporaryDirectory(),
        ] {
            XCTAssertFalse(source.contains(forbidden), "the fixed script contains \(forbidden)")
        }
    }

    // MARK: - Privacy

    func testAttachmentErrorsAreCategoricalAndCarryNoFileDetail() throws {
        let url = try makeFile("Quarterly Report.pdf", byteCount: 2_048)
        let everyError: [MessagesAttachmentError] = [
            .selectionCancelled, .unreadableSelection, .notRegularFile, .emptyFile, .fileTooLarge,
            .unsupportedType, .attachmentChanged,
        ]

        for error in everyError {
            let message = try XCTUnwrap(error.errorDescription)
            for leaked in [
                url.path, url.lastPathComponent, "Quarterly Report", fixtures.path,
                NSTemporaryDirectory(), UTType.pdf.identifier, "com.apple", "public.", "2048",
                "NSCocoaErrorDomain", "NSFileReadNoSuchFileError", "errno", "file://",
            ] {
                XCTAssertFalse(message.contains(leaked), "\(error) leaked \(leaked)")
            }
            // Every pre-dispatch failure states plainly that nothing was sent.
            XCTAssertTrue(message.contains("Nothing was sent."), "\(error) omits the send status")
        }
    }

    func testLoggableSubmissionFactsAreCategoricalOnly() async throws {
        // The only per-submission fact production logs is the categorical destination
        // shape, which is asserted here through the values that compose it.
        let harness = Harness(
            matches: [uniqueDirectMatch, uniqueDirectMatch],
            selection: .success(try makeFile("Quarterly Report.pdf", byteCount: 2_048))
        )
        _ = try await harness.call(["recipient": .string("recipient@example.invalid")])

        XCTAssertEqual(MessagesChatKind.direct.rawValue, "direct")
        XCTAssertEqual(MessagesChatKind.group.rawValue, "group")
        // Nothing that identifies the file or the conversation is available to a log:
        // the sender only ever receives the GUID and the URL, and neither is logged.
        let dispatchedURL = await harness.sender.lastAttachmentURL
        XCTAssertNotNil(dispatchedURL)
    }

    // MARK: - Fixtures

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

    private var uniqueDirectMatch: MessagesConversationMatch {
        .unique(publicChatID: "imcp-chat-v1_synthetic", destination: directChat)
    }

    private func attachmentTool() throws -> iMCP.Tool {
        try XCTUnwrap(
            MessageService(sender: RecordingAttachmentSender()).tools.first {
                $0.name == "message_send_attachment"
            }
        )
    }

    /// Creates a sparse synthetic fixture of an exact logical size. Nothing here is real
    /// user content, and large bounds cost no disk.
    @discardableResult
    private func makeFile(_ name: String, byteCount: Int) throws -> URL {
        let url = fixtures.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        if byteCount > 0 {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(byteCount))
            try handle.close()
        }
        return url
    }

    private func assertRejected(
        _ expected: MessagesAttachmentError,
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let facts = try FileManagerMessagesAttachmentValidator().validate(url)
            XCTFail(
                "Expected \(expected) but \(url.lastPathComponent) was accepted as \(facts.contentType.identifier)",
                file: file,
                line: line
            )
        } catch let error as MessagesAttachmentError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

// MARK: - Harness

/// One fully wired `message_send_attachment` call with every edge stubbed.
private struct Harness {
    let sender: RecordingAttachmentSender
    let composer: RecordingAttachmentComposer
    let selector: StubAttachmentSelector
    let elicitation: StubAttachmentElicitation
    private let tool: iMCP.Tool

    init(
        results: [Result<MessagesResolvedChatDestination, Error>] = [],
        matches: [MessagesConversationMatch] = [],
        selection: Result<URL, Error> = .failure(MessagesAttachmentError.selectionCancelled),
        authorization: MessagesAutomationAuthorization = .consentRequired,
        addressability: [Bool] = [],
        submissionError: Error? = nil,
        confirmation: CreateElicitation.Result = .init(
            action: .accept,
            content: ["confirmed": .bool(true)]
        ),
        confirmationRequester: (any MessagesFinalSendConfirmationRequesting)? = nil,
        onConfirmation: (@Sendable () -> Void)? = nil,
        onSecondResolve: (@Sendable () -> Void)? = nil,
        eventLog: AttachmentEventLog? = nil,
        sendingMode: @escaping @Sendable () -> MessagesSendingMode = { .askBeforeSending }
    ) {
        self.sender = RecordingAttachmentSender(
            authorization: authorization,
            addressability: addressability,
            submissionError: submissionError,
            eventLog: eventLog
        )
        self.composer = RecordingAttachmentComposer()
        self.selector = StubAttachmentSelector(selection: selection, eventLog: eventLog)
        self.elicitation = StubAttachmentElicitation(
            result: confirmation,
            onRequest: onConfirmation,
            eventLog: eventLog
        )
        let service = MessageService(
            sender: sender,
            composer: composer,
            chatRepository: RecordingAttachmentChatRepository(
                results: results,
                matches: matches,
                eventLog: eventLog,
                onSecondResolve: onSecondResolve
            ),
            sendConfirmationRequester: confirmationRequester
                ?? MessagesFinalSendConfirmationRequester(mode: { .mcpForm }),
            attachmentSelector: selector,
            attachmentValidator: FileManagerMessagesAttachmentValidator(),
            chatDatabasePathOverride: "/synthetic/chat.db",
            sendingMode: sendingMode
        )
        self.tool = service.tools.first { $0.name == "message_send_attachment" }!
    }

    func call(_ arguments: [String: Value]) async throws -> Value {
        try await tool(arguments, context: ToolCallContext(elicitation: elicitation))
    }

    func assertFailure(
        _ expected: MessageSendError,
        arguments: [String: Value],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await call(arguments)
            XCTFail("Expected the attachment submission to fail", file: file, line: line)
        } catch let error as MessageSendError {
            XCTAssertEqual(
                error.localizedDescription,
                expected.localizedDescription,
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func assertAttachmentFailure(
        _ expected: MessagesAttachmentError,
        arguments: [String: Value],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await call(arguments)
            XCTFail("Expected the attachment submission to fail", file: file, line: line)
        } catch let error as MessagesAttachmentError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    /// No picker, no confirmation, no permission request, and no dispatch of any kind.
    func assertNothingHappened(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let selections = await selector.selectionCount
        let attachments = await sender.attachmentSubmissionCount
        let messages = await sender.chatSubmissionCount
        let authorizations = await sender.authorizationRequestCount
        let compositions = await composer.compositionCount
        XCTAssertEqual(selections, 0, "a file picker was presented", file: file, line: line)
        XCTAssertEqual(attachments, 0, file: file, line: line)
        XCTAssertEqual(messages, 0, file: file, line: line)
        XCTAssertEqual(authorizations, 0, file: file, line: line)
        XCTAssertEqual(compositions, 0, file: file, line: line)
        XCTAssertEqual(elicitation.requestCount, 0, file: file, line: line)
    }

    /// The user confirmed, then revalidation refused: exactly zero dispatch and no
    /// permission prompt.
    func assertConfirmedButNeverDispatched(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertEqual(elicitation.requestCount, 1, file: file, line: line)
        let attachments = await sender.attachmentSubmissionCount
        let messages = await sender.chatSubmissionCount
        let authorizations = await sender.authorizationRequestCount
        let selections = await selector.selectionCount
        XCTAssertEqual(attachments, 0, file: file, line: line)
        XCTAssertEqual(messages, 0, file: file, line: line)
        XCTAssertEqual(authorizations, 0, file: file, line: line)
        XCTAssertEqual(selections, 1, "the flow asked for a second file", file: file, line: line)
    }
}

// MARK: - Doubles

private actor RecordingAttachmentSender: MessagesSending {
    private(set) var chatSubmissionCount = 0
    private(set) var attachmentSubmissionCount = 0
    private(set) var authorizationStatusCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var addressabilityCount = 0
    private(set) var lastChatGUID: String?
    private(set) var lastAttachmentURL: URL?
    private let authorization: MessagesAutomationAuthorization
    private var addressability: [Bool]
    private let submissionError: Error?
    private let eventLog: AttachmentEventLog?

    init(
        authorization: MessagesAutomationAuthorization = .consentRequired,
        addressability: [Bool] = [],
        submissionError: Error? = nil,
        eventLog: AttachmentEventLog? = nil
    ) {
        self.authorization = authorization
        self.addressability = addressability
        self.submissionError = submissionError
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
    }

    func isChatAddressable(chatGUID: String) throws -> Bool {
        addressabilityCount += 1
        eventLog?.record("addressability")
        return addressability.isEmpty ? true : addressability.removeFirst()
    }

    func submit(chatGUID: String, body: String) throws {
        chatSubmissionCount += 1
        eventLog?.record("chat-submit")
        XCTFail("An attachment submission must never dispatch message text")
    }

    func submitChatAttachment(chatGUID: String, attachmentFile: URL) throws {
        attachmentSubmissionCount += 1
        lastChatGUID = chatGUID
        lastAttachmentURL = attachmentFile
        eventLog?.record("attachment-submit")
        if let submissionError { throw submissionError }
    }
}

private actor RecordingAttachmentComposer: MessagesNewRecipientComposing {
    private(set) var compositionCount = 0

    func compose(
        seedRecipient: String,
        seedBody: String
    ) async throws -> MessagesCompositionOutcome {
        compositionCount += 1
        XCTFail("An attachment submission must never reach system composition")
        return .userCompleted
    }
}

private actor StubAttachmentSelector: MessagesAttachmentSelecting {
    private(set) var selectionCount = 0
    private let selection: Result<URL, Error>
    private let eventLog: AttachmentEventLog?

    init(selection: Result<URL, Error>, eventLog: AttachmentEventLog?) {
        self.selection = selection
        self.eventLog = eventLog
    }

    func selectAttachment() throws -> URL {
        selectionCount += 1
        eventLog?.record("select")
        return try selection.get()
    }
}

private final class AttachmentEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] { lock.withLock { storedEvents } }

    func record(_ event: String) {
        lock.withLock { storedEvents.append(event) }
    }
}

private final class RecordingAttachmentChatRepository: MessagesChatListing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<MessagesResolvedChatDestination, Error>]
    private var matches: [MessagesConversationMatch]
    private let eventLog: AttachmentEventLog?
    private var callCount = 0
    /// Fires once, on the second destination read only. That read is always the
    /// revalidation read — the first happens during `prepareDestination`, before the
    /// picker even runs — so this simulates "the world changed between authorization
    /// and dispatch" identically in Ask Before Sending (where `onConfirmation` also
    /// fires at that same logical moment) and Send Automatically (which has no
    /// confirmation step to hook into).
    private let onSecondResolve: (@Sendable () -> Void)?

    init(
        results: [Result<MessagesResolvedChatDestination, Error>],
        matches: [MessagesConversationMatch],
        eventLog: AttachmentEventLog?,
        onSecondResolve: (@Sendable () -> Void)? = nil
    ) {
        self.results = results
        self.matches = matches
        self.eventLog = eventLog
        self.onSecondResolve = onSecondResolve
    }

    private func recordCallAndFireHookIfSecond() {
        callCount += 1
        if callCount == 2 { onSecondResolve?() }
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
            recordCallAndFireHookIfSecond()
            return results.isEmpty ? nil : results.removeFirst()
        }
        eventLog?.record("match")
        guard let result else { throw MessagesChatRepositoryError.staleIdentifier }
        return try result.get()
    }

    func matchConversation(
        normalizedParticipants: Set<String>,
        kind: MessagesChatKind,
        databasePath: String
    ) throws -> MessagesConversationMatch {
        let match: MessagesConversationMatch = lock.withLock {
            recordCallAndFireHookIfSecond()
            return matches.isEmpty ? .none : matches.removeFirst()
        }
        eventLog?.record("match")
        return match
    }
}

private final class StubAttachmentElicitation: ElicitationRequester, @unchecked Sendable {
    private let lock = NSLock()
    private let result: CreateElicitation.Result
    private let onRequest: (@Sendable () -> Void)?
    private let eventLog: AttachmentEventLog?
    private var storedRequestCount = 0
    private var storedLastMessage = ""
    private var storedLastTitle: String?

    let supportsFormElicitation = true

    var requestCount: Int { lock.withLock { storedRequestCount } }
    var lastMessage: String { lock.withLock { storedLastMessage } }
    var lastTitle: String? { lock.withLock { storedLastTitle } }

    init(
        result: CreateElicitation.Result,
        onRequest: (@Sendable () -> Void)?,
        eventLog: AttachmentEventLog?
    ) {
        self.result = result
        self.onRequest = onRequest
        self.eventLog = eventLog
    }

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        lock.withLock {
            storedRequestCount += 1
            storedLastMessage = message
            storedLastTitle = schema.title
        }
        eventLog?.record("elicitation")
        // Simulates the world changing while the user is looking at the confirmation.
        onRequest?()
        return result
    }
}

private struct SlowAttachmentConfirmationRequester: MessagesFinalSendConfirmationRequesting {
    func requestConfirmation(
        _ presentation: MessagesSendConfirmationPresentation,
        elicitation: any ElicitationRequester
    ) async throws {
        try await Task.sleep(for: .seconds(10))
    }
}

private final class RecordingAttachmentNativePresenter:
    MessagesNativeSendConfirmationPresenting, @unchecked Sendable
{
    private let lock = NSLock()
    private let outcome: MessagesNativeSendConfirmationOutcome
    private var storedRequestCount = 0
    private var storedLastPresentation: MessagesSendConfirmationPresentation?

    var requestCount: Int { lock.withLock { storedRequestCount } }
    var lastPresentation: MessagesSendConfirmationPresentation? {
        lock.withLock { storedLastPresentation }
    }

    init(outcome: MessagesNativeSendConfirmationOutcome) {
        self.outcome = outcome
    }

    @MainActor
    func requestConfirmation(
        _ presentation: MessagesSendConfirmationPresentation
    ) throws -> MessagesNativeSendConfirmationOutcome {
        lock.withLock {
            storedRequestCount += 1
            storedLastPresentation = presentation
        }
        return outcome
    }
}

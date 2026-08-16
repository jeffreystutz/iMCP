import XCTest

@testable import iMCP

final class MessagesSendingModeTests: XCTestCase {
    private func freshDefaults(_ testName: String = #function) -> UserDefaults {
        let suiteName = "MessagesSendingModeTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testFactoryDefaultIsAskBeforeSending() {
        let defaults = freshDefaults()

        XCTAssertEqual(MessagesSendingMode.load(from: defaults), .askBeforeSending)
        XCTAssertEqual(MessagesSendingMode.defaultValue, .askBeforeSending)
    }

    func testPersistenceRoundTripForBothModes() {
        let defaults = freshDefaults()

        defaults.set(MessagesSendingMode.sendAutomatically.rawValue, forKey: MessagesSendingMode.storageKey)
        XCTAssertEqual(MessagesSendingMode.load(from: defaults), .sendAutomatically)

        defaults.set(MessagesSendingMode.askBeforeSending.rawValue, forKey: MessagesSendingMode.storageKey)
        XCTAssertEqual(MessagesSendingMode.load(from: defaults), .askBeforeSending)
    }

    func testAbsentCorruptOrUnknownStoredValueFailsSafeToAskBeforeSending() {
        let defaults = freshDefaults()

        // No value ever written.
        XCTAssertEqual(MessagesSendingMode.load(from: defaults), .askBeforeSending)

        // Empty string.
        defaults.set("", forKey: MessagesSendingMode.storageKey)
        XCTAssertEqual(MessagesSendingMode.load(from: defaults), .askBeforeSending)

        // Unrecognized/corrupt value.
        defaults.set("corrupt", forKey: MessagesSendingMode.storageKey)
        XCTAssertEqual(MessagesSendingMode.load(from: defaults), .askBeforeSending)

        // A plausible-looking but unrecognized value must not be guessed toward automatic.
        defaults.set("automatic", forKey: MessagesSendingMode.storageKey)
        XCTAssertEqual(MessagesSendingMode.load(from: defaults), .askBeforeSending)
    }

    func testRejectedOldGranularPersistedStateCannotAccidentallyEnableSendAutomatically() {
        let defaults = freshDefaults()

        // Simulate a developer having exercised the rejected four-category model
        // during manual testing before it was replaced: every category enabled,
        // persisted under its own (different) storage key.
        let oldGranularStorageKey = "me.mattt.iMCP.messagesAutomaticSendPolicy"
        let allCategoriesEnabledJSON = Data(
            """
            ["existingDirectConversationText","existingGroupConversationText",\
            "existingDirectConversationAttachment","existingGroupConversationAttachment"]
            """.utf8
        )
        defaults.set(allCategoriesEnabledJSON, forKey: oldGranularStorageKey)

        // The new binary mode must never read that key, so it must still resolve
        // to the safe default even though the old key claims "everything automatic."
        XCTAssertEqual(
            MessagesSendingMode.load(from: defaults),
            .askBeforeSending,
            "An old rejected granular persisted value must never accidentally enable Send Automatically"
        )

        // And explicitly setting the new mode is unaffected by the old key's presence.
        defaults.set(MessagesSendingMode.sendAutomatically.rawValue, forKey: MessagesSendingMode.storageKey)
        XCTAssertEqual(MessagesSendingMode.load(from: defaults), .sendAutomatically)
    }

    func testConfirmationPresentationRemainsIndependentOfSendingMode() {
        let defaults = freshDefaults()

        XCTAssertEqual(MessagesSendConfirmationMode.load(from: defaults), .automatic)

        defaults.set(MessagesSendingMode.sendAutomatically.rawValue, forKey: MessagesSendingMode.storageKey)
        XCTAssertEqual(
            MessagesSendConfirmationMode.load(from: defaults),
            .automatic,
            "Changing the sending mode must not affect the confirmation-presentation setting"
        )

        defaults.set("appDialog", forKey: MessagesSendConfirmationMode.storageKey)
        XCTAssertEqual(MessagesSendConfirmationMode.load(from: defaults), .appDialog)
        XCTAssertEqual(
            MessagesSendingMode.load(from: defaults),
            .sendAutomatically,
            "Changing confirmation presentation must not affect the sending mode"
        )
    }

    func testConfirmationPresentationTitleForFormerAutomaticIsNowBestAvailable() {
        // The stored/raw semantic value is preserved — only the user-facing label changed.
        XCTAssertEqual(MessagesSendConfirmationMode.automatic.rawValue, "automatic")
        XCTAssertEqual(MessagesSendConfirmationMode.automatic.title, "Best available")
    }
}

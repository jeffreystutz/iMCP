import XCTest

@testable import iMCP

final class MessagesAutomaticSendPolicyTests: XCTestCase {
    private func freshDefaults(_ testName: String = #function) -> UserDefaults {
        let suiteName = "MessagesAutomaticSendPolicyTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testFactoryDefaultIsConfirmationRequiredForEveryCategory() {
        let defaults = freshDefaults()

        let policy = MessagesAutomaticSendPolicy.load(from: defaults)

        for category in MessagesAutomaticSendCategory.allCases {
            XCTAssertFalse(
                policy.isAutomatic(category),
                "\(category) must require confirmation by factory default"
            )
        }
        XCTAssertFalse(policy.isAnyCategoryAutomatic)
        XCTAssertFalse(policy.isEveryCategoryAutomatic)
        XCTAssertEqual(policy, .defaultValue)
        XCTAssertEqual(policy, .confirmationRequiredForEverything)
    }

    func testPolicyPersistenceRoundTrip() {
        let defaults = freshDefaults()

        var policy = MessagesAutomaticSendPolicy.load(from: defaults)
        policy.setAutomatic(true, for: .existingDirectConversationText)
        policy.setAutomatic(true, for: .existingGroupConversationAttachment)
        policy.save(to: defaults)

        let reloaded = MessagesAutomaticSendPolicy.load(from: defaults)
        XCTAssertTrue(reloaded.isAutomatic(.existingDirectConversationText))
        XCTAssertTrue(reloaded.isAutomatic(.existingGroupConversationAttachment))
        XCTAssertFalse(reloaded.isAutomatic(.existingGroupConversationText))
        XCTAssertFalse(reloaded.isAutomatic(.existingDirectConversationAttachment))
        XCTAssertEqual(reloaded, policy)
    }

    func testIndividualCategoryUpdatesDoNotMutateUnrelatedCategories() {
        var policy = MessagesAutomaticSendPolicy.confirmationRequiredForEverything

        policy.setAutomatic(true, for: .existingDirectConversationText)
        XCTAssertTrue(policy.isAutomatic(.existingDirectConversationText))
        for category in MessagesAutomaticSendCategory.allCases
        where category != .existingDirectConversationText {
            XCTAssertFalse(policy.isAutomatic(category), "\(category) must be unaffected")
        }

        policy.setAutomatic(true, for: .existingGroupConversationText)
        XCTAssertTrue(policy.isAutomatic(.existingDirectConversationText))
        XCTAssertTrue(policy.isAutomatic(.existingGroupConversationText))
        XCTAssertFalse(policy.isAutomatic(.existingDirectConversationAttachment))
        XCTAssertFalse(policy.isAutomatic(.existingGroupConversationAttachment))

        policy.setAutomatic(false, for: .existingDirectConversationText)
        XCTAssertFalse(policy.isAutomatic(.existingDirectConversationText))
        XCTAssertTrue(
            policy.isAutomatic(.existingGroupConversationText),
            "Disabling one category must not disable an unrelated already-enabled category"
        )
    }

    func testAllowEverythingEnablesAllCurrentlySupportedCategories() {
        var policy = MessagesAutomaticSendPolicy.confirmationRequiredForEverything

        policy.allowEverythingAutomatically()

        for category in MessagesAutomaticSendCategory.allCases {
            XCTAssertTrue(policy.isAutomatic(category), "\(category) must be automatic")
        }
        XCTAssertTrue(policy.isEveryCategoryAutomatic)
        XCTAssertTrue(policy.isAnyCategoryAutomatic)
    }

    func testRequireConfirmationResetsEveryCategory() {
        var policy = MessagesAutomaticSendPolicy.confirmationRequiredForEverything
        policy.allowEverythingAutomatically()
        XCTAssertTrue(policy.isEveryCategoryAutomatic)

        policy.requireConfirmationForEverything()

        for category in MessagesAutomaticSendCategory.allCases {
            XCTAssertFalse(policy.isAutomatic(category), "\(category) must require confirmation")
        }
        XCTAssertFalse(policy.isAnyCategoryAutomatic)
        XCTAssertEqual(policy, .confirmationRequiredForEverything)
    }

    func testAbsentOrCorruptOrUnknownPersistedValuesResolveSafelyToConfirmationRequired() {
        let defaults = freshDefaults()

        // No value ever written.
        XCTAssertEqual(MessagesAutomaticSendPolicy.load(from: defaults), .defaultValue)

        // Empty data.
        defaults.set(Data(), forKey: MessagesAutomaticSendPolicy.storageKey)
        XCTAssertEqual(MessagesAutomaticSendPolicy.load(from: defaults), .defaultValue)

        // Corrupt, non-JSON data.
        defaults.set(Data([0xFF, 0x00, 0x13]), forKey: MessagesAutomaticSendPolicy.storageKey)
        XCTAssertEqual(MessagesAutomaticSendPolicy.load(from: defaults), .defaultValue)

        // Well-formed JSON encoding a category unknown to this build (simulating a future
        // category, or a downgrade after a category was renamed/removed).
        let futureCategoryJSON = Data(
            "[\"existingDirectConversationText\",\"someFutureNewRecipientCategory\"]".utf8
        )
        defaults.set(futureCategoryJSON, forKey: MessagesAutomaticSendPolicy.storageKey)
        let decoded = MessagesAutomaticSendPolicy.load(from: defaults)
        XCTAssertEqual(
            decoded,
            .defaultValue,
            "An unknown category anywhere in the payload must fail the whole decode safely to confirmation-required, never partially trust the payload"
        )
    }

    func testConfirmationPresentationSettingRemainsIndependentOfAutomaticSendPolicy() {
        let defaults = freshDefaults()

        // Changing automatic-send policy must not touch the unrelated confirmation
        // presentation setting, and vice versa.
        XCTAssertEqual(MessagesSendConfirmationMode.load(from: defaults), .automatic)

        var policy = MessagesAutomaticSendPolicy.load(from: defaults)
        policy.allowEverythingAutomatically()
        policy.save(to: defaults)

        XCTAssertEqual(
            MessagesSendConfirmationMode.load(from: defaults),
            .automatic,
            "Automatic-send policy changes must not affect confirmation presentation mode"
        )

        defaults.set("appDialog", forKey: MessagesSendConfirmationMode.storageKey)
        XCTAssertEqual(MessagesSendConfirmationMode.load(from: defaults), .appDialog)
        XCTAssertTrue(
            MessagesAutomaticSendPolicy.load(from: defaults).isEveryCategoryAutomatic,
            "Confirmation presentation mode changes must not affect automatic-send policy"
        )
    }

    func testCategoryIdentifiersAreStableStorageValues() {
        // These raw values are the on-disk JSON representation. Changing one is a silent
        // migration hazard, so pin the expected set explicitly.
        XCTAssertEqual(
            Set(MessagesAutomaticSendCategory.allCases.map(\.rawValue)),
            Set([
                "existingDirectConversationText",
                "existingGroupConversationText",
                "existingDirectConversationAttachment",
                "existingGroupConversationAttachment",
            ])
        )
    }
}

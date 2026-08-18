import XCTest

@testable import iMCP

final class MenuBarIconAppearanceTests: XCTestCase {
    func testServerDisabledTakesPrecedenceRegardlessOfSendingMode() {
        XCTAssertEqual(
            MenuBarIconAppearance.resolve(isServerEnabled: false, sendingMode: .askBeforeSending),
            .serverDisabled
        )
        XCTAssertEqual(
            MenuBarIconAppearance.resolve(isServerEnabled: false, sendingMode: .sendAutomatically),
            .serverDisabled
        )
    }

    func testEnabledAskBeforeSendingIsNormalAppearance() {
        XCTAssertEqual(
            MenuBarIconAppearance.resolve(isServerEnabled: true, sendingMode: .askBeforeSending),
            .askBeforeSending
        )
    }

    func testEnabledSendAutomaticallyIsAutomaticSendingActive() {
        XCTAssertEqual(
            MenuBarIconAppearance.resolve(isServerEnabled: true, sendingMode: .sendAutomatically),
            .automaticSendingActive
        )
    }

    func testIsAutomaticSendingActiveIsTrueOnlyForThatOneCase() {
        XCTAssertFalse(MenuBarIconAppearance.serverDisabled.isAutomaticSendingActive)
        XCTAssertFalse(MenuBarIconAppearance.askBeforeSending.isAutomaticSendingActive)
        XCTAssertTrue(MenuBarIconAppearance.automaticSendingActive.isAutomaticSendingActive)
    }

    func testDisablingServerWhileAutomaticDoesNotProduceAThirdCase() {
        // Re-enabling after a disable must resolve back to the same automatic
        // appearance rather than some new intermediate/paused case, since the
        // persisted Sending mode itself never changed.
        let disabled = MenuBarIconAppearance.resolve(isServerEnabled: false, sendingMode: .sendAutomatically)
        let reEnabled = MenuBarIconAppearance.resolve(isServerEnabled: true, sendingMode: .sendAutomatically)

        XCTAssertEqual(disabled, .serverDisabled)
        XCTAssertEqual(reEnabled, .automaticSendingActive)
    }
}

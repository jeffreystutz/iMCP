import XCTest

@testable import iMCP

/// Guards the persistent user-selected Messages access configuration.
///
/// A sandboxed app can only mint a persistent app-scoped security-scoped bookmark when the
/// bookmark is created `.withSecurityScope` *and* the app declares
/// `com.apple.security.files.bookmarks.app-scope`. Missing either one fails at runtime with
/// `NSCocoaErrorDomain` 256, "Failed to retrieve app-scope key" — a failure that unit tests
/// running unsandboxed cannot reproduce, so the configuration itself is asserted here.
final class MessagesBookmarkAccessTests: XCTestCase {
    private static let appScopedBookmarkEntitlement =
        "com.apple.security.files.bookmarks.app-scope"

    func testPersistentBookmarkOptionsRequestSecurityScopeAndReadOnlyAccess() {
        let options = MessageService.readOnlySecurityScopedBookmarkOptions

        XCTAssertTrue(
            options.contains(.withSecurityScope),
            "Persistent bookmarks must be security-scoped, or the sandbox cannot restore access"
        )
        XCTAssertTrue(
            options.contains(.securityScopeAllowOnlyReadAccess),
            "Messages access must stay read-only"
        )
    }

    func testBothEntitlementFilesDeclareAppScopedBookmarks() throws {
        for file in ["App/App.Debug.entitlements", "App/App.entitlements"] {
            let entitlements = try Self.entitlements(at: file)

            XCTAssertEqual(
                entitlements[Self.appScopedBookmarkEntitlement] as? Bool,
                true,
                "\(file) must declare \(Self.appScopedBookmarkEntitlement)"
            )
            // The app-scoped bookmark is only useful alongside the ability to select a
            // location in the first place, which Debug declares explicitly and Release
            // inherits from the ENABLE_USER_SELECTED_FILES build setting.
            XCTAssertEqual(
                entitlements["com.apple.security.automation.apple-events"] as? Bool,
                true,
                "\(file) must retain Apple Events automation"
            )
        }
    }

    func testNeitherBookmarkPathCreatesAnUnscopedBookmark() throws {
        // The defective form was `options: .securityScopeAllowOnlyReadAccess` on its own,
        // which silently produces a bookmark the sandbox cannot restore. Comments are
        // stripped so explanatory prose cannot fail the check.
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("App/Services/Messages.swift"),
            encoding: .utf8
        )
        let code =
            source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains("options: .securityScopeAllowOnlyReadAccess"))
        XCTAssertEqual(
            code.components(separatedBy: "options: Self.readOnlySecurityScopedBookmarkOptions")
                .count - 1,
            2,
            "Both the directory and legacy database bookmark paths must use the shared options"
        )
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func entitlements(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(plist as? [String: Any], "\(path) is not a plist dictionary")
    }
}

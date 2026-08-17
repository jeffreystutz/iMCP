import Foundation
import XCTest

@testable import iMCP

/// Coverage for allowed-folder grant persistence and filesystem containment.
///
/// Every path here is a synthetic temporary directory created and torn down by this
/// suite. No real user folder, file, or private data is referenced.
final class AllowedFolderGrantStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var storageKey: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("iMCPAllowedFolderFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storageKey = "test.allowedFolders.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: storageKey))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let storageKey { UserDefaults().removePersistentDomain(forName: storageKey) }
        root = nil
        defaults = nil
        storageKey = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> UserDefaultsAllowedFolderGrantStore {
        UserDefaultsAllowedFolderGrantStore(
            defaults: defaults,
            storageKey: "grants",
            bookmarkOptions: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        )
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ relativePath: String, in directory: URL, byteCount: Int = 8) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        if byteCount > 0 {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(byteCount))
            try handle.close()
        }
        return url
    }

    // MARK: - Store persistence

    func testAddedGrantIsListedWithAFriendlyNameAndCanBeResolved() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")

        let grant = try store.addGrant(for: folder)
        XCTAssertEqual(grant.displayName, "allowed")

        let listed = store.listGrants()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, grant.id)

        let resolvedURL = try AllowedFolderBookmark.resolve(grant.bookmarkData)
        XCTAssertEqual(resolvedURL.standardizedFileURL.path, folder.standardizedFileURL.path)
    }

    func testAddingTheSameFolderTwiceDeduplicatesToOneGrant() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")

        let first = try store.addGrant(for: folder)
        let second = try store.addGrant(for: folder)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.listGrants().count, 1)
    }

    func testRemoveGrantDeletesOnlyIMCPsRecordNeverTheFolder() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        let grant = try store.addGrant(for: folder)

        store.removeGrant(id: grant.id)

        XCTAssertTrue(store.listGrants().isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path),
            "removing a grant must never delete the user's folder"
        )
    }

    func testReplaceGrantKeepsTheSameIdentityButNewBookmark() throws {
        let store = makeStore()
        let originalFolder = try makeDirectory("original")
        let replacementFolder = try makeDirectory("replacement")
        let grant = try store.addGrant(for: originalFolder)

        let replaced = try store.replaceGrant(id: grant.id, with: replacementFolder)

        XCTAssertEqual(replaced.id, grant.id)
        XCTAssertEqual(store.listGrants().count, 1)
        let resolvedURL = try AllowedFolderBookmark.resolve(replaced.bookmarkData)
        XCTAssertEqual(resolvedURL.standardizedFileURL.path, replacementFolder.standardizedFileURL.path)
    }

    func testReplacingAMissingGrantIdFails() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        XCTAssertThrowsError(try store.replaceGrant(id: UUID(), with: folder)) { error in
            XCTAssertEqual(error as? AllowedFolderGrantError, .grantNotFound)
        }
    }

    // MARK: - Cross-instance synchronization

    /// Production constructs a separate `UserDefaultsAllowedFolderGrantStore` instance for
    /// Settings and for the send-side resolver, both over the same `UserDefaults` storage.
    /// `refreshBookmark` only updates an existing row by id; it never re-inserts one. A
    /// stale-bookmark refresh issued by one instance for a grant another instance already
    /// removed must therefore stay a no-op, never resurrecting the removed grant.
    func testStaleRefreshFromOneInstanceCannotResurrectAGrantRemovedByAnother() throws {
        let sendSideStore = makeStore()
        let settingsStore = UserDefaultsAllowedFolderGrantStore(
            defaults: defaults,
            storageKey: "grants",
            bookmarkOptions: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        )
        let folder = try makeDirectory("resurrect-me")
        let grant = try sendSideStore.addGrant(for: folder)

        settingsStore.removeGrant(id: grant.id)
        XCTAssertTrue(sendSideStore.listGrants().isEmpty)

        sendSideStore.refreshBookmark(id: grant.id, bookmarkData: grant.bookmarkData)

        XCTAssertTrue(
            sendSideStore.listGrants().isEmpty,
            "a stale refresh resurrected a removed grant"
        )
        XCTAssertTrue(settingsStore.listGrants().isEmpty)
    }

    /// Exercises the production cross-instance lock under real concurrent access: many
    /// adds, issued concurrently from two separate store instances sharing the same
    /// `UserDefaults` storage, must all be observed in the final persisted state. A
    /// per-instance (rather than shared `static`) lock would make this flaky under
    /// contention, since an unsynchronized load-modify-save sequence from one instance can
    /// silently overwrite a concurrent write from the other.
    func testConcurrentAddsAcrossTwoInstancesLoseNoGrants() throws {
        let storeA = makeStore()
        let storeB = UserDefaultsAllowedFolderGrantStore(
            defaults: defaults,
            storageKey: "grants",
            bookmarkOptions: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        )
        let folderCount = 24
        let folders = try (0 ..< folderCount).map { try makeDirectory("concurrent-\($0)") }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.allowedFolderGrants.concurrent", attributes: .concurrent)
        for (index, folder) in folders.enumerated() {
            let store = index.isMultiple(of: 2) ? storeA : storeB
            group.enter()
            queue.async {
                defer { group.leave() }
                _ = try? store.addGrant(for: folder)
            }
        }
        group.wait()

        let finalGrants = storeA.listGrants()
        XCTAssertEqual(
            finalGrants.count,
            folderCount,
            "concurrent adds across instances lost or duplicated grants"
        )
        let resolvedPaths = Set(
            finalGrants.compactMap { try? AllowedFolderBookmark.resolve($0.bookmarkData).standardizedFileURL.path }
        )
        XCTAssertEqual(
            resolvedPaths.count,
            folderCount,
            "persisted state was corrupted by an interleaved write"
        )
    }

    // MARK: - Resolver containment

    func testFileInsideAnAllowedRootResolves() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        let file = try makeFile("note.txt", in: folder)
        try store.addGrant(for: folder)
        let resolver = AllowedFolderGrantResolver(store: store)

        let access = try resolver.resolveAccess(forRequestedPath: file.path)
        defer { access.release() }
        XCTAssertEqual(access.fileURL.path, file.path)
    }

    func testFileOutsideEveryAllowedRootFails() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        let outside = try makeDirectory("not-allowed")
        let file = try makeFile("note.txt", in: outside)
        try store.addGrant(for: folder)
        let resolver = AllowedFolderGrantResolver(store: store)

        XCTAssertThrowsError(try resolver.resolveAccess(forRequestedPath: file.path)) { error in
            XCTAssertEqual(error as? MessagesAttachmentSourceError, .pathNotAllowed)
        }
    }

    func testZeroGrantsRejectsEveryFilesystemSource() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        let file = try makeFile("note.txt", in: folder)
        let resolver = AllowedFolderGrantResolver(store: store)

        XCTAssertThrowsError(try resolver.resolveAccess(forRequestedPath: file.path)) { error in
            XCTAssertEqual(error as? MessagesAttachmentSourceError, .pathNotAllowed)
        }
    }

    func testPrefixConfusableSiblingFolderIsRejected() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        // A sibling folder whose name starts with the allowed folder's full name, but is
        // a different, non-contained directory. Naive string-prefix containment would
        // wrongly accept this.
        let sibling = try makeDirectory("allowed-evil")
        let file = try makeFile("secret.txt", in: sibling)
        try store.addGrant(for: folder)
        let resolver = AllowedFolderGrantResolver(store: store)

        XCTAssertThrowsError(try resolver.resolveAccess(forRequestedPath: file.path)) { error in
            XCTAssertEqual(error as? MessagesAttachmentSourceError, .pathNotAllowed)
        }
    }

    func testLexicalTraversalCannotEscapeTheAllowedRoot() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        let secretSibling = try makeDirectory("secret")
        _ = try makeFile("file.txt", in: secretSibling)
        try store.addGrant(for: folder)
        let resolver = AllowedFolderGrantResolver(store: store)

        let traversalPath =
            folder.appendingPathComponent("../secret/file.txt", isDirectory: false).path

        XCTAssertThrowsError(try resolver.resolveAccess(forRequestedPath: traversalPath)) { error in
            XCTAssertEqual(error as? MessagesAttachmentSourceError, .pathNotAllowed)
        }
    }

    func testSymlinkEscapeFromInsideTheAllowedRootIsRejected() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        let secretFolder = try makeDirectory("secret")
        let secretFile = try makeFile("secret.txt", in: secretFolder)
        try store.addGrant(for: folder)
        let resolver = AllowedFolderGrantResolver(store: store)

        // A symlink whose own path is lexically inside the allowed root, but whose
        // target escapes it entirely.
        let escapeLink = folder.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: escapeLink,
            withDestinationURL: secretFolder
        )
        let requestedPath = escapeLink.appendingPathComponent("secret.txt").path

        XCTAssertThrowsError(try resolver.resolveAccess(forRequestedPath: requestedPath)) { error in
            XCTAssertEqual(error as? MessagesAttachmentSourceError, .pathNotAllowed)
        }
        // The legitimate file is untouched and still reachable through its real path.
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretFile.path))
    }

    func testRelativePathIsRejectedBeforeAnyGrantIsConsulted() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        try store.addGrant(for: folder)
        let resolver = AllowedFolderGrantResolver(store: store)

        XCTAssertThrowsError(try resolver.resolveAccess(forRequestedPath: "relative/note.txt")) {
            error in
            XCTAssertEqual(error as? MessagesAttachmentSourceError, .invalidFilePath)
        }
    }

    func testMultipleRootsResolveIndependentlyWithoutBroadeningAuthority() throws {
        let store = makeStore()
        let folderA = try makeDirectory("allowed-a")
        let folderB = try makeDirectory("allowed-b")
        let fileA = try makeFile("a.txt", in: folderA)
        let fileB = try makeFile("b.txt", in: folderB)
        let outside = try makeDirectory("not-allowed")
        let fileOutside = try makeFile("c.txt", in: outside)
        try store.addGrant(for: folderA)
        try store.addGrant(for: folderB)
        let resolver = AllowedFolderGrantResolver(store: store)

        let accessA = try resolver.resolveAccess(forRequestedPath: fileA.path)
        accessA.release()
        let accessB = try resolver.resolveAccess(forRequestedPath: fileB.path)
        accessB.release()
        XCTAssertThrowsError(try resolver.resolveAccess(forRequestedPath: fileOutside.path))
    }

    func testSecurityScopeAcquisitionAndReleaseIsBalanced() throws {
        let store = makeStore()
        let folder = try makeDirectory("allowed")
        let file = try makeFile("note.txt", in: folder)
        try store.addGrant(for: folder)
        let resolver = AllowedFolderGrantResolver(store: store)

        // Resolving and releasing repeatedly must not leak or crash. This is a coarse
        // balance check: `MessagesAttachmentAccess` itself only calls `stop` when `start`
        // reported true, so double-releasing or resolving many times must stay inert.
        for _ in 0 ..< 5 {
            let access = try resolver.resolveAccess(forRequestedPath: file.path)
            access.release()
        }
    }

    // MARK: - Broken grants

    private struct FakeAllowedFolderGrantStore: AllowedFolderGrantStoring {
        var grants: [AllowedFolderGrant]
        let onRefresh: (@Sendable (UUID, Data) -> Void)?

        func listGrants() -> [AllowedFolderGrant] { grants }
        func addGrant(for url: URL) throws -> AllowedFolderGrant {
            fatalError("not used")
        }
        func removeGrant(id: UUID) {}
        func replaceGrant(id: UUID, with url: URL) throws -> AllowedFolderGrant {
            fatalError("not used")
        }
        func refreshBookmark(id: UUID, bookmarkData: Data) {
            onRefresh?(id, bookmarkData)
        }
    }

    func testUnresolvableBookmarkIsReportedBrokenNotDropped() throws {
        let brokenGrant = AllowedFolderGrant(
            id: UUID(),
            displayName: "Broken",
            bookmarkData: Data([0x00, 0x01, 0x02, 0x03])
        )
        let store = FakeAllowedFolderGrantStore(grants: [brokenGrant], onRefresh: nil)
        let resolver = AllowedFolderGrantResolver(store: store)

        let resolved = resolver.resolvedGrants()
        XCTAssertEqual(resolved.count, 1)
        guard case .broken(let grant) = resolved.first else {
            return XCTFail("Expected a broken grant")
        }
        XCTAssertEqual(grant.id, brokenGrant.id)
    }

    func testAccessSkipsABrokenGrantAndFailsClosedWhenNoOtherGrantCovers() throws {
        let brokenGrant = AllowedFolderGrant(
            id: UUID(),
            displayName: "Broken",
            bookmarkData: Data([0x00, 0x01, 0x02, 0x03])
        )
        let store = FakeAllowedFolderGrantStore(grants: [brokenGrant], onRefresh: nil)
        let resolver = AllowedFolderGrantResolver(store: store)

        XCTAssertThrowsError(try resolver.resolveAccess(forRequestedPath: "/tmp/anything.txt")) {
            error in
            XCTAssertEqual(error as? MessagesAttachmentSourceError, .pathNotAllowed)
        }
    }

    func testBrokenGrantNeverAttemptsARefresh() throws {
        var refreshCalled = false
        let brokenGrant = AllowedFolderGrant(
            id: UUID(),
            displayName: "Broken",
            bookmarkData: Data([0x00, 0x01, 0x02, 0x03])
        )
        let store = FakeAllowedFolderGrantStore(
            grants: [brokenGrant],
            onRefresh: { _, _ in refreshCalled = true }
        )
        let resolver = AllowedFolderGrantResolver(store: store)

        _ = resolver.resolvedGrants()
        XCTAssertFalse(refreshCalled, "a bookmark that never resolved has nothing to refresh")
    }
}

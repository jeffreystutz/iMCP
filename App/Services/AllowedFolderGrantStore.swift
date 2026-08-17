import Foundation

/// One persistent user-approved folder root that authorizes filesystem-source Messages
/// attachments.
///
/// This is a distinct product concept from the existing Messages database directory
/// bookmark and must never share its storage key or be overwritten by it. iMCP only ever
/// needs read authority to a caller-owned attachment folder.
struct AllowedFolderGrant: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
}

/// One configured grant, resolved to a live URL, or reported broken.
///
/// A grant is `.broken` when its bookmark cannot be resolved at all — moved, deleted, or
/// revoked authority — and needs explicit reauthorization. It is never silently dropped.
enum ResolvedAllowedFolderGrant: Sendable {
    case available(grant: AllowedFolderGrant, url: URL)
    case broken(grant: AllowedFolderGrant)

    var grant: AllowedFolderGrant {
        switch self {
        case .available(let grant, _): return grant
        case .broken(let grant): return grant
        }
    }
}

enum AllowedFolderGrantError: LocalizedError, Equatable, Sendable {
    case grantNotFound
    case bookmarkCreationFailed

    var errorDescription: String? {
        switch self {
        case .grantNotFound:
            return "That allowed folder no longer exists."
        case .bookmarkCreationFailed:
            return "iMCP could not save access to that folder."
        }
    }
}

/// Persistence and lifecycle for allowed-folder grants. A protocol seam so the send
/// pipeline, the resolver, and Settings can all be exercised without AppKit or real
/// bookmarks in tests.
protocol AllowedFolderGrantStoring: Sendable {
    func listGrants() -> [AllowedFolderGrant]

    /// Adds a folder the user just selected. Deduplicates against any existing grant whose
    /// bookmark still resolves to the same standardized path, returning that grant instead
    /// of creating a second row.
    @discardableResult
    func addGrant(for url: URL) throws -> AllowedFolderGrant

    /// Deletes iMCP's persisted grant record only. Never deletes or modifies the user's
    /// folder or its files.
    func removeGrant(id: UUID)

    /// Replaces one grant's bookmark in place (same `id`, so its Settings row identity is
    /// stable), for explicit user-driven reauthorization of a broken grant.
    @discardableResult
    func replaceGrant(id: UUID, with url: URL) throws -> AllowedFolderGrant

    /// Refreshes a merely-stale-but-still-resolvable bookmark's on-disk data in place. This
    /// acquires no new authority, so it may run automatically outside explicit user action.
    func refreshBookmark(id: UUID, bookmarkData: Data)
}

/// `UserDefaults`-backed grant persistence, following the same bookmark-creation
/// conventions as the existing Messages database directory bookmark
/// (`MessageService.readOnlySecurityScopedBookmarkOptions`), under its own storage key.
/// `UserDefaults` is documented thread-safe, but Foundation's `UserDefaults` does not itself
/// conform to `Sendable` at this SDK version, so this class opts out of automatic checking
/// rather than storing no reference to it at all (unlike `MessagesSendingMode.load(from:)`,
/// this store's dedup/replace operations need the same instance across calls).
///
/// `UserDefaults` being thread-safe does not make a load-modify-save sequence atomic, and
/// production creates more than one instance of this class over the same storage (Settings
/// and the send-side resolver each construct their own). Every public operation is therefore
/// a full transaction under one `static` lock shared by every instance, so a stale-bookmark
/// refresh from one instance can never interleave with, and silently undo, a remove or
/// replace from another. `unlockedLoadStored`/`unlockedSave` exist only to be called from
/// inside an already-held lock, so no operation here ever locks recursively.
final class UserDefaultsAllowedFolderGrantStore: AllowedFolderGrantStoring, @unchecked Sendable {

    static let defaultStorageKey = "me.mattt.iMCP.messagesAttachmentAllowedFolders.v1"

    /// Shared across every instance, not per-instance: two separately constructed stores
    /// over the same (or even different) storage key must still serialize against each
    /// other, since they may share the same underlying `UserDefaults` domain.
    private static let lock = NSLock()

    private struct StoredGrant: Codable {
        let id: UUID
        let displayName: String
        let bookmarkData: Data
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let bookmarkOptions: URL.BookmarkCreationOptions

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = UserDefaultsAllowedFolderGrantStore.defaultStorageKey,
        bookmarkOptions: URL.BookmarkCreationOptions = MessageService
            .readOnlySecurityScopedBookmarkOptions
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.bookmarkOptions = bookmarkOptions
    }

    func listGrants() -> [AllowedFolderGrant] {
        Self.lock.withLock {
            unlockedLoadStored().map(Self.grant(from:))
        }
    }

    @discardableResult
    func addGrant(for url: URL) throws -> AllowedFolderGrant {
        let standardizedNewPath = url.standardizedFileURL.path
        return try Self.lock.withLock {
            var stored = unlockedLoadStored()

            if let existing = stored.first(where: { candidate in
                guard let resolvedURL = try? AllowedFolderBookmark.resolve(candidate.bookmarkData)
                else { return false }
                return resolvedURL.standardizedFileURL.path == standardizedNewPath
            }) {
                return Self.grant(from: existing)
            }

            let bookmarkData = try Self.makeBookmark(for: url, options: bookmarkOptions)
            let record = StoredGrant(
                id: UUID(),
                displayName: url.lastPathComponent,
                bookmarkData: bookmarkData
            )
            stored.append(record)
            unlockedSave(stored)
            return Self.grant(from: record)
        }
    }

    func removeGrant(id: UUID) {
        Self.lock.withLock {
            var stored = unlockedLoadStored()
            stored.removeAll { $0.id == id }
            unlockedSave(stored)
        }
    }

    @discardableResult
    func replaceGrant(id: UUID, with url: URL) throws -> AllowedFolderGrant {
        try Self.lock.withLock {
            var stored = unlockedLoadStored()
            guard let index = stored.firstIndex(where: { $0.id == id }) else {
                throw AllowedFolderGrantError.grantNotFound
            }
            let bookmarkData = try Self.makeBookmark(for: url, options: bookmarkOptions)
            let record = StoredGrant(
                id: id,
                displayName: url.lastPathComponent,
                bookmarkData: bookmarkData
            )
            stored[index] = record
            unlockedSave(stored)
            return Self.grant(from: record)
        }
    }

    func refreshBookmark(id: UUID, bookmarkData: Data) {
        Self.lock.withLock {
            var stored = unlockedLoadStored()
            guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
            stored[index] = StoredGrant(
                id: id,
                displayName: stored[index].displayName,
                bookmarkData: bookmarkData
            )
            unlockedSave(stored)
        }
    }

    private static func makeBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions
    ) throws -> Data {
        do {
            return try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw AllowedFolderGrantError.bookmarkCreationFailed
        }
    }

    private static func grant(from stored: StoredGrant) -> AllowedFolderGrant {
        AllowedFolderGrant(
            id: stored.id,
            displayName: stored.displayName,
            bookmarkData: stored.bookmarkData
        )
    }

    /// Must only be called while `Self.lock` is held.
    private func unlockedLoadStored() -> [StoredGrant] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([StoredGrant].self, from: data)) ?? []
    }

    /// Must only be called while `Self.lock` is held.
    private func unlockedSave(_ grants: [StoredGrant]) {
        guard let data = try? JSONEncoder().encode(grants) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Shared bookmark-resolution helper so the store and the resolver decode identically.
enum AllowedFolderBookmark {
    static func resolveWithStaleness(_ bookmarkData: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    static func resolve(_ bookmarkData: Data) throws -> URL {
        try resolveWithStaleness(bookmarkData).url
    }
}

// MARK: - Resolution and containment

/// Holds the security scope for one filesystem-source attachment access window.
///
/// The scope is held on the granted **root** directory, which recursively authorizes every
/// descendant path underneath it regardless of how the leaf `URL` was constructed. `fileURL`
/// is the exact, unresolved URL for the requested path — handed to
/// `MessagesAttachmentValidating` unchanged so its own symlink/alias/package detection still
/// applies to the requested leaf, exactly as it does for every other attachment source.
struct AllowedFolderFileAccess: Sendable {
    let fileURL: URL
    private let rootAccess: MessagesAttachmentAccess
    /// Test seam only: production never supplies this. `MessagesAttachmentAccess.release()`
    /// is a silent no-op for an unbookmarked URL (the common case in tests), which makes
    /// "was `release()` actually called" otherwise unobservable from outside this type.
    private let onRelease: (@Sendable () -> Void)?

    init(
        fileURL: URL,
        rootAccess: MessagesAttachmentAccess,
        onRelease: (@Sendable () -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.rootAccess = rootAccess
        self.onRelease = onRelease
    }

    func release() {
        rootAccess.release()
        onRelease?()
    }
}

/// Resolves a requested absolute path against configured allowed-folder authority, and
/// reports live grant state for Settings.
protocol AllowedFolderGrantResolving: Sendable {
    /// Live, resolved state of every configured grant, for Settings display. Never throws:
    /// an unresolvable grant is reported `.broken`, not dropped.
    func resolvedGrants() -> [ResolvedAllowedFolderGrant]

    /// Resolves one requested absolute path against every configured grant's authority.
    ///
    /// Throws `MessagesAttachmentSourceError.invalidFilePath` for a non-absolute path, or
    /// `.pathNotAllowed` when no configured grant's root contains the resolved real path.
    /// The caller must call `release()` on the returned access exactly once, on every exit
    /// path.
    func resolveAccess(forRequestedPath path: String) throws -> AllowedFolderFileAccess
}

/// The default `AllowedFolderGrantResolving` implementation: path-component-aware
/// containment against every configured grant, with symlink-escape detection.
///
/// Containment is checked twice. First, lexically, against the requested path standardized
/// without following symlinks — this is what rejects `..` traversal and prefix-confusable
/// siblings (`/allowed-evil` is not contained by `/allowed`). Second, after opening the
/// root's security scope, against the symlink-resolved real path — this is what rejects an
/// intermediate path component that is itself a symlink escaping the granted tree. The
/// second check cannot run before the scope is open, because resolving symlinks inside a
/// sandboxed directory requires read authority on that directory.
final class AllowedFolderGrantResolver: AllowedFolderGrantResolving {
    private let store: any AllowedFolderGrantStoring

    init(store: any AllowedFolderGrantStoring) {
        self.store = store
    }

    func resolvedGrants() -> [ResolvedAllowedFolderGrant] {
        store.listGrants().map { grant in
            guard let resolved = try? resolveRoot(for: grant) else {
                return .broken(grant: grant)
            }
            return .available(grant: grant, url: resolved)
        }
    }

    func resolveAccess(forRequestedPath path: String) throws -> AllowedFolderFileAccess {
        guard path.hasPrefix("/") else {
            throw MessagesAttachmentSourceError.invalidFilePath
        }
        let requestedURL = URL(fileURLWithPath: path)
        let standardizedRequested = requestedURL.standardizedFileURL

        for grant in store.listGrants() {
            guard let rootURL = try? resolveRoot(for: grant) else { continue }
            let standardizedRoot = rootURL.standardizedFileURL
            guard Self.isContained(standardizedRequested, in: standardizedRoot) else {
                continue
            }

            let access = MessagesAttachmentAccess(url: rootURL)
            let resolvedRealRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
            let resolvedRealRequested =
                requestedURL.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolvedRealRequested, in: resolvedRealRoot) else {
                access.release()
                continue
            }

            return AllowedFolderFileAccess(fileURL: requestedURL, rootAccess: access)
        }

        throw MessagesAttachmentSourceError.pathNotAllowed
    }

    /// Resolves one grant's bookmark, transparently refreshing a merely-stale-but-still-
    /// resolvable bookmark's on-disk data. Refreshing acquires no new authority — it only
    /// keeps the existing token current — so it may happen outside explicit user action.
    /// A bookmark that fails to resolve at all propagates as broken.
    private func resolveRoot(for grant: AllowedFolderGrant) throws -> URL {
        let (url, isStale) = try AllowedFolderBookmark.resolveWithStaleness(grant.bookmarkData)
        if isStale,
            let refreshed = try? url.bookmarkData(
                options: MessageService.readOnlySecurityScopedBookmarkOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        {
            store.refreshBookmark(id: grant.id, bookmarkData: refreshed)
        }
        return url
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

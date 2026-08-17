import AppKit
import Foundation
import UniformTypeIdentifiers

/// The inclusive upper bound on one attachment, in bytes (25 MiB).
///
/// This is an iMCP safety limit that keeps one submission bounded and reviewable. It is
/// not a claim that every Messages transport accepts a file of that size.
let maximumMessagesAttachmentByteSize = 26_214_400

/// Everything iMCP keeps about the selected file.
///
/// These are exactly the facts needed to authorize one submission and to detect that the
/// file changed between authorization and dispatch. Nothing here is persisted, no
/// attachment bookmark is created, and none of it may reach a log, an error, or a result.
struct MessagesAttachmentFacts: Equatable, Sendable {
    let url: URL
    let displayName: String
    let byteSize: Int
    let contentType: UTType
    /// The file system's identity for this file, when the volume supplies one. It is what
    /// distinguishes an unchanged file from a different file put in its place.
    let resourceIdentifier: UInt64?
    let modificationDate: Date?

    /// A public type description for the authorization surface only.
    var typeDescription: String {
        contentType.localizedDescription ?? contentType.identifier
    }

    /// A formatted size for the authorization surface only.
    var formattedSize: String {
        Int64(byteSize).formatted(.byteCount(style: .file))
    }
}

/// Categorical attachment failures.
///
/// None of these carries the selected path, name, type, size, or any underlying
/// filesystem error text. A rejected value is still a private value, and upper layers may
/// put an error description in front of the model.
enum MessagesAttachmentError: LocalizedError, Equatable, Sendable {
    case unreadableSelection
    case notRegularFile
    case emptyFile
    case fileTooLarge
    case unsupportedType
    case attachmentChanged

    var errorDescription: String? {
        switch self {
        case .unreadableSelection:
            return "The selected item could not be read. Nothing was sent."
        case .notRegularFile:
            return
                "An attachment must be one ordinary file. Folders, packages, bundles, aliases, and symbolic links are not supported. Nothing was sent."
        case .emptyFile:
            return "An empty file cannot be attached. Nothing was sent."
        case .fileTooLarge:
            return "An attachment must be 25 MiB or smaller. Nothing was sent."
        case .unsupportedType:
            return
                "An attachment must be an image, video or audio, PDF, or plain-text file. Nothing was sent."
        case .attachmentChanged:
            return
                "The selected file changed after it was confirmed, so the confirmation no longer describes it. Nothing was sent."
        }
    }
}

/// Reads the bounded facts about a selected file and rejects everything outside policy.
///
/// It runs once before the final confirmation and again immediately before dispatch, so
/// it must be a pure read: it opens no file, changes nothing, and reports only categories.
protocol MessagesAttachmentValidating: Sendable {
    func validate(_ url: URL) throws -> MessagesAttachmentFacts
}

/// The file system edge of attachment validation.
struct FileManagerMessagesAttachmentValidator: MessagesAttachmentValidating {
    /// The public Uniform Type Identifier categories an attachment may belong to.
    ///
    /// Membership is by conformance, so concrete types such as JPEG, MPEG-4, or a source
    /// file are covered by their public supertype. Anything outside these categories —
    /// including unknown generic `public.data` and dynamic types — fails.
    static let supportedTypes: [UTType] = [.image, .audiovisualContent, .pdf, .plainText]

    /// Categories that are refused even when something also claims a supported category.
    static let rejectedTypes: [UTType] = [
        .executable, .unixExecutable, .application, .applicationBundle, .archive, .diskImage,
        .symbolicLink, .aliasFile, .package, .directory,
    ]

    private static let requiredKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isAliasFileKey,
        .isExecutableKey, .fileSizeKey, .contentTypeKey, .nameKey, .contentModificationDateKey,
        .fileIdentifierKey,
    ]

    func validate(_ url: URL) throws -> MessagesAttachmentFacts {
        // A URL caches every resource value it has already been asked for, and the
        // post-confirmation re-read asks the same URL again. Without dropping that cache
        // the second read would replay the first one's answers, and a file that was
        // removed, replaced, modified, or enlarged after the user authorized it would
        // pass revalidation unnoticed. Every read here must reach the file system.
        var url = url
        url.removeAllCachedResourceValues()

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.requiredKeys)
        } catch {
            // The underlying error names the path and the filesystem condition, so it is
            // deliberately dropped rather than wrapped.
            throw MessagesAttachmentError.unreadableSelection
        }

        // One ordinary regular file. A missing answer is treated as a failure, not as
        // permission: every structural question must be answered "no" explicitly.
        guard values.isSymbolicLink != true,
            values.isAliasFile != true,
            values.isDirectory != true,
            values.isPackage != true,
            values.isRegularFile == true
        else { throw MessagesAttachmentError.notRegularFile }

        guard let contentType = values.contentType else {
            throw MessagesAttachmentError.unsupportedType
        }
        guard !Self.rejectedTypes.contains(where: contentType.conforms(to:)),
            Self.supportedTypes.contains(where: contentType.conforms(to:)),
            values.isExecutable != true
        else { throw MessagesAttachmentError.unsupportedType }

        guard let byteSize = values.fileSize else {
            throw MessagesAttachmentError.unreadableSelection
        }
        guard byteSize > 0 else { throw MessagesAttachmentError.emptyFile }
        // The bound is inclusive: exactly 25 MiB is accepted.
        guard byteSize <= maximumMessagesAttachmentByteSize else {
            throw MessagesAttachmentError.fileTooLarge
        }

        return MessagesAttachmentFacts(
            url: url,
            displayName: values.name ?? url.lastPathComponent,
            byteSize: byteSize,
            contentType: contentType,
            resourceIdentifier: values.fileIdentifier,
            modificationDate: values.contentModificationDate
        )
    }
}

/// Holds sandbox read access to one selected attachment for exactly the window between
/// validation and synchronous Apple Event submission.
///
/// A URL vended by the open panel is already reachable without an explicit scope, so
/// `startAccessingSecurityScopedResource()` answering false is normal rather than a
/// failure. Only a call that answered true may be balanced by a stop.
struct MessagesAttachmentAccess: Sendable {
    private let url: URL
    private let isScoped: Bool

    init(url: URL) {
        self.url = url
        self.isScoped = url.startAccessingSecurityScopedResource()
    }

    func release() {
        guard isScoped else { return }
        url.stopAccessingSecurityScopedResource()
    }
}

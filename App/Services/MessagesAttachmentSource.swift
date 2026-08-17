import Foundation
import MCP

/// The provisional inclusive upper bound on one serialized (base64) attachment's *decoded*
/// content, in bytes (5 MiB).
///
/// This is deliberately lower than `maximumMessagesAttachmentByteSize` (the 25 MiB
/// filesystem-source bound). It is an explicit, adjustable safety constant pending
/// intended-client acceptance, not a generalization of the filesystem bound to base64 JSON.
let maximumSerializedAttachmentByteSize = 5_242_880

/// Which of the two legal `message_send_attachment` sources a call supplied.
///
/// Exactly one form is legal per call. Parsing this is a pure, synchronous step with no
/// filesystem or authorization side effects, mirroring `SendDestination` parsing.
enum AttachmentSourceInput: Equatable, Sendable {
    /// An absolute path that must resolve within at least one persistent user-approved
    /// folder. The path itself is not authority; `AllowedFolderGrantResolving` decides that.
    case filesystem(path: String)
    /// A safe filename plus bounded base64-encoded bytes, to be staged into app-owned
    /// temporary storage.
    case serialized(filename: String, contentBase64: String)
}

/// Categorical attachment-**source** failures: which legal form was supplied, and whether a
/// filesystem path is currently authorized.
///
/// None of these carries the supplied path, filename, or byte length. A rejected value is
/// still a private value.
enum MessagesAttachmentSourceError: LocalizedError, Equatable, Sendable {
    case missingSource
    case conflictingSource
    case incompleteSerializedSource
    case invalidFilePath
    case invalidFilename
    case invalidContentBase64
    case serializedContentTooLarge
    case pathNotAllowed
    case stagingFailed

    var errorDescription: String? {
        switch self {
        case .missingSource:
            return
                "An attachment source is required: file_path, or filename and content_base64. Nothing was sent."
        case .conflictingSource:
            return
                "Supply only one attachment source per call: file_path, or filename and content_base64, not both. Nothing was sent."
        case .incompleteSerializedSource:
            return
                "A serialized attachment requires both filename and content_base64, supplied as text. Nothing was sent."
        case .invalidFilePath:
            return "file_path must be an absolute path to one file. Nothing was sent."
        case .invalidFilename:
            return
                "filename must be a plain file name with no path separators or traversal segments. Nothing was sent."
        case .invalidContentBase64:
            return "content_base64 could not be decoded as base64. Nothing was sent."
        case .serializedContentTooLarge:
            return
                "A serialized attachment must decode to 5 MiB or smaller. Nothing was sent."
        case .pathNotAllowed:
            return
                "file_path is not inside a folder you have allowed. Add the containing folder in iMCP Settings, under Attachments \u{2192} Files on this Mac, then try again. Nothing was sent."
        case .stagingFailed:
            return "iMCP could not prepare the attachment for sending. Nothing was sent."
        }
    }
}

/// Normalizes a raw source-selector argument for exclusivity counting.
///
/// A blank or whitespace-only scalar string is omission-equivalent to an absent argument —
/// the kind of empty optional field a form client may submit untouched — matching the same
/// principle already accepted for destination selectors. Every other present value still
/// counts as supplied, including a non-string scalar: that remains malformed input for the
/// field's own parser to reject, not an omission.
private func attachmentSourceMeaningfulValue(_ value: Value?) -> Value? {
    guard let value else { return nil }
    if let scalar = value.stringValue,
        scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        return nil
    }
    return value
}

/// Parses `message_send_attachment`'s source arguments: exactly one of a filesystem
/// `file_path`, or a serialized `filename` + `content_base64` pair.
///
/// This runs synchronously alongside destination parsing, before any I/O, so malformed or
/// conflicting source input fails before the destination is even resolved.
func resolveAttachmentSource(_ arguments: [String: Value]) throws -> AttachmentSourceInput {
    let filePathValue = attachmentSourceMeaningfulValue(arguments["file_path"])
    let filenameValue = attachmentSourceMeaningfulValue(arguments["filename"])
    let contentBase64Value = attachmentSourceMeaningfulValue(arguments["content_base64"])

    let hasFilesystemSource = filePathValue != nil
    let hasSerializedField = filenameValue != nil || contentBase64Value != nil

    guard !(hasFilesystemSource && hasSerializedField) else {
        throw MessagesAttachmentSourceError.conflictingSource
    }

    if hasFilesystemSource {
        guard let filePath = filePathValue?.stringValue, filePath.hasPrefix("/") else {
            throw MessagesAttachmentSourceError.invalidFilePath
        }
        return .filesystem(path: filePath)
    }

    if hasSerializedField {
        guard let filename = filenameValue?.stringValue,
            let contentBase64 = contentBase64Value?.stringValue
        else {
            throw MessagesAttachmentSourceError.incompleteSerializedSource
        }
        return .serialized(filename: filename, contentBase64: contentBase64)
    }

    throw MessagesAttachmentSourceError.missingSource
}

/// Validates a serialized attachment's `filename`: a plain file name only, never a path.
///
/// Rejects path separators, `..`/`.` traversal segments, and empty/whitespace-only names,
/// so the staged temporary file can never land outside its app-owned directory and never
/// silently collide with `.`/`..`.
func validateSerializedAttachmentFilename(_ filename: String) throws -> String {
    let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
        !trimmed.contains("/"),
        !trimmed.contains(":"),
        trimmed != ".",
        trimmed != ".."
    else {
        throw MessagesAttachmentSourceError.invalidFilename
    }
    return trimmed
}

/// Decodes bounded base64 content for a serialized attachment.
///
/// The encoded length is checked before decoding so that oversized input is rejected
/// without first performing the decode: base64 expands to roughly 4/3 of decoded size, so an
/// encoded string that could not possibly decode within the provisional 5 MiB cap is
/// rejected up front rather than only after allocating the decoded buffer.
func decodeSerializedAttachmentContent(_ contentBase64: String) throws -> Data {
    // Every 4 encoded characters produce at most 3 decoded bytes, so this is a safe upper
    // bound on decoded size before any decoding work happens.
    let maximumPossibleEncodedLength = ((maximumSerializedAttachmentByteSize + 2) / 3) * 4
    guard contentBase64.utf8.count <= maximumPossibleEncodedLength else {
        throw MessagesAttachmentSourceError.serializedContentTooLarge
    }
    guard let data = Data(base64Encoded: contentBase64) else {
        throw MessagesAttachmentSourceError.invalidContentBase64
    }
    guard data.count <= maximumSerializedAttachmentByteSize else {
        throw MessagesAttachmentSourceError.serializedContentTooLarge
    }
    return data
}

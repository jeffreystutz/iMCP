# ADR 0009: Attachment-only submission to an existing conversation

- Status: Proposed
- Date: 2026-08-14
- Deciders: iMCP maintainers
- Supersedes:
- Superseded by:

## Context

`messages_send` submits plain text to one exact existing conversation, or hands a
verified-new recipient to system-owned composition (ADR 0002, ADR 0006). It cannot
send a file.

The installed scripting definition at
`/System/Applications/Messages.app/Contents/Resources/Messages.sdef` documents
`send` with a **single** direct parameter typed as either `file` or `text`,
targeted `to` a participant or a chat. Foundation supplies
`NSAppleEventDescriptor(fileURL:)`, a typed file-URL descriptor.

Two consequences follow directly from that dictionary. A file and a caption cannot
be one submission, because each `send` carries exactly one direct parameter. And a
file can address an existing chat, which `NSSharingService` cannot do — the
sharing composer picks its own destination, so it is not a route to a *chosen*
conversation.

A file also introduces a class of input the existing send path never had: a
filesystem object with a path, a size, a type, and an identity that can all change
between authorization and dispatch.

## Decision drivers

- Preserve the one-dispatch, no-retry, fail-closed existing-chat architecture.
- Keep AppleScript source fixed; untrusted values enter only as descriptors.
- Never put a private path, filename, or file content in an MCP argument, log,
  error, or result.
- Authorize what is actually submitted, and keep that authorization truthful up to
  the moment of dispatch.
- Keep App Sandbox and public APIs; add no entitlement.
- Never claim delivery from submission.

## Options considered

### Extend `messages_send` with an optional file parameter

Rejected. A file plus a body would be two `send` dispatches for one approved call,
which breaks the one-dispatch invariant outright. It would also give the text tool
a file surface, so a caller could reach the filesystem through the tool that is
documented as text-only.

### Accept a path or file bytes as an MCP argument

Rejected. A path in a tool argument is a private value that the model has read and
may echo, and it lets a caller name any file the app can reach. Bytes are worse:
they move file content through the transcript. Neither is necessary, because macOS
already has a consent mechanism for exactly this.

### Reuse `NSSharingService` for attachments

Rejected for this slice. The sharing composer does not select a specific existing
chat, so it cannot honor a destination the caller resolved. It remains the natural
home for a *verified-new-recipient* attachment later, where its editable,
human-completed semantics are the point.

### A separate attachment-only tool with a native picker

Selected.

## Decision

Add `messages_send_attachment`, separate from `messages_send`, submitting exactly
one file to one exact **existing** conversation. It has no caption, no body, no
multiple files, and no new-recipient composition.

Its destination selectors are identical to `messages_send` — one `recipient`, the
complete exact `recipients` set for one existing group, or one opaque `chat_id`,
exactly one required — and resolution, ambiguity, staleness, and addressability
semantics are shared code, not a parallel implementation. A recipient *verified*
to have no existing conversation fails categorically here rather than opening the
sharing composer, because silently switching to a composer would change the
destination the caller asked for.

The tool accepts **no path, URL, filename, bytes, body, or attachment identifier**.
After the destination resolves, iMCP presents a native single-file `NSOpenPanel`.
The human's selection in that panel is what grants sandbox read access, so the
private path never enters the MCP request. The picker and the validator sit behind
`MessagesAttachmentSelecting` and `MessagesAttachmentValidating` and are injected
into `MessageService`, so tests present no UI.

### Bounded file policy

Exactly one ordinary, nonempty regular file of at most 25 MiB (26,214,400 bytes,
inclusive). Directories, packages, bundles, symbolic links, aliases, and
executables are rejected. Public Uniform Type Identifiers must classify it as
image, audiovisual content, PDF, or plain text; unknown generic `public.data`,
dynamic types, archives, disk images, and applications fail. Checks run
structural, then type, then size, so the reported category is the most useful one.
The bound is an iMCP safety limit, not a claim about what a transport accepts.

Only in-memory facts are kept: URL, display name, byte size, content type,
resource identifier when the volume supplies one, and modification date when
available. **No attachment bookmark is persisted.** Security-scoped access is held
from validation through the synchronous Apple Event and then released.

### Ordering

1. Resolve the destination to one exact existing conversation.
2. If Automation is already authorized, run the existing non-prompting
   addressability preflight; otherwise do not prompt.
3. Present the picker and validate the selection.
4. Request one immutable final confirmation through the existing router, showing
   the exact conversation plus the attachment's display name, public type
   description, and formatted size — never its path or contents. The wording
   authorizes an attachment submission and states that no message text is sent.
5. Re-resolve the destination and require exact equality with what was shown.
6. Re-read the file facts and require the same identity and unchanged bounded
   properties. Removed, replaced, modified, enlarged, or newly unsupported fails
   with zero dispatch.
7. Only now request Automation if needed and recheck addressability.
8. Dispatch exactly once.

Cancellation or failure before dispatch means nothing was sent. An error once
dispatch has begun uses the existing ambiguous-submission semantics and is
terminal. There is no retry, queue, alternate conversation, sharing-service
fallback, path fallback, or second dispatch.

### Public mechanism

The fixed script gains `submitChatAttachment(chatGUID, attachmentFile)`, repeating
the same zero/one/many exact-chat checks as the text handler and issuing one
`send attachmentFile to item 1 of targetChats`. The chat GUID remains a string
descriptor; the file is `NSAppleEventDescriptor(fileURL:)`, never a path string.
Apple Event arguments are now typed descriptors throughout rather than strings.
Main-actor serialization and permission sequencing are unchanged.

### Privacy

Production logs carry only categorical destination shape. No destination, chat ID,
path, filename, type identifier, size, content, descriptor argument, or underlying
filesystem error text appears in logs, errors, or results. Caller-visible errors
are categorical and omit the rejected value. The picker and the final confirmation
may show name, type, and size, because they are the authorization surface. The
result reuses the redacted submission status with `mode: attachment` and carries no
file facts. Success means Messages accepted one attachment submission, never that
it was delivered.

## Rationale

The separation is forced by the scripting dictionary rather than chosen for taste:
one direct parameter per `send` means file-plus-caption is two dispatches, and two
dispatches for one approval is precisely what the architecture forbids. Given the
split, the picker is what makes the rest safe — it is the one design where the
human grants access to a specific file, the model never learns its path, and the
sandbox grant is scoped to the thing the human pointed at.

Re-reading the file after confirmation is not defensive noise. The gap between
authorization and dispatch is real, and a file is mutable in ways a string body is
not, so the confirmation is only truthful if the thing dispatched is still the
thing described.

## Consequences

### Positive

- Attachments reach a chosen existing conversation, which sharing cannot address.
- No private path or file content enters an MCP argument, log, error, or result.
- The one-dispatch, no-retry, fail-closed guarantees are unchanged.
- No new entitlement and no new TCC grant; the existing user-selected-file
  consent already covers a picker selection.
- `messages_send` is untouched and gains no file surface.

### Negative

- Sending an attachment requires a person at the machine to choose the file.
- A caption needs a separate `messages_send` call, which is a second approval.
- A verified-new recipient cannot receive an attachment in this slice.
- The 25 MiB bound may be stricter than a given transport would allow.

### Risks and mitigations

- **Stale authorization.** A file can change while the confirmation is on screen.
  Both the destination and the full file facts are revalidated after acceptance,
  and any difference fails before any permission request or dispatch.
- **Cached filesystem answers.** `URL` caches resource values, so a naive second
  read replays the first one's answers and would miss a swapped or deleted file
  entirely. The validator drops the cache before every read; tests that replace,
  modify, enlarge, and remove the file after confirmation fail without that fix.
- **File identity.** Size and modification date alone do not distinguish a
  replacement, so the file's resource identifier is compared too when the volume
  supplies one.
- **Path leakage.** The path exists only inside the app; tests assert it is absent
  from the schema, confirmation text, errors, and result.
- **Route substitution.** A verified-new recipient fails rather than silently
  reaching the sharing composer, and tests assert zero compositions.
- **Duplicate submission.** A post-dispatch error stays ambiguous and terminal;
  tests assert exactly one dispatch and no retry, text fallback, or composition.

## Validation

Automated tests cover the tool schema and annotations and the absence of any path
or body parameter; destination exclusivity and exact matching; verified-new
rejection with no composer, picker, or dispatch; picker cancellation; empty,
oversize, directory, package, application, symlink, executable, unknown, archive,
disk-image, and otherwise unsupported rejection; the supported categories; one byte
and exactly 25 MiB accepted with 25 MiB + 1 rejected; no Automation prompt before
the final confirmation; confirmation content including destination, name, type, and
size and excluding the path; decline, cancel, malformed, and native cancellation
reaching zero dispatch; post-confirmation destination and file revalidation
including removed, replaced-with-identical-properties, modified, enlarged, and
type-changed; the fixed script and typed file descriptor without executing a real
Apple Event; one dispatch maximum with no retry or fallback on ambiguous failure;
and redacted errors, results, and loggable facts.

No real Apple Event was executed, no real Contacts or Messages data was read, and
no attachment was sent. All fixtures are synthetic temporary files.

Manual acceptance selects a synthetic supported file and cancels at the final
confirmation, proving file access and authorization with no send. Any real
attachment send requires separate explicit authorization of the exact file and the
exact destination.

## References

- ADR 0002, for the existing-conversation automation boundary this extends
- ADR 0006, for the new-recipient composition path this deliberately does not use
- `/System/Applications/Messages.app/Contents/Resources/Messages.sdef`, `send`
- Foundation `NSAppleEventDescriptor(fileURL:)`
- `URL.removeAllCachedResourceValues()` and `URLResourceKey.fileIdentifierKey`

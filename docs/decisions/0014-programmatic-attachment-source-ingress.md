# ADR 0014: Programmatic attachment source ingress

- Status: Proposed
- Date: 2026-08-17
- Deciders: iMCP maintainers (user)
- Supersedes: ADR 0009 (its mandatory-native-picker ingress mechanism only; see "What this does not change")
- Superseded by:

## Context

ADR 0009 introduced `messages_send_attachment` (now `message_send_attachment`,
ADR 0012/0013) with a mandatory native `NSOpenPanel` as the only attachment
source: the tool accepted no path, URL, filename, or bytes, and the human's
selection in that panel was what granted sandbox read access. That picker
was always explicitly a proof of the downstream existing-chat attachment
pipeline, not accepted final product ingress — `docs/messages-write-plan.md`
and Hexa project knowledge (`imessage-mcp/attachment-sending-design`) have
recorded this since ADR 0009 shipped.

Requiring a person at the keyboard for every attachment defeats the purpose
of an MCP tool an unattended client can call. The user's settled product
direction (`imessage-mcp/current-status`, `imessage-mcp/attachment-sending-design`)
replaces the picker with exactly two programmatic sources: an absolute path
inside a persistent user-approved folder, or bounded serialized bytes the
MCP client supplies directly and iMCP stages itself. This record implements
that replacement.

## Decision drivers

- Ordinary tool execution must never open a picker; a picker belongs only in
  Settings, where the user deliberately grants a folder.
- The MCP caller must never be able to create filesystem authority itself: a
  `file_path` argument is not consent, so authority comes only from a
  persistent grant the user created through the standard macOS folder
  picker, exactly like the existing Messages database directory bookmark.
- Preserve the full ADR 0009 security/validation contract downstream of
  source resolution: bounded file policy, security-scoped access lifetime,
  destination/file revalidation immediately before dispatch, fixed-script
  typed-descriptor dispatch, one-dispatch/no-retry, privacy redaction, and
  submitted-not-delivered truthfulness. None of that is reopened here.
- Never let a serialized attachment's temporary bytes survive any exit path,
  and never let a filesystem source's caller-owned file be deleted, moved,
  or modified.
- Keep the public schema flat and exactly two mutually exclusive source
  forms, matching the destination selectors' existing "exactly one of"
  shape rather than inventing a nested union.

## Options considered

### Keep the picker as final ingress

Rejected. Already explicitly rejected as final product UX before this
record; an unattended MCP client cannot drive a modal panel, so this would
leave attachment sending permanently human-gated.

### Accept an arbitrary `file_path` with no persistent grant, prompting per call

Rejected. A per-call filesystem prompt is exactly the picker problem again,
just re-framed as a path argument with a just-in-time authorization dialog.
It would also make every call's authority implicit and un-auditable, unlike
a small, visible, user-managed Allowed Folders list.

### A single opaque "staging" concept: caller uploads bytes to a server-side root, addresses them by ID

Rejected. This adds a public root/grant/staging identifier and a delete
lifecycle the user explicitly does not want (`docs/project-prompts/current-task.md`:
"There is no `root`, grant ID, staging identifier, relative staging path,
picker argument, deletion parameter, or delete-after-send behavior"). It
also does not solve the filesystem case, which still needs a real path.

### Two flat, mutually exclusive sources: allowed-folder `file_path`, and staged `filename`/`content_base64`

Selected. This is the shape the settled product direction already
specifies. A filesystem source covers files already on the Mac without
requiring the client to read and re-encode them; a serialized source covers
a client that only has bytes, with no filesystem grant required at all.

## Decision

`message_send_attachment` accepts exactly one of:

- `file_path` — an absolute path that must resolve inside at least one
  folder the user has explicitly allowed in iMCP Settings under
  **Attachments → Files on this Mac**;
- `filename` + `content_base64` — a plain file name and bounded
  base64-encoded bytes, staged into app-owned temporary storage.

Source parsing (`resolveAttachmentSource`) runs synchronously alongside
destination parsing, before any I/O, mirroring `resolveDestination`'s
blank-scalar-omission rule: a blank optional source field is
omission-equivalent to absent for exclusivity counting only, never for
hiding a malformed or partially supplied value. Both forms meaningfully
supplied, one serialized field without the other, or neither form supplied,
all fail closed with a distinct categorical error
(`MessagesAttachmentSourceError`).

### Allowed-folder grants

A new, small persistence type, `AllowedFolderGrantStore`, holds a list of
`{id, displayName, bookmarkData}` records under its own `UserDefaults` key,
distinct from and never colliding with the existing Messages database
directory bookmark. Each bookmark is created with the same
`.withSecurityScope, .securityScopeAllowOnlyReadAccess` options and the same
`com.apple.security.files.bookmarks.app-scope` entitlement already declared
for the database bookmark — no entitlement changed for this record.

Adding the same folder twice deduplicates to the existing grant rather than
creating a duplicate row. Removing a grant deletes only iMCP's persisted
record; it never deletes or modifies the user's folder or files. A merely
stale-but-still-resolvable bookmark is refreshed transparently, since that
acquires no new authority; a bookmark that fails to resolve at all is
reported broken and requires the user to reauthorize it, replacing that same
grant's bookmark in place so its Settings row identity is stable.

### Containment

`AllowedFolderGrantResolver` resolves a requested `file_path` in two
containment passes:

1. Lexically, against every configured grant's root, standardized without
   following symlinks — this rejects `..` traversal and prefix-confusable
   siblings (`/allowed-evil` is not contained by `/allowed`), since
   containment compares path components, not string prefixes.
2. After the matching root's security scope opens, against the
   symlink-resolved real path — this rejects an interior symlink that is
   lexically inside the granted tree but whose target escapes it.

The **original, unresolved** request URL — never the symlink-resolved one —
is what reaches the existing, unchanged `FileManagerMessagesAttachmentValidator`,
so its own symlink/alias/package/directory rejection still applies to the
requested leaf exactly as it did to a picker-selected file. A path outside
every grant, or a grant that no longer resolves, fails with
`MessagesAttachmentSourceError.pathNotAllowed`, a privacy-safe error naming
no path and directing the user to Settings.

### Serialized staging

`filename` must be a plain name — no path separators, no `.`/`..`
traversal segment, non-empty after trimming. `content_base64` is decoded
under a provisional 5 MiB decoded-content cap, checked once on encoded
length (before decoding, so oversized input cannot force unbounded decode
work) and again on the actual decoded size. The decoded bytes are written,
with restrictive permissions, into a unique app-owned temporary directory
under `FileManager.default.temporaryDirectory`, then validated through the
same `FileManagerMessagesAttachmentValidator` used for every other source.
That temporary directory is removed on every exit path from the send
call — success, a declined or cancelled confirmation, validation failure,
revalidation failure, or a send/Automation failure — via a `defer`
installed immediately after staging. iMCP never touches a caller-owned
filesystem source: only its own staged temporary files are ever deleted.

### Pipeline

`sendAttachment`'s existing eight-step pipeline (ADR 0009) is unchanged
except that step 3 (picker + validate) becomes "resolve the source and
validate it," and step 6 (revalidate the file) becomes "revalidate the
source," which for a filesystem source re-checks allowed-folder containment
— not only the file's bounded properties — since a grant can be revoked
between confirmation and dispatch and a stale security scope must never be
trusted to still be authorized. Destination resolution, non-prompting
addressability preflight, the immutable confirmation (or the Send
Automatically skip of only that step), destination revalidation,
Automation/addressability recheck, and exactly one dispatch are byte-for-
byte the same shared code as before.

### Settings

An inline **Attachments** section is added to the existing single-section
Settings form (`GeneralSettingsView`): static copy stating serialized
attachments are always available with no folder access required, then an
inline **Allowed Folders** list under "Files on this Mac" with a direct
`Add Folder…` control (the standard folder picker, one directory, no
files, no intermediate menu), and per-row `Show in Finder`/remove/
`Reauthorize…` (for a broken grant) controls. There is no Manage screen and
no filesystem-access master toggle; removing the last folder naturally
disables filesystem-path attachments while serialized attachments remain
available.

## Rationale

Splitting containment into a lexical pass and a post-scope-open real-path
pass is the only ordering that is both correct and sandbox-legal: symlink
resolution inside a granted directory requires the security scope to
already be open, so the authoritative escape check cannot run before that
scope opens, but the lexical pass must run first to even select which
grant's scope to open. Reusing the exact same downstream validator, on the
exact same unresolved URL, for both new sources (and previously for the
picker) keeps the bounded file policy in exactly one place rather than
duplicating type/size/structural checks per source.

Revalidating containment, not just the file, before dispatch is the
filesystem-source analog of ADR 0009's file revalidation: a grant is
mutable state the user can change from Settings at any moment, including
while a confirmation is on screen, so only re-deriving authority from the
current store state — not trusting whatever was true at initial resolution
— keeps the revalidation step honest.

## Consequences

### Positive

- `message_send_attachment` is usable by a fully unattended MCP client for
  the first time; no person needs to be at the keyboard to select a file.
- Filesystem authority is visible, user-managed, and auditable as a short
  Allowed Folders list, rather than an implicit per-call prompt.
- No entitlement changed; the existing app-scoped-bookmark and
  user-selected-file declarations already cover this.
- The full ADR 0009 downstream contract — bounded file policy,
  revalidation, fixed script, one-dispatch, privacy, submitted-not-delivered
  — is reused unchanged rather than re-implemented per source.

### Negative

- A first-time filesystem attachment now requires a one-time Settings visit
  to add a folder, rather than an in-the-moment picker; this is the
  intended trade for removing the per-send picker.
- The 5 MiB serialized cap is stricter than the 25 MiB filesystem cap and is
  explicitly provisional; a client with larger inline content must use a
  filesystem source instead.
- `MessagesAttachmentSelecting`/`OpenPanelMessagesAttachmentSelector` and
  their test doubles are removed; any external code depending on that
  protocol (none exists in this repository) would need to migrate.

### Risks and mitigations

- **Symlink escape from inside a granted folder.** Mitigated by the
  post-scope-open real-path containment check, with dedicated tests
  creating a symlink whose target is outside the granted root.
- **Prefix-confusable sibling folders (`/allowed` vs. `/allowed-evil`).**
  Mitigated by path-component containment rather than string-prefix
  containment, with a dedicated test.
- **A revoked grant between confirmation and dispatch.** Mitigated by
  re-deriving containment (not just re-validating the file) in the
  revalidation step, with a dedicated test.
- **Serialized temp files surviving a failure or cancellation.** Mitigated
  by an unconditional `defer` installed immediately after staging, with
  dedicated tests covering the success, decline, validation-failure, and
  send-failure exit paths.
- **Unbounded work from oversized base64 input.** Mitigated by checking
  encoded length against the decoded cap before decoding, in addition to
  checking decoded size after.
- **Filename path injection in a serialized source.** Mitigated by
  rejecting any filename containing a path separator or a `.`/`..`
  traversal segment before it is ever joined to the staging directory.
- **Accidentally colliding with the Messages database directory bookmark.**
  Mitigated by a distinct storage key and a dedicated store type that never
  reads or writes the database bookmark's key.

## Validation

Automated tests cover: source-selector parsing (each form alone, both
forms conflicting, a partial serialized source, blank-optional-field
omission, non-string malformed fields failing closed); allowed-folder
containment (inside/outside a root, prefix-confusable siblings, lexical
`..` traversal, symlink escape from inside the root, zero grants, multiple
independent roots, a broken/unresolvable grant reported rather than
dropped, balanced security-scope acquisition/release); grant persistence
(add/dedup, remove without touching the user's folder, replace-in-place for
reauthorization); serialized staging (valid small file reaching
confirmation, invalid base64, empty decoded content, oversized decoded
content, unsafe filenames, an unsupported decoded type still failing
through the normal validator, temp cleanup on every exit path, no
caller-owned path ever cleaned up); and that every existing destination,
confirmation, Sending-mode, revalidation, one-dispatch, and privacy
assertion from ADR 0009/0010/0012/0013 remains green under the new source
model. No real Apple Event was executed, no real Contacts or Messages data
was read, and no attachment was sent; every fixture is a synthetic
temporary file or directory.

Manual acceptance is the checklist in `docs/project-prompts/current-task.md`:
confirm the inline Attachments/Allowed Folders Settings UI, that `Add
Folder…` opens the picker directly, that a filesystem attachment reaches
normal confirmation with no picker, that a serialized attachment reaches
the same confirmation with no folder grant, and that a path outside every
grant fails with the actionable Settings error — all without a real send.

## What this does not change

This ADR supersedes only ADR 0009's mandatory-native-picker ingress
mechanism. It does not reopen, and explicitly reaffirms unchanged:

- ADR 0009's bounded file policy, security-scoped access lifetime,
  destination/file revalidation immediately before dispatch, fixed-script
  typed-descriptor dispatch, one-dispatch/no-retry semantics, privacy
  redaction, and submitted-not-delivered truthfulness;
- ADR 0010's global Sending mode and its accepted exception to ADR 0002's
  per-submission confirmation default;
- ADR 0012's two-tool public-API split;
- ADR 0013's unified `recipients` destination field and strict
  `message_send_text.body`;
- the original iMCP MCP connection-authorization mechanism
  (`trustedClients`, connection approval, `clientInfo.name` handling),
  which this record does not touch in any way.

## References

- ADR 0009, whose ingress mechanism this record supersedes and whose
  downstream security/validation contract this record carries forward
  unchanged
- ADR 0010, for the global Sending mode this record's confirmation step
  continues to honor exactly as before
- ADR 0012, ADR 0013, for the two-tool split and destination-field shape
  this record does not touch
- Hexa `imessage-mcp/attachment-sending-design`, `imessage-mcp/messages-write-architecture`,
  `imessage-mcp/current-status`, for the settled product direction this
  record implements
- `App/Services/MessagesAttachmentSource.swift`, `App/Services/AllowedFolderGrantStore.swift`,
  `App/Services/Messages.swift` (`sendAttachment`, `resolveAttachmentSourceHandle`),
  `App/Controllers/AttachmentFolderGrantsController.swift`, `App/Views/SettingsView.swift`

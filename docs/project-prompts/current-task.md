# Current Claude Code Task

**Status:** ready for implementation

**Recommended session:** fresh Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high — the product shape is settled, but this is a security-sensitive macOS sandbox/bookmark + MCP input + SwiftUI milestone touching attachment source authority and cleanup. It is well specified enough that Opus should not be necessary unless repository/platform reality materially contradicts the plan.

This file is the canonical supervising prompt for one coherent attachment-ingress milestone.

## Repository and exact accepted starting state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The exact fully accepted production implementation baseline is:

`326dbaebb97e72960c2c7fea1f381a26690f3e4b` — `fix: ignore blank optional Messages destination fields`

That baseline has already passed supervising code review, 282/282 automated tests, signed-build verification, and the final MCP Inspector manual checkpoint.

This prompt is expected to be the only trajectory-only commit after that accepted production baseline when you begin. Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow `imessage-mcp/coding-agent-bootstrap` as required by root `AGENTS.md`, including the routed project/global documents;
3. verify repository, branch, remotes, local/origin equality, recent history, and a clean worktree;
4. verify `326dbaebb97e72960c2c7fea1f381a26690f3e4b` remains the latest production source/test implementation and that intervening commit(s), if any, are only this prompt trajectory update;
5. inspect the current attachment tool/schema and pipeline, especially `App/Services/Messages.swift`, `App/Services/MessagesAttachment.swift`, `App/Services/MessagesSendConfirmation.swift`, `App/Services/MessagesSender.swift`, `App/Views/SettingsView.swift`, current bookmark/database-access code, `AppTests/MessageAttachmentSendTests.swift`, `AppTests/MessagesBookmarkAccessTests.swift`, relevant ADRs, and current Messages/attachment docs.

If unexpected production source/test changes follow `326dbaeb...`, stop and report the exact state rather than absorbing them.

Do not amend, rebase, reset, squash, force-push, or rewrite reviewed history.

## Current attachment behavior that must be replaced only at the ingress edge

`message_send_attachment` is already an accepted separate public send tool. Destination inputs are settled:

- exactly one meaningful selector: `recipients` or `chat_id`;
- `recipients` accepts a scalar exact handle or a non-empty array;
- scalar and one-item arrays are direct-recipient intent;
- arrays with 2+ supplied elements are exact-existing-group intent and collisions fail closed;
- blank/whitespace scalar optional destination controls are omission-equivalent before exclusivity counting;
- malformed typed/nonblank selectors remain supplied and fail closed;
- verified-new direct recipients remain unsupported for attachments.

The current attachment source path is temporary: after destination resolution it presents a per-send `NSOpenPanel` through `MessagesAttachmentSelecting`, then validates the selected file and uses the existing confirmation / revalidation / AppleScript attachment sender. That picker-based ingress was useful proof but is explicitly rejected as final product UX.

The reviewed downstream attachment boundary is valuable and should be preserved rather than rewritten:

- one ordinary regular file only;
- 25 MiB inclusive filesystem attachment safety cap;
- supported image, audiovisual, PDF, and plain-text types;
- directories, packages/bundles, aliases, symlinks, executables, apps/archives/disk images, unknown generic data, empty files, and unsupported types fail closed;
- immutable attachment confirmation in Ask Before Sending;
- live global `MessagesSendingMode`, with Send Automatically skipping only final confirmation;
- post-authorization destination/file revalidation;
- exact existing-chat addressability;
- Apple Events/TCC after authorization;
- fixed AppleScript source with descriptor-only caller data;
- one dispatch, no retry/fallback;
- privacy-redacted logs/errors/results;
- success means submitted to Messages, never delivered.

## Settled product outcome

Replace per-send picker ingress with exactly two programmatic source forms on `message_send_attachment`:

### A. Filesystem source

```json
{
  "recipients": "person@example.invalid",
  "file_path": "/absolute/path/to/file.pdf"
}
```

`file_path` must be an absolute path to a file contained within at least one folder the user has explicitly allowed in iMCP Settings.

The caller cannot grant new filesystem authority. An absolute path outside every active allowed-folder grant must fail before confirmation/Automation/dispatch with a privacy-safe actionable error directing the user to add the containing folder in iMCP Settings.

### B. Serialized source

```json
{
  "recipients": "person@example.invalid",
  "filename": "file.pdf",
  "content_base64": "..."
}
```

The caller supplies bounded base64 bytes and a safe filename. iMCP materializes them into app-owned temporary storage, passes that staged file through the normal attachment validation/send pipeline, and cleans app-owned temporary artifacts on every safe exit path.

### Source exclusivity

Exactly one source form is valid per call:

- meaningful `file_path`; OR
- meaningful `filename` + meaningful `content_base64`.

There is no `root`, grant ID, staging identifier, relative staging path, picker argument, deletion parameter, or delete-after-send behavior.

Keep the public shape flat. Do not add a nested source object or resurrect the unified send tool.

Because form clients may serialize untouched optional text fields as blank strings, apply the same narrow compatibility principle already accepted for destination controls: a blank/whitespace optional scalar source field may be treated as omission-equivalent for source-form selection. This must not hide malformed typed values or partially supplied serialized input. In particular:

- blank `file_path` does not conflict with a valid serialized source;
- blank `filename` / blank `content_base64` do not conflict with a valid filesystem source;
- meaningful `file_path` plus either meaningful serialized field is a conflicting source error;
- only one of `filename` or `content_base64` meaningfully supplied is an explicit incomplete/malformed serialized-source error;
- no meaningful source is an explicit missing-source error;
- non-string values remain supplied malformed input and fail closed rather than being silently ignored.

Prefer straightforward flat schema properties plus server-side exact validation over a complicated top-level schema union if the latter would reduce MCP client/form compatibility. Preserve clear tool/property descriptions so clients understand the two legal forms.

## Allowed Folders Settings UX — settled

Add the filesystem authority UI inline in the existing Settings surface. Preserve the original repository's settings/navigation style; do not invent a broad settings redesign.

The intended content is an **Attachments** section with two visibly distinct capabilities:

### Serialized attachments

Show that serialized attachments are **Available**, with concise explanatory copy making clear that attachment bytes can be supplied directly by an MCP client and **no folder access is required**.

This is intentionally visible so users can discover the lower-filesystem-permission attachment path without reading documentation.

### Files on this Mac

Explain concisely that iMCP can send files only from folders the user explicitly allows.

Show an inline **Allowed Folders** list. Do not add a separate Manage screen or filesystem-access master toggle.

When empty, show a useful empty state such as “No folders allowed” and explain that adding a folder permits MCP clients to send files stored beneath it.

`Add Folder…` / `+` must open the normal macOS folder picker **directly**, with no intermediate preset menu. Configure it for exactly one directory selection and no file selection.

Each active row should show:

- friendly folder name;
- path/location text;
- lightweight **Show in Finder** action;
- remove/revoke control.

A broken/unresolvable grant must be visible as needing access rather than remaining silently broken. Provide **Reauthorize…** for a broken grant. If the platform can safely refresh a merely stale bookmark without acquiring new authority, it is fine to refresh it automatically; actual missing/broken authority must require user action.

Removing the last folder naturally makes filesystem-path attachments unavailable. Serialized attachments remain available. There is no separate Boolean.

Do not prompt for filesystem access merely because Messages is enabled.

## Persistent folder authority

Use normal user-selected sandbox access and persistent app-scoped security-scoped bookmarks, following the repository's existing signing/entitlement conventions.

Important boundaries:

- attachment-folder grants are a separate product concept from the existing Messages database-directory bookmark/access state; do not accidentally reuse or overwrite that database grant;
- iMCP only needs read authority to caller-owned attachment folders/files;
- persist only what is necessary to restore and display allowed roots; never log bookmark bytes or private paths;
- starting security-scoped access must be balanced with stopping it;
- do not hold scopes indefinitely when not needed;
- removing a grant deletes iMCP's persisted grant record but never deletes or modifies the user's folder/files.

The checked-in project already has app-sandbox/user-selected-file and app-scoped-bookmark support used by existing Messages access. Preserve effective signing, Hardened Runtime, entitlements, and original connection authorization.

## Filesystem containment and revalidation

Caller-controlled `file_path` never creates authority by itself.

For a filesystem source:

1. require an absolute file path;
2. resolve/canonicalize the allowed root and requested file safely;
3. require the final resolved file to remain structurally contained within an active allowed root, with path-component-aware containment rather than naive string-prefix checks;
4. reject traversal and symlink/alias/package escape from the granted root;
5. run the existing bounded attachment validator;
6. retain/restore the required security scope for the access window;
7. after Ask-mode confirmation (or at the equivalent final pre-dispatch point in automatic mode), re-establish/revalidate both grant authority and the exact file facts before dispatch;
8. never copy, delete, rename, or otherwise mutate caller-owned filesystem sources.

Do not weaken the existing attachment validator merely because a parent folder was granted.

## Serialized-source requirements

Use a provisional **5 MiB decoded-content limit** for serialized attachment input in this implementation. Treat it as an explicit adjustable safety constant and document it as provisional pending intended-client acceptance; do not generalize the 25 MiB filesystem cap to base64 JSON blindly.

Required behavior:

- `filename` is a filename only, not a path; reject path separators, traversal names, empty/whitespace names, or other representations that could escape the app-owned temp location;
- use a unique app-owned temporary location;
- decode base64 strictly enough that malformed input fails cleanly;
- bound encoded/decoded work so oversized data is rejected without unbounded memory/disk behavior;
- write temporary attachment data with restrictive file permissions appropriate for private app-owned temp content;
- run the resulting file through the same ordinary attachment validator/type/size policy rather than inventing a privileged serialized bypass;
- keep serialized bytes, filename, temp path, and decoded contents out of production logs/errors/results;
- clean the app-owned temporary file/directory on validation failure, confirmation cancellation, task cancellation, Automation failure, destination failure after creation, successful submission, and every other safe exit path;
- never clean or mutate caller-owned filesystem sources.

If actual repository/platform behavior makes a 5 MiB implementation technically unsound, stop and report evidence rather than silently choosing a different public limit.

## Connection authorization — explicitly out of scope

Preserve the original repository's MCP connection-authorization behavior **as intact as possible**.

Do not change:

- `trustedClients` persistence/behavior;
- “Always trust this client” UI;
- connection approval dialogs;
- client connection notifications;
- approval coalescing/timeouts;
- `clientInfo.name` handling in the original connection-auth path.

Do not build any new Messages-specific authorization semantics keyed by client name, but do not refactor or “fix” upstream connection authentication in this milestone.

A diff touching `ConnectionApprovalView` or trusted-client management is presumptively out of scope and should be avoided unless compilation forces a mechanical change; if so, stop and report before proceeding.

## Implementation approach

Preserve the current destination/send/confirmation/dispatch architecture and replace only the attachment-source edge plus the Settings/grant support needed to make filesystem sources usable.

A reasonable decomposition inside this one milestone is:

1. introduce a small attachment-source parsing/resolution abstraction for filesystem vs serialized input;
2. introduce a focused allowed-folder grant/bookmark store/resolver with test seams;
3. wire filesystem and serialized sources into the existing `sendAttachment` pipeline without tool-time UI;
4. add the inline Attachments Settings UI for viewing/adding/showing/removing/reauthorizing folder grants;
5. remove production dependence on the per-send attachment selector and delete dead picker-only code/tests if genuinely unused, while preserving any generic code still useful for Settings folder selection;
6. update tests/docs/ADR truthfully.

Follow repository conventions. Do not create a broad generic filesystem-permissions framework if a Messages attachment-focused component is sufficient.

## Required tests

Use synthetic paths, names, bytes, handles, and chats only. No real Messages/Contacts data and no real send.

At minimum cover:

### Source parsing/schema

- filesystem source accepted with only meaningful `file_path`;
- serialized source accepted with meaningful `filename` + `content_base64`;
- no source fails;
- both source forms meaningfully supplied fail;
- partial serialized source fails;
- blank optional source controls are omission-equivalent only for form-selection purposes;
- malformed non-string extra source fields remain supplied/fail closed;
- destination semantics from the accepted baseline remain unchanged.

### Filesystem grants

- zero grants rejects filesystem source before confirmation/Automation/dispatch;
- file inside allowed root is resolvable through a test grant;
- sibling/prefix-confusable paths are rejected;
- `..`/canonical traversal cannot escape;
- symlink escape is rejected;
- final symlink/alias/package/directory/unsupported file behavior remains rejected by existing policy;
- revoked/broken grant cannot authorize;
- multiple roots work without broadening authority;
- scope acquisition/release is balanced through test seams where practical;
- file/grant revalidation before dispatch remains enforced.

### Serialized content

- valid small supported synthetic file materializes and reaches normal attachment confirmation/send seam;
- invalid base64 fails with zero downstream send side effect;
- empty decoded file fails;
- >5 MiB decoded input fails under the provisional serialized limit;
- unsafe filename/path attempts fail;
- unsupported type still fails through normal validator;
- temp cleanup occurs on success seam, confirmation cancellation, validation failure, and send/Automation failure;
- no caller-owned path cleanup occurs.

### Settings/grant model

Factor grant storage/resolution so core persistence state can be unit tested without presenting AppKit UI. Cover add/deduplicate-or-explicitly-handle duplicate, remove, broken grant presentation state, and reauthorization replacement semantics as appropriate to the implementation.

Do not add GUI automation solely to test SwiftUI/AppKit rendering.

## Documentation / ADR

This source-model change is durable public/security architecture.

Inspect ADR 0009 and current ADR index. If ADR 0009 presents per-send picker ingress as the accepted final source mechanism, preserve it as history and create the next ADR to supersede **that ingress decision only**, while retaining the accepted downstream existing-chat attachment submission architecture. Update `docs/decisions/README.md`.

Update current attachment/write docs and README/tool documentation where needed so they describe:

- `message_send_attachment` with `file_path` OR `filename` + `content_base64`;
- user-approved Allowed Folders;
- no per-send picker;
- no staging/delete behavior;
- 5 MiB serialized limit as provisional/current implementation policy if exposed publicly;
- 25 MiB filesystem attachment policy where already documented;
- verified-new recipients still unsupported for attachments;
- original iMCP connection authorization unchanged.

Do not rewrite historical project reports merely because product direction evolved.

Write a sanitized self-contained implementation report to:

`docs/project-reports/programmatic-attachment-ingress-2026-08-17.md`

The report must include starting accepted implementation SHA, ending implementation SHA, main files/symbols, tests/build/signing evidence, unresolved platform/manual gates, and next bounded action. Do not include private paths, real recipient data, raw logs, or serialized bytes.

## Scope and explicit exclusions

Do not implement in this milestone:

- automatic-send active indicator / Pause automatic sending affordance;
- circuit breaker;
- Recent Send Activity;
- new-recipient attachment composition;
- text-send API changes;
- new group creation;
- per-client Messages send policies;
- connection-auth/trusted-client redesign;
- source-file deletion or staging semantics;
- Full Disk Access prompting;
- private Messages frameworks, Accessibility automation, SIP changes, or code injection;
- cross-call idempotency;
- RCS-specific work;
- unrelated Settings redesign/refactoring;
- upstream PR decomposition or maintainer-facing PR creation.

## Security and privacy invariants

Do not weaken:

- exact destination resolution and ambiguity failure;
- exact-existing-group semantics;
- verified-new-recipient attachment refusal;
- Ask-mode final confirmation and global Send Automatically behavior;
- destination/file/grant revalidation;
- Automation/TCC ordering and exact chat addressability;
- fixed AppleScript source / descriptor-only caller values;
- one Messages dispatch per tool call and no retry/fallback;
- cancellation before dispatch;
- privacy-redacted logs/errors/results;
- submitted-not-delivered truthfulness;
- App Sandbox, Hardened Runtime, signing, and existing entitlement guarantees;
- original iMCP connection-auth behavior.

A confirmation surface may show the exact attachment display name/type/size needed for human authorization, as the existing accepted design does. Production logs and ordinary errors/results must not expose private file paths, bookmark material, serialized bytes, or recipient/message data.

Do not send a real message or attachment during automated verification.

## Verification

Run focused tests first, then full applicable verification.

At minimum:

- focused attachment source/grant tests;
- focused existing `MessageAttachmentSendTests` regression suite;
- `swift format lint --strict --recursive .`;
- `git diff --check`;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- elicitation proxy test if the tool-schema/CLI path is affected and the environment supports the known framework-loading requirement;
- regenerate the established signed `.build/ManualVerification` app;
- `codesign --verify --strict`;
- inspect the signed artifact's effective entitlements and confirm App Sandbox, user-selected file access, app-scoped bookmarks, Apple Events automation, and Hardened Runtime remain present.

Adversarially self-review for:

- filesystem path escaping a grant through prefix tricks, `..`, symlinks, aliases, packages, or stale bookmark handling;
- security scope started but not stopped;
- bookmark/grant state accidentally colliding with the Messages database bookmark;
- serialized temp files surviving failure/cancellation/success;
- serialized filename path injection;
- oversized base64 work before bounds are checked;
- filesystem source accidentally deleted or modified;
- source validation occurring after Automation or dispatch;
- per-send picker still reachable from ordinary tool execution;
- accidental changes to destination, text-send, Sending-mode, or connection-auth behavior;
- private paths/filenames/bytes leaking into logs/errors/results;
- more than one Messages dispatch or any retry/fallback.

## Git and handoff

Use additive checkpoint commits if useful, with one coherent final implementation/report head. Stage only task-owned files.

Push normally to `origin/feat/messages-write-foundation`, then fetch and verify local HEAD exactly equals origin and the worktree is clean.

Do not open or merge an upstream PR. Do not push to the maintainer repository. Do not rewrite reviewed history.

## Manual verification after supervising code review

Claude must not perform a real Messages send.

After the exact pushed head passes supervising review, the human manual checkpoint should be limited to unresolved macOS/UI behavior, likely:

1. Launch the signed manual-verification build and inspect the inline Attachments settings: Serialized attachments visibly Available; Allowed Folders empty state present.
2. Click Add Folder and verify it opens the folder picker directly. Add a disposable test folder containing only synthetic files.
3. Verify the row shows name/path, Show in Finder works, and removing/re-adding access behaves correctly. If practical, exercise the broken-grant/Reauthorize state with a disposable folder move/removal; do not contort the environment if macOS makes this artificial.
4. Through MCP Inspector, call `message_send_attachment` for an existing conversation with an allowed synthetic filesystem file. It should reach the normal Ask Before Sending attachment confirmation without opening a picker. Cancel; nothing sends.
5. Repeat with a tiny serialized synthetic supported attachment. It should reach the same normal confirmation with no filesystem grant requirement. Cancel; nothing sends.
6. Attempt a synthetic filesystem path outside every grant and confirm it fails with the actionable Settings guidance before confirmation/Automation.

No successful real attachment dispatch is required unless the supervisor and user separately authorize an exact destination and exact test file later.

## Stopping point

STOP after all of the following are true:

- ordinary `message_send_attachment` no longer opens a per-send picker;
- the public tool supports exactly filesystem `file_path` OR serialized `filename` + `content_base64` sources;
- filesystem paths require active persistent user-approved folder authority and cannot escape it;
- serialized input is bounded, safely staged, validated, and always cleaned up;
- caller-owned filesystem sources are never deleted or mutated;
- the inline Attachments / Allowed Folders Settings UX is implemented with direct Add Folder, Show in Finder, remove, and broken-grant reauthorization behavior;
- existing destination, confirmation, automatic-mode, revalidation, Automation/TCC, privacy, one-dispatch, and submitted-not-delivered behavior is preserved;
- original connection-auth/trusted-client behavior is untouched;
- focused/full tests, formatting, build, and signed-artifact verification pass;
- current docs/ADR are truthful and the implementation report is committed;
- branch is pushed normally, local HEAD equals origin, and worktree is clean.

When complete, the user should only need to say **done**.
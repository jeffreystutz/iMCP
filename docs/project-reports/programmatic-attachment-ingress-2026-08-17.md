# Programmatic attachment ingress for `message_send_attachment`

- Starting accepted production head: `326dbaebb97e72960c2c7fea1f381a26690f3e4b`
  — `fix: ignore blank optional Messages destination fields`. That head
  passed supervising code review, 282/282 automated tests, signed-build
  verification, and the final manual MCP Inspector checkpoint.
- Trajectory-only commit present before this slice (no production change):
  `9ee212588fa8f9a5456ac3ce17ac13bfb69986b3` — "docs: publish programmatic
  attachment ingress task" (`docs/project-prompts/current-task.md`).
- Implementation commit(s) for this slice: identified by title, not
  embedded hash, per the established convention (a commit cannot accurately
  embed its own hash) — see `git log --oneline` for exact SHAs.
- Branch: `feat/messages-write-foundation`.

## Summary

`message_send_attachment` no longer opens a per-send `NSOpenPanel`. It now
accepts exactly one of two programmatic sources:

- `file_path` — an absolute path that must resolve inside at least one
  folder the user has explicitly allowed in iMCP Settings under
  **Attachments → Files on this Mac**;
- `filename` + `content_base64` — a plain file name and bounded (5 MiB
  decoded, provisional) base64-encoded bytes, staged into app-owned
  temporary storage and always cleaned up afterward.

Source-selector parsing (`resolveAttachmentSource`) mirrors the existing
destination-selector blank-scalar-omission rule: a blank optional source
field is omission-equivalent only for exclusivity counting, never for
hiding a malformed or conflicting value.

A new persistence type, `AllowedFolderGrantStore`, holds user-approved
folder bookmarks under their own `UserDefaults` key — distinct from, and
never colliding with, the existing Messages database directory bookmark —
using the same app-scoped security-scoped bookmark mechanism and the same
entitlements already declared for that bookmark. No entitlement changed.
`AllowedFolderGrantResolver` resolves a requested path against every
configured grant with two containment passes (lexical, then
symlink-resolved-real-path after the root's security scope opens), so
`..` traversal, prefix-confusable sibling folders, and interior symlink
escapes are all rejected, while the original unresolved request URL still
reaches the unchanged `FileManagerMessagesAttachmentValidator` so its own
symlink/alias/package rejection still applies to the requested leaf.

`sendAttachment`'s eight-step pipeline (destination resolution,
non-prompting preflight, source resolution, confirmation or the Send
Automatically skip of only that step, destination revalidation, source
revalidation, Automation/addressability recheck, exactly one dispatch) is
unchanged in shape; only the source-resolution and source-revalidation
steps were replaced. Revalidation for a filesystem source re-derives
containment from the current grant store, not just the file, so a grant
revoked between confirmation and dispatch fails closed.

Settings gained an inline **Attachments** section in the existing single
form: static "Serialized attachments — Available" copy, and an **Allowed
Folders** list under "Files on this Mac" with a direct `Add Folder…`
(standard folder picker, one directory, no intermediate menu), and per-row
`Show in Finder`, remove, and `Reauthorize…` (for a broken grant) controls.

The public tool description and schema were updated to describe both
source forms, the two size caps, and the Allowed Folders requirement, with
no picker language remaining. `MessagesAttachmentSelecting` and
`OpenPanelMessagesAttachmentSelector` are removed; the bounded file
validator, its facts type, its categorical error type, and the
security-scope RAII wrapper are unchanged and reused by both new sources.

## Correction (2026-08-17, review iteration)

Supervising review of head `a16be7721bf1287f1f933adc74157afa895f448c` found
three issues, published as `docs/project-prompts/current-task.md` at
prompt-only commit `5e2f4c07e1492ba8ca4a1764891c38a168fa39e8`
("docs: publish attachment ingress review correction"). All three are
corrected additively on top of that head, without rewriting any reviewed
commit.

1. **Initial-validation resource leak.** `resolveAttachmentSourceHandle`
   acquired a filesystem grant's security scope, or staged a serialized
   temp file, before the very first validator call — but the cleanup
   closure only existed on the `ResolvedAttachmentSourceHandle` returned
   *after* that validation succeeded. If initial validation threw, the
   just-acquired security scope was never released, and the just-staged
   temp directory was never removed. Fixed with a `do`/`catch` around each
   branch's initial `validator.validate(...)` call that releases the
   access, or removes the temp directory, before rethrowing — the existing
   outer `defer { sourceHandle.release() }` behavior for every exit after
   a successful handle is returned is unchanged, so there is no
   double-release/double-delete on the success path.
2. **Test asserted the wrong failure for the wrong reason.**
   `testSerializedTempCleanupOccursOnValidationFailure` (and, found during
   the fix, the same flaw in `testEmptyDecodedSerializedFileFails`) supplied
   meaningful `filename` with **blank** `content_base64` and expected
   `.emptyFile`. Under the settled blank-scalar-omission rule, blank
   `content_base64` is omission-equivalent, so that input is an
   **incomplete serialized source** and fails with
   `.incompleteSerializedSource` before decoding or staging — it can never
   reach `.emptyFile`, and could never have exercised validation-failure
   cleanup. The parser semantics were not changed. Both tests were
   corrected: the blank-content case is now its own explicit
   parser-and-pipeline test proving `.incompleteSerializedSource` with zero
   downstream side effect
   (`testMeaningfulFilenameWithBlankContentBase64FailsAsIncompleteSourceWithZeroSideEffects`,
   plus a parser-level case added to `testPartialSerializedSourceFails`),
   and the cleanup test now supplies complete, nonempty, synthetic
   base64 content with an unsupported-type filename, actually reaches
   staging and the normal validator, and asserts the staged temp directory
   count returns to its pre-call value.
3. **Unsynchronized compound persistence across store instances.**
   Production constructs a separate `UserDefaultsAllowedFolderGrantStore`
   instance for Settings and for the send-side resolver, both over the same
   `UserDefaults` storage. `UserDefaults` itself being thread-safe does not
   make a load-modify-save sequence atomic, so a send-side stale-bookmark
   refresh could race a Settings-side remove and resurrect a just-removed
   grant, or otherwise lose an update. Fixed with one `static` `NSLock`
   shared by every instance of the class, with every public operation
   (`listGrants`, `addGrant`, `removeGrant`, `replaceGrant`,
   `refreshBookmark`) now a single transaction under that lock; unlocked
   private `unlockedLoadStored`/`unlockedSave` helpers exist only to be
   called from inside an already-held lock, so no path locks recursively.
   The storage key, serialized format, dedup semantics, and the Messages
   database bookmark's separate state are all unchanged.

Focused regression coverage added: `testFilesystemInitialValidationFailureReleasesTheAcquiredAccess`
and `testFilesystemSuccessfulHandleReleasesEachResolvedAccessExactlyOnce`
prove the filesystem-branch fix via a new `onRelease` test seam on
`AllowedFolderFileAccess` (production-optional, defaulted to `nil`, wired
only by the test double) — necessary because `MessagesAttachmentAccess.release()`
is a silent no-op for the unbookmarked URLs tests use, which made "was
`release()` actually called" otherwise unobservable. The corrected
`testSerializedTempCleanupOccursOnValidationFailure` proves the serialized-
branch fix directly. `testStaleRefreshFromOneInstanceCannotResurrectAGrantRemovedByAnother`
and `testConcurrentAddsAcrossTwoInstancesLoseNoGrants` (real concurrent
`DispatchQueue` access across two store instances sharing one
`UserDefaults` domain) cover the persistence-synchronization fix.

## Files and symbols changed

- `App/Services/MessagesAttachmentSource.swift` (new): `AttachmentSourceInput`,
  `MessagesAttachmentSourceError`, `resolveAttachmentSource(_:)`,
  `validateSerializedAttachmentFilename(_:)`,
  `decodeSerializedAttachmentContent(_:)`,
  `maximumSerializedAttachmentByteSize` (5 MiB, provisional).
- `App/Services/AllowedFolderGrantStore.swift` (new): `AllowedFolderGrant`,
  `ResolvedAllowedFolderGrant`, `AllowedFolderGrantError`,
  `AllowedFolderGrantStoring` protocol, `UserDefaultsAllowedFolderGrantStore`,
  `AllowedFolderBookmark` (shared bookmark resolution),
  `AllowedFolderFileAccess`, `AllowedFolderGrantResolving` protocol,
  `AllowedFolderGrantResolver` (path-component-aware containment,
  symlink-escape rejection, transparent stale-bookmark refresh, broken-grant
  reporting).
- `App/Controllers/AttachmentFolderGrantsController.swift` (new):
  `@MainActor` `ObservableObject` wrapping `AllowedFolderGrantStoring` for
  Settings — `addFolder()`, `remove(id:)`, `reauthorize(id:)`,
  `showInFinder(id:)`, `refresh()`.
- `App/Services/MessagesAttachment.swift`: removed
  `MessagesAttachmentSelecting`, `OpenPanelMessagesAttachmentSelector`, and
  `MessagesAttachmentError.selectionCancelled` (picker-only, now
  unreachable). `MessagesAttachmentFacts`, `MessagesAttachmentValidating`,
  `FileManagerMessagesAttachmentValidator`, `MessagesAttachmentAccess`, and
  every remaining `MessagesAttachmentError` case are unchanged and reused.
- `App/Services/Messages.swift`:
  - `MessageService` drops the `attachmentSelector` property/init parameter;
    adds `attachmentFolderGrantResolver: any AllowedFolderGrantResolving`
    (default `AllowedFolderGrantResolver(store: UserDefaultsAllowedFolderGrantStore())`).
  - `message_send_attachment`'s schema gains `file_path`, `filename`,
    `content_base64`; description rewritten to describe both source forms,
    both size caps, no picker, and the Allowed Folders requirement. The
    tool closure now also parses `resolveAttachmentSource(arguments)`
    synchronously alongside `resolveDestination`, before any I/O.
  - `sendAttachment(destination:source:context:)`: step 3 (picker +
    validate) replaced by `resolveAttachmentSourceHandle(_:)`, producing a
    `ResolvedAttachmentSourceHandle { facts, revalidate, release }`;
    `release()` runs via `defer` immediately after resolution, so a
    filesystem grant's security scope and a serialized temp directory are
    always balanced/removed on every exit path. Step 6 (revalidate file)
    now calls `sourceHandle.revalidate()`, which for a filesystem source
    re-resolves grant access (re-deriving authority, not just re-reading
    the file) and for a serialized source re-validates the still-present
    staged file. Steps 1-2 and 4-8 are byte-for-byte unchanged.
  - `resolveAttachmentSourceHandle(_:)`, `stageSerializedAttachment(_:filename:)`
    (new private helpers on `MessageService`).
- `App/Views/SettingsView.swift`: `GeneralSettingsView` gains
  `@StateObject private var attachmentGrants = AttachmentFolderGrantsController()`
  and a new "Attachments" `Section` (serialized-availability copy, Allowed
  Folders list with empty state, add/show-in-Finder/remove/reauthorize
  controls). No new `SettingsSection` case; no new navigation.
- `AppTests/MessageAttachmentSendTests.swift`: rewritten. New "Source
  parsing" section unit-tests `resolveAttachmentSource`,
  `validateSerializedAttachmentFilename`, `decodeSerializedAttachmentContent`
  directly. New "Filesystem source: allowed-folder access" and "Serialized
  source" sections cover outside-every-grant rejection, resolve-only-after-
  destination ordering, revoked-grant-after-confirmation failure, valid/
  invalid/oversize/empty/unsafe-filename/unsupported-type serialized input,
  and temp-cleanup on every exit path (success, decline, validation
  failure, send failure) plus never cleaning up a caller-owned filesystem
  path. Every remaining picker-era test (destination resolution,
  confirmation content, post-confirmation revalidation, dispatch, Send
  Automatically, fixed script/descriptors, privacy) is preserved with its
  original assertions, converted to pass `file_path`/`filename`+
  `content_base64` arguments instead of stubbing a picker selection.
  `StubAttachmentSelector` replaced by `StubAllowedFolderGrantResolver`
  (records call count/order, returns configurable per-call outcomes).
- `AppTests/AllowedFolderGrantStoreTests.swift` (new): store persistence
  (add/dedup, remove-without-touching-the-folder, replace-in-place),
  resolver containment (inside/outside a root, prefix-confusable sibling,
  lexical traversal, symlink escape, zero grants, multiple independent
  roots, balanced scope acquisition/release), and broken-grant reporting
  (unresolvable bookmark reported `.broken` not dropped, access skips it
  and fails closed, no refresh attempted on an unresolvable bookmark).
- `docs/decisions/0014-programmatic-attachment-source-ingress.md` (new):
  Proposed ADR superseding ADR 0009's mandatory-picker ingress mechanism
  only, carrying forward its full bounded-file/revalidation/privacy
  contract unchanged.
- `docs/decisions/0009-attachment-only-existing-chat-submission.md`: header
  `Superseded by` updated to name both ADR 0011 (tool surface) and ADR 0014
  (ingress); new "Note (ADR 0014)" paragraph added, same style as the
  existing ADR 0011/0012 notes.
- `docs/decisions/README.md`: ADR 0009 row updated; new ADR 0014 row added.
- `docs/messages-write-plan.md`: new "Note (2026-08-17)" at the top of
  "Attachment submission" pointing to the new section below it; new
  "Programmatic attachment ingress" section added before "Reference
  implementation," describing the settled source model, grant containment,
  serialized staging, pipeline changes, and Settings UI. Historical
  narrative sections are preserved unchanged.
- `README.md`: the tool-table attachment description and the "Sending
  Messages" prose updated to describe the two sources and the Allowed
  Folders requirement in place of "via a native picker."
- This report (new).

Explicitly unchanged: destination resolution/revalidation/ambiguity
handling, the bounded file validation policy and its 25 MiB filesystem cap,
the fixed AppleScript sender and its typed file-URL descriptor, one-
dispatch/no-retry semantics, privacy redaction, submitted-not-delivered
truthfulness, the global `MessagesSendingMode` wiring, `message_send_text`
and its schema, verified-new-recipient attachment refusal, and the original
iMCP MCP connection-authorization mechanism (`trustedClients`, connection
approval, `clientInfo.name` handling) — none of it was touched.

## Verification evidence

- `xcodebuild -scheme iMCP -configuration Debug -destination "platform=macOS" build`
  — **BUILD SUCCEEDED**.
- `xcodebuild -scheme imcp-serverTests -configuration Debug -destination "platform=macOS" build-for-testing`
  — **TEST BUILD SUCCEEDED** (compiles cleanly against every new/changed
  test file, including the rewritten `MessageAttachmentSendTests.swift` and
  the new `AllowedFolderGrantStoreTests.swift`).
- `swift format lint --strict --recursive` over every new/changed file —
  clean after one auto-format pass (`swift format format --in-place`) fixed
  purely mechanical spacing/line-break findings; no logic changed by that
  pass.
- `git diff --check` — clean.
- `python3 CLITests/test_elicitation_proxy.py .build/DerivedData/Build/Products/Debug/iMCP.app/Contents/MacOS/imcp-server`
  — passed (exit 0), against the unsigned CI-style artifact built the same
  way as `.github/workflows/ci.yml`. This exercises the CLI-to-app stdio
  proxy round trip, including tool-schema listing for the now-changed
  `message_send_attachment` schema.
- Signed `.build/ManualVerification` build regenerated with
  `DEVELOPMENT_TEAM=4LC533SNYD`, `CODE_SIGNING_ALLOWED=YES`. `codesign
  --verify --strict` exits 0. Effective entitlements
  (`codesign -d --entitlements - --xml`) include `com.apple.security.app-sandbox`,
  `com.apple.security.files.user-selected.read-write`,
  `com.apple.security.files.bookmarks.app-scope`,
  `com.apple.security.automation.apple-events`, and the existing
  `com.apple.MobileSMS` Apple Events temporary exception; `CodeDirectory
  ... flags=0x10000(runtime)` confirms Hardened Runtime is active. This
  entitlement set is unchanged from every earlier signed build in this
  project's Messages-write history — this milestone added no entitlement.

### Unresolved verification gap: automated XCTest execution still did not run

**`xcodebuild ... test` was retried in this correction session and still
could not launch.** Two consecutive attempts against the focused test
classes (`MessageAttachmentSendTests`, `AllowedFolderGrantStoreTests`)
failed identically with `IDELaunchErrorDomain` code 20, "Could not launch
imcp-serverTests... The LaunchServices launcher has returned an error" —
the same failure mode reported for the original implementation session,
now re-confirmed once as the correction task instructed rather than
investigated further. The test *target* builds successfully
(`build-for-testing` succeeds cleanly against the corrected code and every
new/changed test), so this remains a launch-time infrastructure limitation
of this session, not a compile or logic defect introduced by this
correction. Per this correction task's explicit instruction ("If the exact
same environment-wide LaunchServices test-launch failure persists after
one normal retry, do not spend the session trying to redesign tests or
repair unrelated runner infrastructure"), this was not pursued further.

**Consequently: no automated test *execution* count (e.g. "N/N passed") is
claimed anywhere in this report, for either the original implementation or
this correction.** The prior milestone's 282/282 figure remains the last
actual execution result and predates both this milestone and this
correction entirely. Running the full `imcp-serverTests` suite — ideally in
the interactive session where that 282/282 result was obtained — remains a
**prerequisite** for supervising acceptance, not merely the deferred manual
UI checkpoint below. Every test file this report describes, including the
corrected and newly added tests, was written to compile and was reasoned
through manually against the production code it exercises, but that is not
a substitute for actually running it.

- Adversarial self-review performed against: filesystem path escaping a
  grant via prefix tricks, `..`, or symlinks (dedicated resolver tests for
  each); a security scope started but not stopped, on both the success
  path (the original `access` object's scope is held via `defer` for the
  whole `sendAttachment` call and released exactly once; the revalidation
  closure opens and releases its own short-lived second scope only to
  re-check current authority) and the initial-validation-failure path
  found by review and fixed in the correction above (a dedicated test now
  asserts the acquired access is released exactly once even when the very
  first validation call throws); grant state colliding with the Messages
  database bookmark (distinct
  `UserDefaults` key, distinct store type, no shared code path); a
  serialized temp file surviving failure/cancellation/success (unconditional
  `defer` installed immediately after staging, with dedicated tests for
  each exit path); serialized filename path injection (rejected before the
  filename is ever joined to the staging directory); oversized base64 work
  before bounds are checked (encoded-length check runs before decoding);
  a filesystem source accidentally deleted or modified (the resolver and
  validator only ever read; no write/delete call exists on that path in
  either the pipeline or its tests, and a dedicated test asserts the
  caller-owned file still exists after a send failure); source validation
  after Automation or dispatch (source resolution and its confirmation
  remain steps 3-4, strictly before the step-7 Automation
  request/addressability recheck and step-8 dispatch, unchanged in order);
  the per-send picker still reachable (the picker protocol/implementation
  is deleted from the module entirely, not merely unused); accidental
  changes to destination, text-send, Sending-mode, or connection-auth
  behavior (none of those files/sections were touched; `message_send_text`
  and `resolveDestination` are byte-for-byte unchanged); private
  paths/filenames/bytes leaking into logs/errors/results (every new error
  case's `errorDescription` was written categorically and is covered by a
  dedicated privacy test asserting none of a synthetic private path,
  filename, or content leaks); more than one Messages dispatch or any retry
  (the dispatch step itself is unchanged from ADR 0009, and existing
  one-dispatch tests were preserved).
- No automated verification step sent a real message or attachment. No
  real Contacts or Messages data was accessed, read, or logged at any
  point. Every test fixture is a synthetic temporary file, directory, or
  path string.

### Fresh-session verification attempt (2026-08-17, verification-only task)

A dedicated fresh Claude Code session executed
`docs/project-prompts/current-task.md` at prompt-only head
`f0f5aef1d18f8408343d45d5ac72d09d07ead13b`, with the sole goal of getting the
milestone's XCTest suite to actually execute. Repository state was verified
first: `feat/messages-write-foundation` at `HEAD` equal to `origin/HEAD`
(`f0f5aef1d18f8408343d45d5ac72d09d07ead13b`), clean worktree, and the only
commit after `0a20c99e372096e5d777309e5acc282e36aeb824` was that prompt-only
commit — no unexpected production/test drift.

Environment: macOS 26.5.2 (build 25F84), Xcode 26.6 (build 17F113), Darwin
25.5.0, arm64 (Mac15,12).

Two focused-test attempts were made, each against a distinct, freshly created,
git-ignored `-derivedDataPath` (neither reused any directory from a prior
session):

```
xcodebuild -scheme imcp-serverTests -configuration Debug -destination "platform=macOS" \
  -derivedDataPath .build/DerivedData-xctest-verify-20260817 \
  -only-testing:imcp-serverTests/MessageAttachmentSendTests \
  -only-testing:imcp-serverTests/AllowedFolderGrantStoreTests \
  test
```

```
xcodebuild -scheme imcp-serverTests -configuration Debug -destination "platform=macOS" \
  -derivedDataPath .build/DerivedData-xctest-verify-2 \
  -only-testing:imcp-serverTests/MessageAttachmentSendTests \
  -only-testing:imcp-serverTests/AllowedFolderGrantStoreTests \
  test
```

Both attempts failed identically, before any XCTest case executed:

```
IDELaunchReport: ... Finished with error: Could not launch "imcp-serverTests"
Domain: IDELaunchErrorDomain
Code: 20
Recovery Suggestion: The LaunchServices launcher has returned an error. Please check the system logs for the underlying cause of the error.
```

Result bundles: `.build/DerivedData-xctest-verify-20260817/Logs/Test/Test-imcp-serverTests-2026.08.17_12-28-37--0700.xcresult`
and `.build/DerivedData-xctest-verify-2/Logs/Test/Test-imcp-serverTests-2026.08.17_12-29-34--0700.xcresult`
(both git-ignored under `.build/`, not committed).

This is the third consecutive session (across the original implementation
session, the correction session, and this dedicated verification session) to
hit the identical `IDELaunchErrorDomain` code 20 failure at test-runner
launch time, now confirmed with two independently fresh `DerivedData`
directories in the same session, ruling out a stale-cache explanation
specific to one directory. Per this task's explicit bounded-retry limit (at
most one safe, non-product retry), no further attempts were made. No
signing, entitlements, sandboxing, test, product code, scheme, or project
configuration change was made to try to coerce the runner, and no
GUI/Accessibility/AppleScript workaround was introduced.

**No test execution occurred in this session. The last actual XCTest
execution result for this repository remains the pre-attachment-milestone
282/282 figure.** This session neither adds nor claims any new pass/fail
count; it adds confirming evidence that the launch failure is environment/
infrastructure-level (LaunchServices) and reproduces across fresh
`DerivedData` paths and sessions, not a property of any one stale build
directory. `build-for-testing` was not re-verified in this session since it
was already confirmed clean in the prior correction session and no
production/test source changed since.

## Manual checkpoint to prepare (not executed)

Using the signed build at
`.build/ManualVerification/Build/Products/Debug/iMCP.app`, and only after
the automated test suite above has actually been run and passed:

1. Launch the signed build and open Settings; confirm the inline
   **Attachments** section shows "Serialized attachments — Available" and
   an empty **Allowed Folders** list with its empty-state copy.
2. Click **Add Folder…**; confirm it opens the standard folder picker
   directly, with no intermediate menu. Add a disposable folder containing
   only synthetic files.
3. Confirm the resulting row shows a name and location, that **Show in
   Finder** opens it, and that removing it returns the list to empty.
   Exercise **Reauthorize…** on a broken grant if practical (e.g. moving the
   folder), without contorting the environment if macOS makes this
   artificial.
4. Through MCP Inspector, call `message_send_attachment` with `file_path`
   pointing at a synthetic file inside an allowed folder, for an explicitly
   authorized existing conversation. Confirm it reaches normal Ask Before
   Sending confirmation with no picker. Cancel; confirm nothing sends.
5. Repeat with a small synthetic `filename` + `content_base64` payload;
   confirm the same confirmation appears with no folder-access requirement.
   Cancel; confirm nothing sends.
6. Attempt a synthetic `file_path` outside every allowed folder; confirm it
   fails before confirmation with the actionable Settings-pointing error.

Claude did not perform this checkpoint and did not send any real message
or attachment during implementation or automated verification.

## Next bounded action

A third, dedicated verification-only session (above) reproduced the same
`IDELaunchErrorDomain` code 20 launch failure with two independently fresh
`DerivedData` directories, so the failure is not specific to one stale build
directory or one prior session's environment. The failure remains launch-time
infrastructure (LaunchServices), not a compile or test-assertion defect: the
test target still builds cleanly and no product/test code changed.

Running the full `imcp-serverTests` suite so it actually executes remains a
**prerequisite** for supervising acceptance of this milestone. That may
require an interactive/GUI-attached session (the environment the prior
282/282 result was obtained in) rather than another CLI-only `xcodebuild
test` invocation, since three consecutive CLI-only sessions have now hit the
identical launch failure. Once XCTest actually executes and passes, then
supervising review of the exact pushed head on
`feat/messages-write-foundation`, then the manual checkpoint above under the
user's own explicit, separate authorization for any real send. No further
implementation is expected until the test suite has actually been executed
and that review/checkpoint complete.

# Existing-conversation picker-based attachment-send Sending-mode wiring

- Accepted starting head (text-send runtime wiring, fully accepted including the real runtime checkpoint): `eb64ee2de11a50d63bc1d64362136d1251f0bdf4`
- Supervising governance/prompt commits present before this slice (trajectory only, no production change): "docs: publish automatic attachment-send wiring task" (`docs/project-prompts/current-task.md`)
- Implementation commit(s) for this slice: identified by title, not embedded hash, per the established cleanup in the prior report (a commit cannot accurately embed its own hash) — see `git log --oneline` for exact SHAs.
- Branch: `feat/messages-write-foundation`

## Summary

Extends the accepted global `MessagesSendingMode` (ADR 0010, `Accepted`) to
**picker-based `messages_send_attachment`**, using the identical pattern
already accepted for text sends. In **Ask Before Sending** (factory default),
attachment sends behave exactly as they did before this slice: native picker,
bounded file validation, one mandatory final confirmation naming the exact
destination and file facts, then destination/file revalidation, Automation
authorization, and exactly one dispatch. In **Send Automatically**, only that
one confirmation step is skipped; the native picker and every other step
remain unconditional, shared code for both modes. There is no second dispatch
path.

The native picker is **not** replaced or treated as authorization in
automatic mode — selecting a file is the trusted local input mechanism, not a
substitute per-send approval. Attachment sending is therefore still not
fully unattended even with Send Automatically selected: a person still must
be at the machine to choose the file. Verified-new-recipient attachment
sending remains unsupported and fails before the picker is ever presented,
in both modes.

## Files and symbols changed

- `App/Services/Messages.swift`:
  - The `messages_send_attachment` tool closure: the unconditional final
    attachment-confirmation request is now wrapped in `switch
    self.sendingMode() { case .askBeforeSending: ... case .sendAutomatically:
    break }`, placed immediately around the existing confirmation-building/
    request code and nowhere else. Every line before and after this switch —
    destination resolution, verified-new-recipient rejection, non-prompting
    preflight, picker presentation, file validation, destination/file
    revalidation, Automation/addressability verification, the single
    `submitChatAttachment` dispatch, categorical logging, and the redacted
    result — is unchanged.
  - Updated the doc comment above that switch to describe both modes
    accurately instead of assuming confirmation is always the authorization
    boundary.
  - Updated `messages_send_attachment`'s public tool description so it no
    longer promises confirmation unconditionally; it now explains that
    whether confirmation happens follows the Sending mode setting, that no
    caller can choose or override it, and that the native picker always runs
    and is never itself treated as authorization.
  - No new stored property or init parameter was needed: `MessageService`
    already gained the `sendingMode` provider in the text-send slice, and
    this slice reuses it unchanged.
- `AppTests/MessageAttachmentSendTests.swift`:
  - `RecordingAttachmentChatRepository` gained an `onSecondResolve`
    (`@Sendable () -> Void`) hook, firing exactly once, on the second
    destination-read call. That read is always the revalidation read — the
    first happens during `prepareDestination`, before the picker even runs —
    so this simulates "the world changed between authorization and dispatch"
    at the identical logical moment in both modes, mirroring what the
    existing `onConfirmation` hook already does for Ask Before Sending (which
    has no effect in automatic mode, since no confirmation is requested
    there).
  - `Harness.init(...)` gained the corresponding `onSecondResolve` parameter,
    threaded through to the repository.
  - Replaced the now-obsolete `testSendAutomaticallyDoesNotBypassAttachmentConfirmation`
    (which correctly asserted the *prior*, not-yet-wired behavior) with 9 new
    tests (see "Required focused tests" below).
  - Strengthened `testSchemaAcceptsOnlyDestinationSelectorsAndNoFileOrBodyParameter`
    with additional forbidden-substring checks (`mode`, `sending_mode`,
    `automatic`, `bypass`, `confirm`, `confirmation`) to explicitly cover "no
    caller-facing mode/bypass argument."
- `README.md`: the "Sending Messages" prose and the Messages capabilities-table
  row updated so attachments are no longer described as always confirmed;
  both now describe the shared Sending-mode behavior and note the picker
  always runs regardless of mode.
- `docs/decisions/0009-attachment-only-existing-chat-submission.md`:
  reconciled in place (not superseded) — the unconditional final-confirmation
  language is amended to describe ADR 0010's accepted exception; a new
  "Runtime wiring" section records this slice; every other invariant in that
  record (bounded file policy, security-scoped access lifetime, revalidation,
  fixed script, typed descriptor, one-dispatch) is explicitly reaffirmed as
  unchanged in both modes.
- `docs/decisions/0010-global-automatic-send-authorization-policy.md`:
  "Runtime wiring" section extended to record the attachment slice; header
  summary updated.
- `docs/decisions/README.md`: ADR 0010 index row updated to mention both
  `messages_send` and `messages_send_attachment`.
- `docs/messages-write-plan.md`: new "Runtime wiring for existing-conversation
  picker-based attachments" subsection; the now-stale claim that
  `messages_send_attachment` does not read `sendingMode` was corrected;
  top-of-file status summary updated.
- `docs/project-reports/existing-conversation-text-send-automatic-mode-wiring-2026-08-16.md`:
  one small forward cross-reference added at the end, pointing to this
  report; its accepted evidence above that line is unchanged.
- This report (new).

Explicitly unchanged: `messages_send` text behavior at accepted head
`eb64ee2d...`, verified-new-recipient text composition through
`NSSharingService`, verified-new-recipient attachment behavior (still
unsupported, still fails without composition or fallback), the attachment
tool's input schema (still exactly `recipient`/`recipients`/`chat_id`,
`additionalProperties: false`, no file/path/bytes/mode/confirmation-bypass
argument — verified by a strengthened test), destination matching/resolution
semantics, the bounded file policy (exactly one regular nonempty supported
file, at most 25 MiB, existing type/package/symlink/executable restrictions),
security-scoped access lifetime, AppleScript source and typed file-URL
descriptor dispatch, and `App/Services/MessagesSender.swift`.

## Required focused tests

New tests in `AppTests/MessageAttachmentSendTests.swift`:

1. `testAskBeforeSendingAttachmentRemainsUnchanged` — default mode (no
   explicit `sendingMode` argument) requests exactly one confirmation before
   dispatch.
2. `testAutomaticModeDirectAttachmentSkipsConfirmationButPreservesEveryOtherStep`
   — zero confirmations; the picker still runs; an event log asserts the
   exact remaining sequence (`match`, `automation-status`, `select`, `match`,
   `automation-request`, `addressability`, `attachment-submit`) is unchanged
   except for the missing `elicitation` event; one dispatch.
3. `testAutomaticModeGroupAttachmentSkipsConfirmationAndDispatchesOnceToTheExactResolvedChat`
   — same bypass for an existing group; dispatch targets the exact resolved
   group chat GUID.
4. `testLiveModeChangesAreObservedForAttachmentsWithoutReinitializingTheService`
   — one `Harness`/service/tool instance, two calls: first under Ask Before
   Sending (confirmation requested), then the mode is flipped and the exact
   same tool is called again with the same file (confirmation skipped) —
   proving the mode is read live, not cached at construction.
5. `testPickerCancellationInAutomaticModeSendsNothing` — the picker still
   runs and can still be cancelled in automatic mode; cancellation dispatches
   nothing; automatic mode never bypasses the picker.
6. `testAutomaticModeStaleDestinationFailsClosedWithZeroDispatch` — the
   matched conversation changes between the (skipped) authorization point and
   revalidation; fails with `.staleMatchedConversation` and zero dispatch,
   zero Automation requests.
7. `testAutomaticModeFileChangeFailsClosedWithZeroDispatch` — using the new
   `onSecondResolve` hook to mutate the file at the revalidation checkpoint
   (the automatic-mode equivalent of the existing `onConfirmation`-based file
   mutation tests); fails with `.attachmentChanged` and zero dispatch.
8. `testAutomaticModeAutomationDenialOrUnavailabilityFailsClosedWithZeroDispatch`
   — two sub-cases: denial caught at the non-prompting preflight (which runs
   unconditionally, before the mode branch), and unavailability caught at the
   post-authorization addressability check (which still runs after the
   skipped confirmation); both fail with zero dispatch.
9. `testVerifiedNewRecipientRemainsUnsupportedForAttachmentsInAutomaticMode` —
   a verified-new recipient in automatic mode still fails categorically
   before the picker, composer, or dispatch are ever reached.

Strengthened existing test:

10. `testSchemaAcceptsOnlyDestinationSelectorsAndNoFileOrBodyParameter` — now
    also asserts the schema contains no `mode`/`sending_mode`/`automatic`/
    `bypass`/`confirm`/`confirmation` substring, alongside its existing
    file/path/body checks.

Existing Ask-mode decline/cancel/malformed-confirmation tests, destination/
file-revalidation tests (via the existing `onConfirmation` hook), and every
other existing `MessageAttachmentSendTests`/`MessageSendTests` assertion were
re-run unmodified (aside from the `Harness` helper gaining the
`onSecondResolve` parameter, which defaults to `nil` and has no effect unless
a test supplies it) and continue to pass, evidencing no behavior change for
the default mode.

## Verification evidence

- `swift format lint --strict --recursive App AppTests` — clean (fixed 14
  formatting violations from the new tests with `swift format format
  --in-place`, then re-linted clean).
- `git diff --check` — clean.
- `xcodebuild -scheme iMCP -configuration Debug ... build` — succeeded.
- `xcodebuild -scheme imcp-serverTests -configuration Debug ... test` —
  **275/275 tests passed, 0 failures** (267 at the prior accepted head + 9
  new, net of the 1 obsoleted-and-replaced test: 267 − 1 + 9 = 275, plus the
  strengthened schema test counted in the existing 267). All 10 new/changed
  tests individually confirmed passing via `-only-testing`.
- One test failure was found and fixed during verification, not shipped: the
  first draft of the event-order assertion in test 2 above guessed the wrong
  order for the two preflight events (`automation-status` before `match`);
  the actual code resolves the destination before running the non-prompting
  preflight, so `match` comes first. Corrected after seeing the actual
  `XCTAssertEqual` failure output; re-verified passing.
- Adversarial self-review of the diff performed: confirmed a single shared
  dispatch path (`submitChatAttachment` called exactly once, from one call
  site, regardless of mode); confirmed the authorization branch is scoped to
  exactly the confirmation-request statement; confirmed the picker, file
  validation, and security-scoped access lifetime (`defer { access.release()
  }`) are all unconditional and unaffected by the branch; confirmed the
  confirmation-presentation object (which carries the exact destination and
  file facts) is not even constructed in automatic mode; confirmed
  verified-new-recipient rejection and the tool schema have zero diff from
  this slice; confirmed no new logging of destination, handles, chat IDs, or
  file facts was added.
- **A live app process was found running during this session** — not a
  routine stale leftover: the signed `ManualVerification` build (PID 53998)
  had an established connection from a running MCP Inspector session (PID
  54057, ~16 minutes old). Flagged to the user before touching it; the user
  confirmed it was not in active use and to terminate it. Terminated only
  after that explicit confirmation, then testing proceeded normally.
- Signed `.build/ManualVerification` build regenerated with
  `DEVELOPMENT_TEAM=4LC533SNYD` — succeeded. `codesign --verify --strict`
  valid. Entitlement key set and Hardened Runtime flag identical to every
  earlier signed build in this project's Messages-write history, none
  weakened.
- `CLITests/test_elicitation_proxy.py`'s known unrelated `DYLD_FRAMEWORK_PATH`
  path-fragility issue was left untouched per the task's explicit instruction
  not to spend time on it unless this slice changed that path — it does not.
- `git status --porcelain=v1 -uall` showed exactly the intended files before
  staging.

No automated verification step sent a real message or attachment. No private
Messages or Contacts data was accessed, read, or logged at any point.

## Manual checkpoint to prepare (not executed)

Using the signed build at `.build/ManualVerification/Build/Products/Debug/iMCP.app`,
the user's later checkpoint should verify, without sending any real
attachment unless separately, explicitly authorized for an exact destination
and file:

1. With Sending mode set to **Ask Before Sending**, invoke
   `messages_send_attachment` for an existing conversation, select an
   explicitly chosen supported test file, then cancel the final
   confirmation — verify nothing sends.
2. Without restarting iMCP, switch to **Send Automatically**, invoke
   `messages_send_attachment` for the same explicitly authorized existing
   conversation, select the exact explicitly authorized test file, and
   verify it submits after picker selection **without** a final
   confirmation.
3. Switch back to **Ask Before Sending** and verify a later attachment call
   again presents final confirmation; cancel is sufficient.

Claude did not perform this checkpoint and did not send any real attachment
during implementation or automated verification.

## Explicit statement

Verified-new-recipient attachment sending remains **unsupported** in both
modes — it fails categorically before the picker, exactly as at the prior
accepted head. Attachment sending is **not fully unattended** even in Send
Automatically: the native file picker always runs, and only the post-selection
confirmation step becomes optional.

## Unresolved issues

- Persistent attachment handoff-directory ingress and serialized/base64
  attachment ingress remain separate, unstarted later work.
- Unattended new-recipient sending (text or attachment) remains excluded
  pending a separate safe mechanism.
- The pre-existing `trustedClients` `clientInfo.name`-spoofing gap remains
  unrelated to this slice and untouched.
- `CLITests/test_elicitation_proxy.py`'s `DYLD_FRAMEWORK_PATH` path-fragility
  issue remains unresolved; still out of scope.

## Next bounded action

Supervising review of the exact pushed head on `feat/messages-write-foundation`,
then the manual checkpoint above under the user's own explicit, separate
authorization for any real attachment send. No further implementation is
expected until that review and checkpoint complete.

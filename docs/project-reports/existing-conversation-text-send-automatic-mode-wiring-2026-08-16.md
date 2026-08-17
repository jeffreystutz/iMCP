# Existing-conversation text-send Sending-mode wiring

- Accepted starting head (Settings/model slice, manually accepted): `968b703a901a1ec16056fc98ebab9f03c15c16e6`
- Accepted reviewed branch head including documentation/verification: `b2795b45cce861ffc6b8577d932ca8ab10ee2fef`
- Supervising governance commits present before this slice (trajectory only, no production change): "docs: align Messages safety contract with accepted Sending mode" (`AGENTS.md`), "docs: publish automatic text-send wiring task" (`docs/project-prompts/current-task.md`)
- Implementation commit(s) for this slice: see `git log --oneline` for exact SHAs; this report identifies commits by title rather than embedding a hash that could go stale, per the prior report's cleanup.
- Branch: `feat/messages-write-foundation`

## Summary

Wires the accepted global `MessagesSendingMode` (ADR 0010, `Accepted`) into
**existing-conversation plain-text `messages_send` only**. In **Ask Before
Sending** (factory default), every existing-conversation text send behaves
exactly as it did before this slice: one mandatory final confirmation,
through the existing presentation router, before dispatch. In **Send
Automatically** (explicit user opt-in in Settings), that one confirmation
step is skipped; every other step — destination preparation, non-prompting
addressability preflight, cancellation checks, destination revalidation,
Automation authorization and addressability reverification, the single
dispatch, categorical logging, and the redacted result — is identical, shared
code for both modes. There is no second dispatch path.

Verified-new-recipient composition and `messages_send_attachment` are both
explicitly unaffected by this slice: composition returns before the mode is
ever consulted, and the attachment tool does not read the mode at all, so
attachment submission still always requires its own confirmation.

## Files and symbols changed

- `App/Services/Messages.swift`:
  - `MessageService` gained a new stored property and init parameter,
    `sendingMode: @Sendable () -> MessagesSendingMode`, defaulting to
    `{ MessagesSendingMode.load() }` — evaluated fresh on every call, not
    snapshotted at service construction, so a Settings change takes effect on
    the next call without restarting the service.
  - The `messages_send` tool closure: the unconditional final-confirmation
    request is now wrapped in `switch self.sendingMode() { case
    .askBeforeSending: ... case .sendAutomatically: break }`, placed
    immediately around the existing confirmation-building/request code and
    nowhere else. Every line before and after this switch is unchanged.
  - Updated the doc comment above that switch, which previously said "no mode
    bypasses authorization," to describe both modes accurately.
  - Updated `messages_send`'s public tool description and its `recipient`
    parameter description so they no longer promise confirmation for every
    existing-chat send; both now state that whether confirmation happens
    follows the user's Sending mode setting, which no caller can choose or
    override, and that the new-recipient compose route is unaffected.
  - `messages_send_attachment` and every other tool: byte-for-byte unchanged.
- `AppTests/MessageSendTests.swift`:
  - `sendTool(...)` test helper gained a `sendingMode` parameter defaulting to
    `{ .askBeforeSending }`, so every pre-existing test's behavior stays
    deterministic and explicit rather than depending on ambient
    `UserDefaults.standard` state on the machine running the tests.
  - 8 new tests (see "Required behavior and tests" below).
- `AppTests/MessageAttachmentSendTests.swift`:
  - `Harness.init(...)` gained the same `sendingMode` parameter, defaulting
    the same way.
  - 1 new regression test proving attachment confirmation is unaffected by
    Send Automatically.
- `README.md`: the "Sending Messages" prose and the Messages row of the
  capabilities table no longer claim text sends are always confirmed; both
  now describe the Ask Before Sending / Send Automatically split and note
  attachments are always confirmed regardless of mode.
- `docs/decisions/0010-global-automatic-send-authorization-policy.md`: status
  changed `Proposed` → `Accepted`; new "Runtime wiring" section added.
- `docs/decisions/0002-messages-automation-security-boundary.md`: reconciled
  in place (not superseded) — the "confirmation for every submission, no
  opt-out" language is amended to note ADR 0010's accepted, app-owned,
  never-caller-controlled exception for existing-conversation sends; every
  other invariant in that record (fixed script, descriptor-only input,
  revalidation, TCC, one-dispatch, privacy, truthful result) is explicitly
  reaffirmed as unchanged and still in force in both modes.
- `docs/decisions/README.md`: ADR 0010 index row updated to `Accepted` with
  updated summary text.
- `docs/messages-write-plan.md`: "Automatic-send authorization policy"
  section extended with a "Runtime wiring" subsection; status summary updated.
- `docs/project-reports/global-send-authorization-settings-2026-08-16.md`:
  cleaned the stale self-referential documentation-SHA line (a commit cannot
  accurately embed its own hash) — now identifies commits by title and points
  to `git log` for exact SHAs.
- This report (new).

Explicitly unchanged: tool input schema for `messages_send` (still exactly
`recipient`/`recipients`/`chat_id`/`body`, `additionalProperties: false`, no
mode/automatic/confirmation-bypass argument — verified by a new test),
`App/Services/MessagesSender.swift`, `App/Services/MessagesSendConfirmation.swift`
(aside from the earlier, separately-reported "Automatic" → "Best available"
label rename), destination selection/matching logic, AppleScript source and
descriptor-based dispatch architecture.

## Required behavior and tests

New tests in `AppTests/MessageSendTests.swift`:

1. `testAskBeforeSendingIsTheDefaultAndRequestsExactlyOneFinalConfirmation` —
   default mode (no explicit `sendingMode` argument) requests one confirmation.
2. `testAutomaticModeDirectSendSkipsConfirmationButPreservesEveryOtherStep` —
   zero confirmations; an event log asserts the exact remaining sequence
   (`automation-status`, `automation-request`, `addressability`, `chat-submit`)
   is unchanged except for the missing `elicitation` event; one dispatch.
3. `testAutomaticModeGroupSendSkipsConfirmationAndDispatchesOnceToTheExactResolvedChat`
   — same bypass for an existing group; the exact group is still revalidated
   (`matchCount == 2`); no raw/new-group submission path is ever reached.
4. `testLiveModeChangesAreObservedWithoutReinitializingTheService` — one
   `MessageService`/tool instance, two calls: first under Ask Before Sending
   (confirmation requested), then the mode is flipped and the exact same tool
   closure is called again (confirmation skipped) — proving the mode is read
   live, not cached at construction.
5. `testAutomaticModeStillFailsClosedOnAStaleDestinationWithZeroDispatch` —
   the existing conversation changes between preparation and revalidation;
   fails with `.staleChatIdentifier` and zero dispatch even though
   confirmation was skipped, and zero Automation requests occur.
6. `testAutomaticModeAutomationDenialOrUnavailabilityStillFailsClosedWithZeroDispatch`
   — two sub-cases: denial caught at the non-prompting preflight (which runs
   unconditionally, before the mode branch), and unavailability caught at the
   post-authorization addressability check (which still runs after the
   skipped confirmation); both fail with zero dispatch.
7. `testVerifiedNewRecipientRemainsHumanCompletedCompositionInAutomaticMode` —
   a verified-new recipient in automatic mode still composes through the
   system panel, requests zero iMCP confirmations (as before — that route
   never had one), and never reaches `sender.submit`.
8. `testToolSchemaHasNoModeOrConfirmationBypassInput` — the tool's input
   schema properties are exactly `{recipient, recipients, chat_id, body}`,
   `required == ["body"]`, `additionalProperties == .boolean(false)`.

New test in `AppTests/MessageAttachmentSendTests.swift`:

9. `testSendAutomaticallyDoesNotBypassAttachmentConfirmation` — with
   `sendingMode: { .sendAutomatically }` injected into the attachment
   `Harness`, an attachment submission still requests exactly one
   confirmation and still dispatches only after it.

Existing confirmation decline/cancel/malformed-path tests, and every other
existing `MessageSendTests`/`MessageAttachmentSendTests` assertion, were
re-run unmodified (aside from the `sendTool`/`Harness` helper signature
additions, which default to the pre-existing Ask Before Sending behavior) and
continue to pass, evidencing no behavior change for the default mode.

## Verification evidence

- `swift format lint --strict --recursive App AppTests` — clean (fixed
  formatting violations from the new tests with `swift format format
  --in-place`, then re-linted clean).
- `git diff --check` — clean.
- `xcodebuild -scheme iMCP -configuration Debug ... build` — succeeded.
- `xcodebuild -scheme imcp-serverTests -configuration Debug ... test` —
  **267/267 tests passed, 0 failures** (258 at the prior accepted head + 9
  new). All 9 new tests individually confirmed passing via `-only-testing`.
- Adversarial self-review of the diff performed: confirmed a single shared
  dispatch path (`sender.submit` called exactly once, from one call site,
  regardless of mode); confirmed the authorization branch is scoped to
  exactly the confirmation-request statement and nothing else; confirmed no
  new MCP-reachable argument, prompt field, or elicitation-response field can
  select the mode; confirmed the confirmation-presentation object (which
  carries the exact destination and body) is not even constructed in
  automatic mode, so nothing new is available to leak; confirmed
  `messages_send_attachment` and new-recipient composition have zero diff
  from this slice.
- Signed `.build/ManualVerification` build regenerated with
  `DEVELOPMENT_TEAM=4LC533SNYD` — succeeded. `codesign --verify --strict`
  valid. Entitlement key set and Hardened Runtime flag identical to every
  earlier signed build in this project's Messages-write history, none
  weakened.
- `CLITests/test_elicitation_proxy.py`'s known unrelated
  `DYLD_FRAMEWORK_PATH` path-fragility issue (documented in the prior
  correction pass) was left untouched per the task's explicit instruction not
  to spend time on it unless this slice changed that path — it does not.
- `git status --porcelain=v1 -uall` showed exactly the intended files before
  staging.

No automated verification step sent a real message. No private Messages or
Contacts data was accessed, read, or logged at any point.

## Manual checkpoint to prepare (not executed)

Using the signed build at `.build/ManualVerification/Build/Products/Debug/iMCP.app`,
the user's later checkpoint should verify, without sending any real message
unless separately, explicitly authorized for an exact destination and body:

1. With Sending mode set to **Ask Before Sending**, an existing-conversation
   text call still presents the configured final confirmation; canceling
   sends nothing.
2. With Sending mode set to **Send Automatically**, an explicitly authorized
   existing-conversation text call submits without the final iMCP/MCP
   confirmation.
3. Switching back to **Ask Before Sending** restores confirmation on the very
   next call, without an app restart.
4. New-recipient sends still open the human-controlled Messages compose
   window, unaffected by either mode.
5. Attachment sending still requires its existing picker and confirmation in
   both modes.

Claude did not perform this checkpoint and did not send any real message
during implementation or automated verification.

## Explicit statement

`messages_send_attachment` and verified-new-recipient composition are
**unaffected** by this slice: attachments still always require confirmation,
and new recipients still always open human-controlled Messages composition,
regardless of the global Sending mode. Only existing-conversation plain-text
`messages_send` now honors the mode.

## Unresolved issues

- Wiring `messages_send_attachment` to the Sending mode is separate, later
  work, explicitly excluded from this slice.
- Unattended new-recipient sending remains excluded pending a separate safe
  mechanism, per the earlier architecture investigation.
- The pre-existing `trustedClients` `clientInfo.name`-spoofing gap remains
  unrelated to this slice and untouched.
- `CLITests/test_elicitation_proxy.py`'s `DYLD_FRAMEWORK_PATH` path-fragility
  issue remains unresolved; still out of scope.

## Next bounded action

Supervising review of the exact pushed head on `feat/messages-write-foundation`,
then the manual checkpoint above under the user's own explicit, separate
authorization for any real send. No further implementation is expected until
that review and checkpoint complete; the next candidate slice (attachment
automatic-mode wiring) is intentionally not started here.

**Update:** the text-send manual checkpoint above passed on 2026-08-16, and
attachment automatic-mode wiring is now implemented in a later slice. See
`docs/project-reports/existing-conversation-attachment-send-automatic-mode-wiring-2026-08-16.md`
for that slice's full record; this report's evidence above is unchanged and
still describes only the text-send wiring.

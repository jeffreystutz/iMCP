# Unified `messages_send` tool for text and picker attachments

- Reviewed starting head: `3b9a4a71f33245c511adcdd64f129c24e48f3603` — `feat: honor global Sending mode for existing attachments`
- State of that head: existing-conversation plain-text `messages_send` automatic-mode wiring was fully accepted, including a real runtime checkpoint. Picker-based `messages_send_attachment` automatic-mode wiring passed supervising code review and full automated verification (275/275 tests), but its separate-tool manual runtime checkpoint was **deliberately deferred** after the user chose to consolidate the public API first. That checkpoint is **superseded, not discarded**, by this slice: it now applies to the unified `messages_send` tool's `attachment` payload instead of the removed standalone tool name.
- Supervising governance/prompt commit present before this slice (trajectory only, no production change): "docs: publish unified Messages send-tool task" (`docs/project-prompts/current-task.md`)
- Implementation commit(s) for this slice: identified by title, not embedded hash, per the established convention (a commit cannot accurately embed its own hash) — see `git log --oneline` for exact SHAs.
- Branch: `feat/messages-write-foundation`

## Summary

Consolidates the two public tools `messages_send` (text) and
`messages_send_attachment` (picker-based attachment) into **one** public
`messages_send` tool. Each call now supplies exactly one of a `body` string
payload or an `attachment` object payload (currently only
`{"source": "picker"}`); the destination selectors (`recipient`,
`recipients`, `chat_id`) are unchanged. `messages_send_attachment` is removed
from the public tool list with no alias.

The two already-reviewed internal pipelines are not rewritten: `MessageService`
gained private `sendText`/`sendAttachment` methods containing the same
bodies the two former tool closures contained, reached by a new
`resolveSendPayload` router that enforces exactly-one-payload in code before
any destination lookup, picker, confirmation, Automation request, or
dispatch. Missing/conflicting/malformed payloads fail categorically
(`missingSendPayload` / `conflictingSendPayload` / `invalidAttachmentPayload`)
with zero side effects. The global `MessagesSendingMode` (ADR 0010) continues
to gate the final confirmation step identically for both payload types,
unchanged by this consolidation.

One deliberate behavior change: a call that omits both `body` and
`attachment` now fails immediately instead of eliciting a missing body, since
a missing payload is genuinely ambiguous between the two payload types with
two tools merged into one. This is documented in ADR 0011 and covered by a
dedicated test.

## Schema decision

Selected: one tool, flat optional top-level properties (`body`, `attachment`),
exactly-one-of enforced in code — matching this project's existing
destination-selector convention (`recipient`/`recipients`/`chat_id`) rather
than a JSON Schema `oneOf` construct. `oneOf` was considered (the vendored
`JSONSchema` package supports it, and it is used elsewhere for individual
property value unions) but rejected for this task: expressing "exactly one of
two sibling top-level properties, each with its own nested shape" as `oneOf`
would be a materially more complex schema shape than anything else in this
codebase's tool definitions, with untested MCP-client rendering behavior for
that specific shape. See ADR 0011's "Options considered" for the full
comparison.

## Files and symbols changed

- `App/Services/MessagesSender.swift`: removed the now-dead `MessageSendError`
  cases `inputDeclined`/`inputCancelled` (only reachable from the now-removed
  missing-body elicitation path); kept `inputMalformed`; added
  `missingSendPayload`, `conflictingSendPayload`, `invalidAttachmentPayload`
  with privacy-safe, non-promissory descriptions.
- `App/Services/Messages.swift`:
  - Replaced the two separate `Tool(...)` definitions for `messages_send` and
    `messages_send_attachment` with one `messages_send` `Tool` whose schema
    exposes `recipient`/`recipients`/`chat_id`/`body`/`attachment` and keeps
    top-level `additionalProperties: false`.
  - Added `SendPayload` (`case text(String)` / `case attachment`) and
    `resolveSendPayload(from:)`, which enforces exactly-one-payload and
    validates the `attachment` object shape (must be exactly
    `{"source": "picker"}`) before anything else runs.
  - Added `validateAttachmentPayload` for the nested-shape check.
  - Extracted `sendText` and `sendAttachment` as private methods: the same
    reviewed pipeline bodies the two former closures contained, unmodified
    beyond removing their now-shared destination-resolution code.
  - Merged the two previously duplicated destination-preparation helpers
    (`resolveSendInput` and `resolveAttachmentDestination`) into one shared
    `resolveDestination`, used by both `sendText` and `sendAttachment`.
  - Deleted `ResolvedSendInput`/`resolveSendInput`, removing the missing-body
    elicitation path entirely (see "Deliberate behavior change" below).
  - The unified tool closure does nothing but resolve the payload, resolve
    the destination, and call exactly one of `sendText`/`sendAttachment` —
    there is no shared dispatch code between them beyond destination
    resolution.
- `AppTests/MessageSendTests.swift`: removed
  `testMissingBodyIsElicitedBeforeSeparateConfirmation` and
  `testMissingInputElicitationIsNeverTreatedAsFinalConfirmation` (obsolete —
  elicitation removed); split
  `testDeclinedMissingInputAndEmptyBodyNeverDispatch` into a kept
  `testEmptyBodyStillFailsWithZeroDispatch`; added
  `testNeitherPayloadFailsBeforeAnythingElse`,
  `testBothPayloadsFailBeforeAnythingElse`,
  `testUnsupportedAttachmentSourceAndExtraOrMissingFieldsFailBeforeAnythingElse`,
  `testTextAndAttachmentPayloadsRouteDifferentlyForAVerifiedNewRecipient`;
  fixed `testAuthorizationModelsStaySeparate`'s new-recipient sub-case to
  supply `body` directly; renamed and rewrote
  `testToolSchemaHasNoModeOrConfirmationBypassInput` to
  `testUnifiedToolSchemaExposesBodyAndAttachmentWithNoModeOrBypassInput` with
  full schema assertions for the merged property set.
- `AppTests/MessageAttachmentSendTests.swift`: `Harness.init` and
  `attachmentTool()` now target `"messages_send"`; `call()` gained an
  `autoAttach` parameter that auto-injects `attachment: {"source": "picker"}`
  when a test supplies neither `body` nor `attachment`, so the ~45
  pre-existing attachment-pipeline tests kept working with no per-test
  changes; removed 3 obsolete structural tests (separate-tool existence
  checks) and replaced them with one
  `testUnifiedToolAdvertisesAttachmentGuaranteesAndNoSeparateAttachmentToolExists`.
- `AppTests/ContactConversationSearchTests.swift`: removed
  `"messages_send_attachment"` from the expected advertised tool-name array.
- `AppTests/MessagesChatListingTests.swift`:
  `testExistingFetchAndSendContractsRemainUnchanged` updated for the merged
  schema property set; its `required` assertion changed from `["body"]` to
  `nil` (payload optionality is enforced in code now, not by `required`).
- `docs/decisions/0011-unified-messages-send-tool.md` (new): Accepted ADR
  recording this decision, including the schema-construct comparison, the
  deliberate elicitation-removal rationale, and an explicit "What this does
  not change" section reaffirming ADR 0009's and ADR 0010's still-binding
  invariants.
- `docs/decisions/0009-attachment-only-existing-chat-submission.md`: `Status`
  changed `Proposed` → `Superseded`, `Superseded by: ADR 0011`; a new
  paragraph clarifies the superseding is narrow (public-tool-surface only)
  and every security/validation boundary carries forward unchanged.
- `docs/decisions/0010-global-automatic-send-authorization-policy.md`: intro
  paragraph and the end of the "Runtime wiring" section updated to describe
  Sending mode against the unified tool; the two paragraphs narrating what
  each historical slice did are left as accurate past-tense description.
- `docs/decisions/README.md`: updated the 0009 and 0010 rows, added the 0011
  row.
- `docs/messages-write-plan.md`: status summary, "Attachment submission"
  section header/intro, and the "Runtime wiring for existing-conversation
  picker-based attachments" section updated to describe the unified tool;
  historical narration of what each slice did at the time is preserved with
  added context rather than rewritten.
- `docs/project-reports/existing-conversation-text-send-automatic-mode-wiring-2026-08-16.md`
  and
  `docs/project-reports/existing-conversation-attachment-send-automatic-mode-wiring-2026-08-16.md`:
  one small forward-reference paragraph appended to each, pointing to this
  report; their accepted evidence above those additions is unchanged.
- This report (new).

Explicitly unchanged: the destination-resolution, revalidation, Automation/
addressability, bounded file validation, security-scoped access lifetime,
fixed AppleScript sender, typed-descriptor dispatch, one-dispatch/no-retry
semantics, privacy redaction, and submitted-not-delivered truthfulness of
both pipelines; verified-new-recipient text composition through
`NSSharingService`; verified-new-recipient attachment rejection (still
unsupported, still fails before the picker); `App/Services/MessagesSender.swift`
beyond the error-case changes above; and every read-only Messages/Contacts
behavior.

## Deliberate behavior change

A call that supplies neither `body` nor `attachment` now fails immediately
with `missingSendPayload` instead of eliciting a missing body. The prior
standalone text tool could safely elicit a missing `body` because text was
the only possible interpretation; with two payload shapes merged into one
tool, a missing payload is genuinely ambiguous between "forgot body" and
"forgot attachment," and guessing would be exactly the invented
payload-type elicitation this design avoids. Covered by
`testNeitherPayloadFailsBeforeAnythingElse` and documented in ADR 0011.

## Verification evidence

- `swift format lint --strict --recursive App AppTests` — clean (fixed 14
  formatting violations from the new/changed tests with `swift format format
  --in-place`, then re-linted clean).
- `git diff --check` — clean.
- `xcodebuild -scheme imcp-serverTests -configuration Debug ... test` —
  **275/275 tests passed, 0 failures**, a net-zero test-count change from the
  reviewed starting head (tests removed for now-obsolete standalone-tool/
  elicitation behavior were replaced one-for-one, and in most cases more than
  one-for-one, by consolidation-specific coverage).
- `xcodebuild -scheme iMCP -configuration Debug ... build` — succeeded.
- Adversarial self-review performed against: payload ambiguity (confirmed
  `resolveSendPayload` returns a non-optional two-case enum consulted by a
  two-case `switch`, each arm returning immediately from exactly one of
  `sendText`/`sendAttachment`; neither method calls the other); a call
  reaching both pipelines (structurally impossible per the above); duplicated
  dispatch (each pipeline retains exactly one dispatch call site, unchanged
  from the reviewed starting head); text/attachment fallback (none exists —
  confirmed by `testTextAndAttachmentPayloadsRouteDifferentlyForAVerifiedNewRecipient`,
  which shows the identical verified-new-recipient destination handled
  differently by payload); caller-controlled Sending mode (schema test
  confirms no `mode`/`bypass`/`confirm`-family property exists); picker
  bypass (the picker remains unconditional in the attachment pipeline,
  untouched by this slice); weakened destination/file race checks (the
  revalidation code paths are the same reviewed lines, only relocated into
  `resolveDestination`); schema accepting file paths/bytes (schema test
  asserts the exact property set and the absence of forbidden substrings);
  privacy leaks (no new logging was added; the new `MessageSendError` cases'
  descriptions carry no caller data); changed new-recipient behavior (none —
  both new-recipient behaviors are reached exactly as before, only through
  the merged entry point).
- Signed `.build/ManualVerification` build regenerated with
  `DEVELOPMENT_TEAM=4LC533SNYD`, `CODE_SIGN_IDENTITY="Apple Development"`,
  `CODE_SIGN_STYLE=Automatic` (Debug's project defaults set
  `CODE_SIGNING_ALLOWED=NO`, so both signing-enablement flags must be
  overridden alongside the identity/team, matching the established
  procedure). `codesign --verify --strict` — valid on disk, satisfies its
  Designated Requirement. `TeamIdentifier=4LC533SNYD`, Hardened Runtime flag
  present (`flags=0x10000(runtime)`). Entitlement key set (App Sandbox,
  Apple Events automation with the `com.apple.MobileSMS` exception,
  user-selected read-write for the picker, the Messages directory temporary
  exception, app-scope bookmarks) is identical to every earlier signed build
  in this project's Messages-write history — none weakened or added to by
  this slice.
- `CLITests/test_elicitation_proxy.py`'s known unrelated
  `DYLD_FRAMEWORK_PATH` path-fragility issue was left untouched — this slice
  does not change that path.
- No automated verification step sent a real message or attachment. No
  private Messages or Contacts data was accessed, read, or logged at any
  point.

## Manual checkpoint to prepare (not executed)

Using the signed build at
`.build/ManualVerification/Build/Products/Debug/iMCP.app`, the next human
checkpoint should verify, without sending any real message/attachment unless
separately, explicitly authorized for an exact destination and file:

1. With Sending mode set to **Ask Before Sending**, call `messages_send` with
   a `body` payload for an existing conversation and cancel the final
   confirmation — verify nothing sends.
2. Still in Ask Before Sending, call `messages_send` with an `attachment`
   payload for an existing conversation, select an explicitly chosen
   supported test file, then cancel the final confirmation — verify nothing
   sends.
3. Without restarting iMCP, switch to **Send Automatically**: a `body`-payload
   call to an explicitly authorized existing conversation submits without a
   final confirmation, and an `attachment`-payload call to the same
   conversation with an explicitly authorized test file submits after picker
   selection without a final confirmation.
4. Switch back to **Ask Before Sending** and verify a later call of either
   payload type again presents its final confirmation; cancel is sufficient.
5. Verify `messages_send_attachment` is no longer a callable/advertised tool
   name from a connected MCP client.

Claude did not perform this checkpoint and did not send any real message or
attachment during implementation or automated verification.

## Explicit statement

Verified-new-recipient sending is unaffected by this consolidation in either
payload: text still opens human-controlled `NSSharingService` composition,
and attachment still fails categorically before any picker/composer/dispatch.
Attachment sending remains not fully unattended even in Send Automatically —
the native picker always runs. `messages_send_attachment` no longer exists as
a tool name; there is no alias or deprecation shim.

## Unresolved issues

- Handoff-directory and serialized/base64 attachment ingress sources remain
  separate, unstarted later work (the `attachment.source` namespace exists
  for exactly this extension).
- Unattended new-recipient sending (text or attachment) remains excluded
  pending a separate safe mechanism.
- The pre-existing `trustedClients` `clientInfo.name`-spoofing gap remains
  unrelated to this slice and untouched.
- `CLITests/test_elicitation_proxy.py`'s `DYLD_FRAMEWORK_PATH` path-fragility
  issue remains unresolved; still out of scope.

## Next bounded action

Supervising review of the exact pushed head on `feat/messages-write-foundation`,
then the unified manual checkpoint above under the user's own explicit,
separate authorization for any real send. No further implementation is
expected until that review and checkpoint complete.

**Update:** the unified `messages_send` tool this report describes was
implemented and passed supervising code review and full automated
verification, but it was **never manually accepted**: before the human
runtime checkpoint above was performed, the user explicitly reversed the
consolidation decision (ADR 0011 marked Superseded). The public Messages
send surface is now split again, under new names,
`message_send_text`/`message_send_attachment` (ADR 0012, Accepted). This
report's evidence above is unchanged and still accurately describes the
unified tool as it existed at this slice's pushed head; see
`docs/project-reports/split-messages-send-tools-2026-08-16.md` for the
correction's full record.

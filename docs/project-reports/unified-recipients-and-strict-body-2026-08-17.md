# Unified `recipients` destination field and strict `message_send_text.body`

- Starting head: `fa5733b91f383eba0b8e257f1132bacc58e98aae` — `refactor: split Messages text and attachment send tools`
- State of that head: passed supervising code review, automated verification, and signed-build verification, but was **not fully manually accepted**. The 2026-08-17 human checkpoint explicitly rejected two pieces of that shipped public behavior:
  1. `message_send_text`'s missing-body MCP form elicitation;
  2. the separate singular `recipient` / plural `recipients` destination properties on both send tools.
- Supervising governance/prompt commit present before this slice (trajectory only, no production change): "docs: publish Messages destination-input correction task" (`docs/project-prompts/current-task.md`)
- Implementation commit(s) for this slice: identified by title, not embedded hash, per the established convention (a commit cannot accurately embed its own hash) — see `git log --oneline` for exact SHAs.
- Branch: `feat/messages-write-foundation`

## Summary

Both public Messages send tools, `message_send_text` and
`message_send_attachment`, now accept exactly one of:

- `recipients` — a scalar exact handle (string) or a non-empty array of exact
  handles, expressed via JSON Schema `oneOf`, matching this project's
  existing `showPointsOfInterest` scalar-or-array precedent in
  `App/Services/Maps.swift`;
- `chat_id` — unchanged.

The singular `recipient` property is removed entirely, with no alias. A
scalar handle and a one-item array express identical direct-recipient
intent and are validated/dispatched identically. An array of two or more
elements is exact-existing-group intent, unchanged from before: every
element must be a valid exact handle, and after normalization there must be
at least two distinct handles, or the call fails
(`insufficientGroupParticipants`) rather than silently degenerating into a
direct send. An empty array now fails explicitly (`emptyRecipients`), a new
failure mode that the prior `minItems: 2` schema constraint used to prevent
structurally.

`message_send_text.body` is now a hard requirement. Missing-body MCP form
elicitation is removed completely: a missing, non-string, or empty body
fails immediately, before any destination lookup, confirmation request,
composition, or dispatch, and never issues an elicitation request. Final
send confirmation (Ask Before Sending vs. Send Automatically) is completely
unaffected — it is a separate, later step in `sendText` that this
correction never touches.

Both tools' previously duplicated destination-selector parsing is merged
into one shared `resolveDestination`/`parseRecipients` pair, since removing
`recipient` left the two tools with byte-identical destination logic.
`sendText` and `sendAttachment` — the actual pipeline implementations — are
unmodified.

## Files and symbols changed

- `App/Services/MessagesSender.swift`: removed the now-dead
  `MessageSendError.inputDeclined`/`.inputCancelled` cases (only reachable
  from the removed missing-body elicitation branch; confirmed via repository
  search that no other production path referenced either); added
  `MessageSendError.emptyRecipients`; updated `missingInput`'s and
  `invalidDestination`'s descriptions to no longer name a singular
  `recipient`; updated `invalidRecipient`'s description to describe
  `recipients` entries.
- `App/Services/Messages.swift`:
  - Both `message_send_text` and `message_send_attachment` schemas replace
    their separate `recipient`/`recipients` properties with one `recipients`
    property using `.oneOf([.string(...), .array(...)])`; `chat_id` is
    unchanged. Tool descriptions and parameter descriptions updated to match
    (no more promise of missing-body elicitation on the text tool's
    description).
  - `resolveSendInput` (text) rewritten: no longer `async`, no longer takes
    `context`; it now calls the shared `resolveDestination`, then requires
    `body` directly (`missingInput` if absent, `inputMalformed` if
    non-string) — no elicitation call of any kind.
  - `resolveAttachmentDestination` renamed to the now-shared
    `resolveDestination`, used by both tools; it and the new
    `parseRecipients(_:)` helper implement the scalar-or-one-item-array ==
    direct-intent / two-or-more-item-array == group-intent parsing described
    above.
  - `sendText` and `sendAttachment` themselves are byte-for-byte unchanged.
- `AppTests/MessageSendTests.swift`: mechanically renamed all `"recipient":`
  argument-dictionary keys to `"recipients":` (safe 1:1 rename — the new
  scalar `recipients` form is expressed identically to the old scalar
  `recipient` form); removed `testMissingBodyIsElicitedBeforeSeparateConfirmation`
  and `testMissingInputElicitationIsNeverTreatedAsFinalConfirmation`
  (elicitation removed); replaced `testDeclinedMissingInputAndEmptyBodyNeverDispatch`
  with `testMissingBodyFailsImmediatelyWithoutEverEliciting` and
  `testMalformedAndEmptyBodyNeverDispatch`; rewrote
  `testDestinationFormsAndGroupValidation` for the unified selector (removed
  the now-nonsensical `recipient`+`recipients` conflict case; added empty-array,
  non-string-element, and malformed-scalar cases; moved the former
  one-item-array `insufficientGroupParticipants` case out, since a one-item
  array is now direct intent); added
  `testScalarAndOneItemArrayRecipientsProduceEquivalentDirectBehavior` and
  `testOneItemArrayRecipientVerifiedNewStillComposes`; fixed
  `testAuthorizationModelsStaySeparate`'s new-recipient sub-case to supply
  `body` directly instead of relying on elicitation; updated
  `testToolSchemaHasNoModeOrConfirmationBypassInput` for the merged property
  set and added a forbidden-substring check for `"recipient"`.
- `AppTests/MessageAttachmentSendTests.swift`: same mechanical
  `"recipient":` → `"recipients":` rename; updated
  `testSchemaAcceptsOnlyDestinationSelectorsAndNoFileOrBodyParameter` for the
  merged property set and added a forbidden-substring check for
  `"recipient"`; rewrote `testExactlyOneDestinationSelectorIsRequired` for
  the unified selector; rewrote `testInvalidAndInexactDestinationsFailBeforeThePicker`
  to move its former one-item-array case out (now direct intent, not a
  failure) and add empty-array (`emptyRecipients`) and non-string-element
  cases; added `testOneItemArrayRecipientsBehavesIdenticallyToScalar`.
- `AppTests/MessagesChatListingTests.swift`:
  `testExistingFetchAndSendContractsRemainUnchanged`'s expected schema
  property set updated to drop `recipient`.
- `docs/decisions/0013-unified-recipients-and-strict-body.md` (new): Accepted
  ADR recording this correction, including the `oneOf` schema-construct
  precedent, the direct/group intent-mapping rules, the missing-body
  elicitation removal rationale, and an explicit "What this does not change"
  section reaffirming ADR 0009's, ADR 0010's, and ADR 0012's still-binding
  invariants (including that the attachment-ingress redesign remains
  separately gated future work).
- `docs/decisions/0012-split-messages-send-tools.md`: `Status` changed
  `Accepted` → `Superseded`; `Superseded by: ADR 0013 (its destination-field
  shape and missing-body elicitation only)`; a new note clarifies the
  two-tool split and carried-forward safety contracts are not reopened.
- `docs/decisions/0010-global-automatic-send-authorization-policy.md`: fixed
  a stale `recipient` parameter reference; added a paragraph recording that
  this correction did not touch Sending-mode wiring.
- `docs/decisions/README.md`: ADR 0012 row updated to "Superseded by
  [0013]"; new ADR 0013 row added.
- `docs/messages-write-plan.md`: status summary, the existing-conversation
  destination-selector paragraphs, the "First send behavior" bullet list,
  the attachment-submission destination-selector bullet, and both "Runtime
  wiring" subsections updated to describe the unified `recipients` field and
  the removed elicitation; historical narration of what earlier slices did
  at the time is preserved with added context rather than rewritten.
- This report (new).

Explicitly unchanged: `sendText`, `sendAttachment`, destination resolution/
revalidation, the bounded file validation policy, security-scoped access
lifetime, the fixed AppleScript sender, typed-descriptor dispatch,
one-dispatch/no-retry semantics, privacy redaction, submitted-not-delivered
truthfulness, and the global `MessagesSendingMode` wiring for both tools.
Final send confirmation (Ask Before Sending / Send Automatically) is
unaffected — a separate, later step this correction never touches.

## Verification evidence

- `swift format lint --strict --recursive App AppTests` — clean.
- `git diff --check` — clean.
- `xcodebuild -scheme imcp-serverTests -configuration Debug ... test` —
  **277/277 tests passed, 0 failures**, a net increase of two over the
  starting head's 275, reflecting new scalar/array-equivalence and
  degenerate-group coverage rather than any removed safety assertion.
- `xcodebuild -scheme iMCP -configuration Debug ... build` — succeeded.
- Signed `.build/ManualVerification` build regenerated with
  `DEVELOPMENT_TEAM=4LC533SNYD`, `CODE_SIGN_IDENTITY="Apple Development"`,
  `CODE_SIGN_STYLE=Automatic`, `CODE_SIGNING_ALLOWED=YES`,
  `CODE_SIGNING_REQUIRED=YES`. `codesign --verify --strict` — valid on disk,
  satisfies its Designated Requirement. `TeamIdentifier=4LC533SNYD`,
  Hardened Runtime flag present. Entitlement key set (App Sandbox, Apple
  Events automation with the `com.apple.MobileSMS` exception, user-selected
  read-write for the picker, the Messages directory temporary exception,
  app-scope bookmarks) is identical to every earlier signed build in this
  project's Messages-write history — none weakened or added to by this
  correction.
- A blocking duplicate-bundle-ID situation was found and resolved before the
  first test run this session: a `ManualVerification` build (PID 20960) with
  an established connection to an `imcp-server` process (PID 20997) whose
  parent was the same MCP Inspector process the user had already confirmed
  earlier in this session was not in active use. Both were terminated before
  proceeding, consistent with that earlier explicit confirmation.
- Adversarial self-review performed against: a hidden singular-recipient
  alias (none — confirmed by a strengthened schema test asserting the exact
  JSON key token `"recipient"` is absent from both tools' encoded schemas);
  scalar/array disagreement (a dedicated test in each tool's suite asserts a
  scalar handle and a one-item array dispatch identically); group duplicate
  degeneration into direct intent (the existing `distinct.count >= 2` guard
  is unchanged and still runs for every array with two or more raw
  elements; a dedicated test supplies two normalization-colliding entries
  and asserts `insufficientGroupParticipants`, not success); malformed body
  accidentally reaching confirmation/composition (`resolveSendInput` throws
  before `sendText` is ever called, so no destination lookup, confirmation,
  composition, or dispatch can occur for any invalid body); loss of final
  confirmation because missing-body elicitation was removed (elicitation and
  final confirmation are different steps using different code paths;
  `sendText`'s confirmation branch is unmodified and covered by existing
  passing tests); changed new-recipient behavior (none — both routes are
  reached exactly as before, only through the unified `recipients` field);
  weakened destination/file race checks (the revalidation code is the same
  reviewed lines, unmoved); caller-controlled automatic bypass (schema tests
  confirm no `mode`/`bypass`/`confirm`-family property exists on either
  tool); privacy leak (no new logging was added; the new
  `MessageSendError.emptyRecipients` case's description carries no caller
  data).
- `CLITests/test_elicitation_proxy.py`'s known unrelated
  `DYLD_FRAMEWORK_PATH` path-fragility issue was left untouched — this slice
  does not change that path.
- No automated verification step sent a real message or attachment. No
  private Messages or Contacts data was accessed, read, or logged at any
  point.

## Unresolved attachment-ingress milestone

The user has already decided that ordinary `message_send_attachment`
execution should eventually be programmatic rather than picker-driven: a
persistent user-approved filesystem root with a dedicated staging area as
the primary case, plus bounded serialized attachment content staged into
app-owned temporary storage, with the native picker retained only for
Settings/onboarding grants. None of that was implemented in this task, as
explicitly instructed. The current native picker remains, deliberately, the
reviewed downstream-execution scaffold for `message_send_attachment` until
that redesign's own UX/security/entitlement acceptance boundary is settled
separately.

## Manual checkpoint to prepare (not executed)

Using the signed build at
`.build/ManualVerification/Build/Products/Debug/iMCP.app`, the next human
checkpoint should verify, without sending any real message/attachment unless
separately, explicitly authorized for an exact destination and body/file:

1. Refresh/reconnect the MCP client and inspect `message_send_text` /
   `message_send_attachment`: confirm `recipient` is absent, `recipients` is
   represented as scalar-or-array, and `chat_id` remains the alternative.
2. Call `message_send_text` without `body`; verify an immediate error and
   that no missing-body form appears.
3. In Ask Before Sending, call `message_send_text` with a scalar
   `recipients` value and a deliberately chosen test body to an explicitly
   authorized existing conversation; verify the normal final send
   confirmation appears, then cancel.
4. If the client can conveniently express it, repeat with a one-item
   `recipients` array and verify it reaches the same final confirmation;
   cancel.

The current attachment picker should not be used as a product-acceptance
test — attachment ingress remains explicitly pending redesign. Claude did
not perform this checkpoint and did not send any real message or attachment
during implementation or automated verification.

## Next bounded action

Supervising review of the exact pushed head on `feat/messages-write-foundation`,
then the compact manual checkpoint above under the user's own explicit,
separate authorization for any real send. No further implementation is
expected until that review and checkpoint complete; the attachment-ingress
redesign (persistent filesystem root, staging, serialized content) remains
separate future work with its own acceptance boundary.

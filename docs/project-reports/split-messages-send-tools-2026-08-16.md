# Split Messages send tools — `message_send_text` and `message_send_attachment`

- Starting head: `801f3418f4a713d1ffa9aa784d972c3452952eb5` — `refactor: unify Messages text and attachment send tool`
- State of that head: the unified public `messages_send` tool (ADR 0011) was implemented, passed supervising structural/code review, and passed full automated verification (275/275 tests), but was **never manually accepted**. Before the human runtime checkpoint for that design, the user explicitly reversed the decision and asked for the public Messages send surface to be split again, under new exact names.
- Supervising governance/prompt commit present before this slice (trajectory only, no production change): "docs: publish split Messages send-tool correction task" (`docs/project-prompts/current-task.md`)
- Implementation commit(s) for this slice: identified by title, not embedded hash, per the established convention (a commit cannot accurately embed its own hash) — see `git log --oneline` for exact SHAs.
- Branch: `feat/messages-write-foundation`

## Summary

Reverses ADR 0011's unified `messages_send` tool per the user's explicit
decision, made before manual acceptance. The public Messages send surface is
now exactly two tools, `message_send_text` and `message_send_attachment`
(ADR 0012, Accepted) — the pre-consolidation architecture, under new final
names. Neither the old plural `messages_send`/`messages_send_attachment`
names nor a unified/legacy alias are retained.

`message_send_text` restores the pre-consolidation schema (destination
selectors plus required `body`) and, critically, restores the pre-consolidation
**missing-body MCP form elicitation** that ADR 0011 had deliberately removed:
because payload type is unambiguous again (text is the only thing this tool
can carry), a caller that supplies a valid destination but omits `body` is
asked for it, and accepting that elicitation supplies the body without being
final send authorization by itself.

`message_send_attachment` restores the pre-consolidation attachment-only
schema (destination selectors only, no body/caption/path/source argument of
any kind) and its already-reviewed picker pipeline, unmodified.

Both tools continue to read the same live, app-owned `MessagesSendingMode`
(ADR 0010) exactly as before this correction: Ask Before Sending requires the
existing final confirmation; Send Automatically skips only that confirmation,
never the elicitation, the picker, or any revalidation/Automation/
addressability step. No behavior in either pipeline's dispatch, revalidation,
or authorization logic changed — only the public tool declarations and the
destination/body parsing that feeds them.

## Files and symbols changed

- `App/Services/MessagesSender.swift`: restored `MessageSendError.inputDeclined`/
  `.inputCancelled` (removed by ADR 0011, needed again by the restored
  missing-body elicitation); removed the now-unused `missingSendPayload`/
  `conflictingSendPayload`/`invalidAttachmentPayload` cases ADR 0011 had
  added for its payload router, which no longer exists. This file is now
  byte-for-byte identical to its pre-consolidation state at `3b9a4a71...`.
- `App/Services/Messages.swift`:
  - Replaced the single unified `messages_send` `Tool` with two: `message_send_text`
    (schema: destination selectors + required `body`; description restored to
    the pre-consolidation text) and `message_send_attachment` (schema:
    destination selectors only; description restored to the pre-consolidation
    text, cross-references updated to name `message_send_text`).
  - Restored `ResolvedSendInput`/`resolveSendInput(_:context:)` — the
    pre-consolidation destination-validation-plus-missing-body-elicitation
    helper — feeding `message_send_text`'s closure, which now calls the
    unchanged `sendText` pipeline directly.
  - Restored `resolveAttachmentDestination(_:)` (renamed back from the
    unified router's shared `resolveDestination`) feeding
    `message_send_attachment`'s closure, which calls the unchanged
    `sendAttachment` pipeline directly.
  - Removed `resolveSendPayload`, `validateAttachmentPayload`, and the
    `SendPayload` enum — ADR 0011's payload router, no longer needed once
    each tool has its own schema.
  - `sendText` and `sendAttachment` themselves are unmodified: the same
    reviewed pipeline bodies carried through the original standalone tools,
    then ADR 0011's consolidation, and now this reversal, without ever being
    rewritten.
- `AppTests/MessageSendTests.swift`, `AppTests/MessageAttachmentSendTests.swift`,
  `AppTests/ContactConversationSearchTests.swift`,
  `AppTests/MessagesChatListingTests.swift`: restored to their exact
  pre-consolidation content at `3b9a4a71...` (confirmed identical by diff
  before editing), then the tool-name literals `"messages_send"` and
  `"messages_send_attachment"` were mechanically renamed to
  `"message_send_text"` and `"message_send_attachment"` throughout,
  including in doc comments and one test function name
  (`testMessagesSendRemainsSeparateAndTextOnly` ->
  `testMessageSendTextRemainsSeparateAndTextOnly`) for consistency. No test
  logic, ordering assertion, or coverage was weakened, added, or removed
  beyond this rename — this restores the exact previously reviewed test
  suite, including its schema tests (`testToolSchemaHasNoModeOrConfirmationBypassInput`,
  `testSchemaAcceptsOnlyDestinationSelectorsAndNoFileOrBodyParameter`, the
  latter already asserting the absence of `mode`/`bypass`/`confirm`-family
  substrings), its missing-body elicitation tests, and its full Ask/Automatic
  fail-closed matrix for both tools.
- `docs/decisions/0012-split-messages-send-tools.md` (new): Accepted ADR
  recording this reversal, including why the split is intentional again (the
  platform's one-parameter-per-`send` constraint, restored missing-body
  elicitation safety, and the user's explicit choice), and an explicit "What
  this does not change" section reaffirming ADR 0009's and ADR 0010's
  still-binding invariants.
- `docs/decisions/0011-unified-messages-send-tool.md`: `Status` changed
  `Accepted` -> `Superseded`, `Superseded by: ADR 0012`; a new note explains
  the unified tool was implemented and code-reviewed but never manually
  accepted before the user's reversal.
- `docs/decisions/0009-attachment-only-existing-chat-submission.md`: its
  existing "Superseded by ADR 0011" supersession chain is left exactly as
  is — it accurately records what happened — with one added note explaining
  that ADR 0012 is a further, later decision that independently carries
  forward this record's security/validation contract under the restored
  attachment tool's new name.
- `docs/decisions/0010-global-automatic-send-authorization-policy.md`: intro
  paragraph and "Runtime wiring"/References sections updated to describe the
  final two-tool surface and record ADR 0011's reversal; no Sending-mode
  behavior changed.
- `docs/decisions/README.md`: ADR 0011 row updated to "Superseded by
  [0012]"; new ADR 0012 row added; ADR 0010 row's summary updated to name
  both final tools.
- `docs/decisions/0007-reusable-search-operations-behind-mcp-adapters.md`,
  `docs/messages-conversation-search.md`, `docs/messages-conversation-index.md`:
  small terminology fixes — these still-binding documents named the
  send-side tool generically; their `messages_send` mentions are updated to
  name `message_send_text`/`message_send_attachment` so they stay accurate
  after this rename. No decision or behavior they describe changed.
- `docs/messages-write-plan.md`: status summary, "Hybrid routing", "First
  send behavior", "Read-only conversation listing", "Recipient and
  conversation discovery", "Attachment submission", and both "Runtime
  wiring" subsections updated to describe the final two-tool surface;
  historical narration of what ADR 0011's unified tool did while it existed
  is preserved, not rewritten.
- `docs/project-reports/unified-messages-send-tool-2026-08-16.md`: one small
  forward-reference paragraph appended, pointing to this report; its
  accepted evidence above that line is unchanged (it still accurately
  describes the unified tool as it existed at its own pushed head).
- This report (new).

Explicitly unchanged: `sendText`, `sendAttachment`, destination resolution/
revalidation, the bounded file validation policy, security-scoped access
lifetime, the fixed AppleScript sender, typed-descriptor dispatch,
one-dispatch/no-retry semantics, privacy redaction, submitted-not-delivered
truthfulness, and the global `MessagesSendingMode` wiring for both tools.

## Restored elicitation behavior

`message_send_text` restores the pre-ADR-0011 missing-body MCP form
elicitation exactly: destination validity (`recipient`/`recipients`/`chat_id`,
exactly one supplied) is checked before eliciting; if `body` is present the
elicitation never runs; if absent, an MCP form request asks for it;
`.decline`/`.cancel` fail with `inputDeclined`/`inputCancelled` and zero
submission; `.accept` supplies the body from the elicitation response. Only
after a non-empty body is resolved does the existing-conversation
destination preparation, addressability preflight, and Sending-mode-gated
final confirmation (or its Send Automatically skip) run — the elicitation
itself is never treated as final send authorization, exactly as ADR 0002
requires.

## Verification evidence

- `swift format lint --strict --recursive App AppTests` — clean.
- `git diff --check` — clean.
- `xcodebuild -scheme imcp-serverTests -configuration Debug ... test` —
  **275/275 tests passed, 0 failures** — the identical count to the last
  reviewed pre-consolidation head (`3b9a4a71...`), since this correction
  restores rather than extends that coverage.
- `xcodebuild -scheme iMCP -configuration Debug ... build` — succeeded.
- Signed `.build/ManualVerification` build regenerated with
  `DEVELOPMENT_TEAM=4LC533SNYD`, `CODE_SIGN_IDENTITY="Apple Development"`,
  `CODE_SIGN_STYLE=Automatic`, `CODE_SIGNING_ALLOWED=YES`,
  `CODE_SIGNING_REQUIRED=YES` (Debug's project defaults disable signing, so
  both enablement flags must be overridden alongside the identity/team).
  `codesign --verify --strict` — valid on disk, satisfies its Designated
  Requirement. `TeamIdentifier=4LC533SNYD`, Hardened Runtime flag present.
  Entitlement key set (App Sandbox, Apple Events automation with the
  `com.apple.MobileSMS` exception, user-selected read-write for the picker,
  the Messages directory temporary exception, app-scope bookmarks) is
  identical to every earlier signed build in this project's Messages-write
  history — none weakened or added to by this correction.
- Adversarial self-review performed against: any legacy/unified alias still
  advertised (none — `MessageService.tools` exposes exactly
  `message_send_text` and `message_send_attachment` among the send-capable
  tools, verified by a restored structural test); a tool reaching the wrong
  internal pipeline (structurally impossible — each tool's closure calls
  exactly one of `sendText`/`sendAttachment` directly, with no shared
  payload-resolution router left to regress); text missing-body elicitation
  being mistaken for final authorization (the restored `resolveSendInput`
  only ever returns a resolved `body`; the separate Sending-mode-gated
  confirmation step in `sendText` is unchanged and still runs afterward for
  every existing-conversation submission); caller-controlled automatic-send
  bypass (no schema property named `mode`/`bypass`/`confirm`-family exists on
  either tool, verified by the restored strengthened schema test); picker
  bypass (the picker remains unconditional in `sendAttachment`, untouched by
  this slice); weakened destination/file race checks (the revalidation code
  is the same reviewed lines, unmoved); two dispatches from one MCP
  operation (each tool has exactly one dispatch call site, as before);
  retry/fallback (none — unchanged); privacy leak (no new logging; the
  restored `MessageSendError` cases carry no caller data); changed
  new-recipient behavior (none — both routes are reached exactly as before,
  through the restored tool names).
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

1. Confirm the connected MCP client advertises `message_send_text` and
   `message_send_attachment`, and does not advertise `messages_send`,
   `messages_send_attachment`, or any unified/legacy alias.
2. With Ask Before Sending selected, invoke `message_send_text` for an
   existing conversation and cancel its final confirmation — verify nothing
   sends. If practical, also exercise omitted-body elicitation
   non-destructively, then cancel the final confirmation.
3. Still in Ask mode, invoke `message_send_attachment`, choose an explicitly
   selected supported file, then cancel final confirmation — verify nothing
   sends.
4. Without restarting iMCP, switch to Send Automatically and perform one
   explicitly authorized attachment submission through
   `message_send_attachment` — the picker still appears, final confirmation
   does not.
5. Switch back to Ask Before Sending and verify a later attachment
   invocation presents final confirmation again — cancel is sufficient.

No additional real text send is required merely because the public text tool
was renamed; its automatic-mode runtime path was already accepted (at
`eb64ee2d...`) before either the consolidation or this reversal, and neither
touched that pipeline's dispatch behavior. Claude did not perform this
checkpoint and did not send any real message or attachment during
implementation or automated verification.

## Explicit statement

Verified-new-recipient sending is unaffected by this correction in either
tool: text still opens human-controlled `NSSharingService` composition, and
attachment still fails categorically before any picker/composer/dispatch.
Attachment sending remains not fully unattended even in Send Automatically —
the native picker always runs. `messages_send`, `messages_send_attachment`,
and any unified alias no longer exist as tool names; there is no
compatibility shim.

## Unresolved issues

- Handoff-directory and serialized/base64 attachment ingress sources remain
  separate, unstarted later work.
- Unattended new-recipient sending (text or attachment) remains excluded
  pending a separate safe mechanism.
- The pre-existing `trustedClients` `clientInfo.name`-spoofing gap remains
  unrelated to this slice and untouched.
- `CLITests/test_elicitation_proxy.py`'s `DYLD_FRAMEWORK_PATH` path-fragility
  issue remains unresolved; still out of scope.

## Next bounded action

Supervising review of the exact pushed head on `feat/messages-write-foundation`,
then the compact manual checkpoint above under the user's own explicit,
separate authorization for any real send. No further implementation is
expected until that review and checkpoint complete.

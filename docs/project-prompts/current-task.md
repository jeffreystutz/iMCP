# Current Claude Code Task

**Status:** active manual-checkpoint correction

**Recommended session:** continue the current Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high — the runtime change is tiny, but it sits at the security-sensitive destination parser and must distinguish harmless blank optional form fields from genuinely malformed supplied selectors without weakening fail-closed behavior.

This file is the canonical supervising prompt for one bounded correction task.

## Repository and exact current state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The exact production head already code-review accepted by the supervisor is:

`dd135167bd8a9a1f0b028c56acfa2c6147d07f1a` — `fix: fail closed on malformed Messages destination selectors`

That head is **not yet fully manually accepted** because the final runtime checkpoint exposed a compatibility/semantics issue described below.

The accepted behavior that must remain intact is:

- public send tools are exactly `message_send_text` and `message_send_attachment`;
- both expose `recipients` plus mutually exclusive `chat_id`, with no singular `recipient`;
- `recipients` accepts either a scalar exact handle or a non-empty array;
- scalar and one-item-array `recipients` mean identical direct-recipient intent;
- arrays with two or more supplied entries mean exact-existing-group intent; duplicate/normalization collisions fail closed rather than degenerating into direct intent;
- `message_send_text.body` is required, non-empty, and is never collected through missing-body elicitation;
- malformed non-string extra selectors currently fail closed before any downstream side effect;
- `sendText` / `sendAttachment`, live global Sending mode, confirmation, revalidation, Automation/addressability, privacy, one-dispatch/no-retry, and verified-new-recipient behavior are already reviewed and must not be rewritten.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow the project coding-agent bootstrap required by `AGENTS.md`;
3. verify repository, branch, remotes, local/origin equality, and clean worktree;
4. verify `dd135167bd8a9a1f0b028c56acfa2c6147d07f1a` is the latest production commit and that only this prompt-only trajectory commit follows it;
5. inspect `MessageService.resolveDestination`, `parseRecipients`, both send-tool schemas/closures, `MessageSendTests`, `MessageAttachmentSendTests`, ADR 0013, and any current docs that describe destination-selector exclusivity.

If any unexpected production source/test commit follows `dd135167...`, stop and report the exact state rather than absorbing it.

Do not amend, rebase, reset, squash, force-push, or rewrite reviewed history.

## Manual runtime finding and settled product decision

MCP Inspector submitted this actual tool-call payload while the user had entered a valid recipient and left the optional chat field untouched:

```json
{
  "name": "message_send_text",
  "arguments": {
    "recipients": "+14158867421",
    "chat_id": "",
    "body": ""
  }
}
```

At `dd135167...`, selector exclusivity is intentionally counted from raw argument-key presence. That correctly fixed the previous defect where a **non-string** malformed extra selector could be silently ignored, but it also means the harmless blank optional `chat_id` emitted by a form client counts as a second destination selector and causes `invalidDestination` before the request reaches the intended empty-body validation.

The user explicitly approved this refinement:

> Blank or whitespace-only **scalar string** destination selector values are omission-equivalent.

This is intended as general server API semantics, not an Inspector-specific hack.

### Final destination-presence semantics

Before destination-selector exclusivity is evaluated:

- scalar `recipients` whose string is empty or whitespace-only -> treat as **omitted**;
- `chat_id` whose string is empty or whitespace-only -> treat as **omitted**;
- valid nonblank scalar `recipients` -> supplied;
- non-empty `recipients` arrays -> supplied and parsed under the existing scalar/array rules;
- an empty `recipients` array -> **supplied malformed input**, preserving the existing explicit `emptyRecipients` failure; do not reinterpret it as omission;
- non-string `recipients` -> **supplied malformed input**, fail closed;
- non-string `chat_id` -> **supplied malformed input**, fail closed;
- malformed nonblank handles -> supplied and fail the existing recipient validation;
- a malformed extra non-string selector alongside another valid selector must still count as supplied and produce `invalidDestination`, preserving the fix at `dd135167...`.

After blank-scalar normalization, exactly one meaningful destination selector must remain:

- neither -> `invalidDestination`;
- both -> `invalidDestination`;
- one -> parse/validate it normally.

Do not use successful type conversion as the test for whether a malformed nonblank/non-string selector was supplied. The previous security correction remains binding.

## Concrete goal

Make the shared destination parser tolerate blank optional scalar text fields while preserving strict malformed-selector fail-closed behavior.

Use the smallest clear implementation. A reasonable structure is to classify each raw selector as absent / blank-string-omitted / supplied before exclusivity counting, then parse the selected meaningful value. Follow repository conventions rather than inventing a broad framework.

The implementation must serve both `message_send_text` and `message_send_attachment` through the existing shared parser.

## Required behavior

Preserve or establish all of the following:

1. `recipients: "valid@example.invalid"`, `chat_id: ""` -> behaves exactly like recipients alone.
2. `recipients: "valid@example.invalid"`, `chat_id: "   "` -> behaves exactly like recipients alone.
3. `recipients: ""`, valid `chat_id` -> behaves exactly like chat_id alone.
4. whitespace-only scalar `recipients`, valid `chat_id` -> behaves exactly like chat_id alone.
5. blank scalar `recipients` + blank `chat_id` -> `invalidDestination` because no meaningful selector remains.
6. valid recipients + non-string `chat_id` -> `invalidDestination`; malformed extra selector is never ignored.
7. non-string sole `chat_id` -> existing `invalidChatIdentifier` or equivalent settled explicit malformed-chat failure, with zero side effects.
8. non-string sole `recipients` -> existing recipient/input failure with zero side effects.
9. empty `recipients` array remains `emptyRecipients`, not omission.
10. valid scalar and one-item-array recipients remain equivalent direct intent.
11. 2+ arrays preserve exact-existing-group semantics and collision failure.
12. `message_send_text.body` missing/malformed/empty behavior remains unchanged and never elicits a missing body.
13. All downstream send, confirmation, automatic-mode, revalidation, Automation/TCC, privacy, and one-dispatch semantics remain unchanged.

The Inspector payload above should therefore proceed past destination parsing and fail for the **empty body**, not `invalidDestination`.

## Required focused tests

Add focused regression tests for **both public send tools**. At minimum prove:

### Text tool

- valid scalar recipients + `chat_id: ""` reaches the same path as recipients alone;
- valid scalar recipients + whitespace-only `chat_id` does the same;
- blank/whitespace scalar recipients + valid chat_id reaches the chat path;
- both scalar selectors blank -> `invalidDestination`, zero confirmation/composition/dispatch;
- the exact Inspector-shaped input with valid scalar recipients + blank chat_id + empty body fails `emptyBody` (or the existing exact empty-body error), requests zero missing-body elicitation, and dispatches zero;
- valid recipients + non-string chat_id still fails `invalidDestination` with zero side effects;
- sole non-string chat_id remains fail-closed;
- empty recipient array remains `emptyRecipients`;
- existing scalar/one-item-array/group behavior remains green.

### Attachment tool

- valid scalar recipients + blank/whitespace chat_id behaves like recipients alone and does not fail destination exclusivity;
- blank/whitespace scalar recipients + valid chat_id behaves like chat_id alone;
- both scalar selectors blank -> `invalidDestination` before picker/confirmation/Automation/dispatch;
- valid recipients + non-string chat_id still fails `invalidDestination` before picker;
- empty recipient array remains an explicit error, not omission;
- no current attachment schema/file-ingress behavior is changed in this task.

Prefer extending the existing destination-validation tests and harnesses. Use only synthetic values.

## Documentation / decision record

This is a refinement of the accepted destination API in ADR 0013, not a new architectural direction.

- Do **not** create a new ADR.
- Update ADR 0013 if its current wording says or implies that any present raw key, including a blank optional scalar text value, necessarily counts as a supplied destination.
- Update current repository docs/tool comments only where necessary to keep the final semantics truthful.
- Preserve historical reports/ADRs as history; do not rewrite unrelated narration.
- A separate new project report is unnecessary for this tiny correction unless repository conventions or unexpected findings justify one.

## Scope and explicit exclusions

This task is only destination-input normalization and its tests/docs.

Do not implement or redesign:

- attachment staging-directory ingress;
- serialized/base64 attachment ingress;
- `message_send_attachment` file/path/content schema;
- managed file-access Settings;
- persistent filesystem grants/bookmarks;
- staging cleanup/delete-after-send;
- the temporary picker implementation;
- send-tool names or the scalar-or-array `recipients` schema;
- text/attachment downstream send pipelines;
- Sending-mode Settings or authorization behavior;
- new-recipient behavior;
- circuit breaker, activity history, idempotency, trusted-client hardening, RCS work, CLI fragility cleanup, or upstream PR decomposition;
- unrelated cleanup/refactoring.

The attachment tool currently having only destination inputs is expected. The picker-based attachment ingress is already rejected as the final product design and will be replaced in a separate milestone.

## Security and privacy invariants

Do not weaken:

- malformed typed selector fail-closed behavior established at `dd135167...`;
- exact destination validation and ambiguity failure;
- exact-existing-group semantics for arrays of two or more recipients;
- duplicate/normalization-collision group failure;
- verified-new direct-recipient text composition distinction;
- attachment verified-new-recipient refusal;
- Ask-mode final authorization / live global Automatic mode behavior;
- destination and attachment-file revalidation;
- Automation/TCC and exact chat addressability;
- fixed AppleScript source and descriptor-only caller data;
- one Messages dispatch per operation, no retry/fallback;
- cancellation-before-dispatch;
- privacy-redacted logs/errors/results;
- submitted-not-delivered truthfulness.

Do not read, print, log, or commit private Messages/Contacts contents, real recipient identities, real message bodies, or real attachment paths/content. Do not send a real message or attachment.

## Verification

Run focused destination/input tests first, then the project verification appropriate to this exact head.

At minimum:

- focused `MessageSendTests` and `MessageAttachmentSendTests` for the cases above;
- `swift format lint --strict --recursive App AppTests`;
- `git diff --check`;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- regenerate the established signed `.build/ManualVerification` app;
- `codesign --verify --strict` and confirm Hardened Runtime/effective entitlements remain unchanged.

Do not derail on the known unrelated CLI test `DYLD_FRAMEWORK_PATH` fragility unless this change actually touches that path.

Adversarially self-review for:

- blank-string omission accidentally swallowing non-string malformed selectors;
- empty arrays accidentally becoming omission;
- malformed nonblank recipients being ignored;
- blank fields changing body validation order incorrectly;
- text and attachment tools diverging despite the shared parser;
- any changes to `sendText` / `sendAttachment` or downstream authorization/dispatch behavior.

## Git and handoff

Use one additive implementation/test/docs commit. Do not rewrite `dd135167...` or this prompt-only commit.

Suggested commit message:

`fix: ignore blank optional Messages destination fields`

Push normally to `origin/feat/messages-write-foundation`, then fetch and verify local HEAD exactly equals origin and the worktree is clean.

Do not open or merge an upstream PR.

## Manual verification after supervising review

Claude must not perform a real/manual Messages send.

After supervising code review, the human checkpoint should be:

1. In MCP Inspector, submit a valid scalar recipient with blank optional `chat_id` and empty body. The error must be the body error, not `invalidDestination`; no missing-body form appears.
2. Supply a non-empty synthetic body with the same scalar recipient / blank `chat_id`. In Ask Before Sending mode, the normal final confirmation appears. Cancel it; nothing sends.
3. If Inspector can preserve a one-item array, repeat once with the array and cancel. If Inspector normalizes it to the scalar branch, automated equivalence coverage is sufficient; do not fight the Inspector UI.

No attachment-picker acceptance test is required or desired.

## Stopping point

STOP after:

- blank/whitespace optional scalar destination values are omission-equivalent;
- malformed typed/nonblank selectors still fail closed;
- empty recipient arrays remain explicit errors;
- both public send tools share the corrected semantics;
- empty-body behavior is reached correctly through an Inspector-shaped blank-chat payload;
- focused/full tests, formatting, build, and signing verification pass;
- ADR/current docs are truthful without unnecessary churn;
- no unrelated production behavior changes;
- branch is pushed normally, local HEAD equals origin, and worktree is clean.

When complete, the user should only need to say **done**.
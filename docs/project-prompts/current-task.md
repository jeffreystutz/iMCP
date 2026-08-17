# Current Claude Code Task

**Status:** active public-input correction

**Recommended session:** continue the current Claude Code session if it still has useful repository context; otherwise a fresh session is fine  
**Recommended model:** Sonnet  
**Effort:** high — the code change is localized, but it sits immediately in front of two security-sensitive send pipelines whose downstream behavior must remain unchanged.

This file is the canonical supervising prompt for one bounded correction task.

## Repository and exact starting state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

Expected production/review head before this prompt-only trajectory commit:

`fa5733b91f383eba0b8e257f1132bacc58e98aae` — `refactor: split Messages text and attachment send tools`

That head passed supervising code review, automated verification, and signed-build verification. It is **not fully manually accepted**: the 2026-08-17 human checkpoint explicitly rejected two pieces of current public behavior that this task corrects:

1. `message_send_text` must not elicit a missing body; missing/malformed/empty body should fail.
2. The send tools should not expose separate `recipient` and `recipients` destination fields.

The user also rejected the current native picker as the final ordinary attachment ingress. That attachment-source redesign is **not part of this task**; the current picker path remains temporarily in code as a reviewed downstream-execution scaffold until the separate filesystem/serialized-ingress milestone replaces its source boundary.

Important accepted ancestry:

- `eb64ee2de11a50d63bc1d64362136d1251f0bdf4` — existing-conversation text automatic-send wiring, fully accepted including real runtime verification;
- `3b9a4a71f33245c511adcdd64f129c24e48f3603` — picker-attachment automatic-send wiring, code-review accepted and still useful as downstream attachment validation/revalidation/dispatch evidence, although picker ingress itself is no longer the desired product UX;
- `fa5733b9...` — final split public tool names `message_send_text` / `message_send_attachment`, code-review accepted.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow `imessage-mcp/coding-agent-bootstrap` from Hexa as required by `AGENTS.md`;
3. verify repository, branch, remotes, local/origin HEAD equality, and clean worktree;
4. verify `fa5733b91f383eba0b8e257f1132bacc58e98aae` is in history;
5. inspect commits after `fa5733b9...` and confirm they are only this prompt-only trajectory commit; if any unexpected production source/test commit follows it, stop and report exact state;
6. inspect `MessageService.tools`, `resolveSendInput`, `resolveAttachmentDestination`, `SendDestination`, destination preparation/revalidation, `MessageSendTests`, `MessageAttachmentSendTests`, tool-list/schema tests, and ADRs 0010/0012 before editing;
7. inspect existing repository uses of property-level JSON Schema unions (`oneOf`/equivalent) and follow the local SDK idiom rather than inventing a new schema abstraction.

Do not amend, rebase, squash, reset, force-push, or rewrite reviewed history.

## Concrete goal

Make both public Messages send tools use one simplified destination field and make text body input strict.

The public send operations remain exactly:

- `message_send_text`
- `message_send_attachment`

No unified alias and no old plural send-tool alias should exist.

## Settled destination API

Both tools must accept exactly one of:

- `recipients`
- `chat_id`

Remove the singular `recipient` property entirely from both public schemas and parsing paths.

### `recipients` accepts scalar or array

`recipients` accepts either:

- one exact handle as a scalar string; or
- an array containing one or more exact-handle strings.

Represent this in the tool schema with the repository's established property-level JSON Schema union mechanism. Do not create two public properties merely to avoid a union.

Normalize only at the parsing boundary:

- scalar string -> direct-recipient intent;
- one-item array -> the same direct-recipient intent;
- array with two or more supplied elements -> exact-existing-group intent.

Preserve the existing internal direct/group distinction if useful. There is no requirement to collapse `SendDestination` internals merely because the public field is unified.

### Exact validation semantics

`recipients` scalar:

- must be a valid exact Messages handle under the existing exact-handle rules;
- maps to the existing direct-recipient route.

`recipients` array:

- must contain at least one element;
- every element must be a string and a valid exact Messages handle;
- one element maps to the direct-recipient route;
- two or more supplied elements express group intent and must remain two-or-more **distinct normalized handles**;
- duplicate or normalization-colliding group inputs must fail closed rather than silently collapse to a one-recipient/direct call;
- preserve exact existing-group membership semantics: no additional/missing participant, no group creation, no fuzzy membership.

`chat_id`:

- preserves its existing exact indexed-conversation behavior.

Selector rules:

- exactly one of `recipients` or `chat_id` must be supplied;
- both -> invalid destination;
- neither -> invalid destination;
- an empty recipients array is invalid;
- do not infer a country, rewrite a handle, choose a transport, or fall back between destination routes.

### Direct-recipient behavior remains operation-specific

For `message_send_text`, direct-recipient intent (scalar or one-item array):

- unique existing direct conversation -> existing exact AppleScript text-send pipeline;
- recipient verified to have no existing conversation -> existing human-controlled `NSSharingService.Name.composeMessage` path;
- ambiguous/incomplete/stale/invalid -> fail closed.

For `message_send_attachment`, direct-recipient intent (scalar or one-item array):

- unique existing direct conversation -> current reviewed attachment pipeline;
- verified-new recipient -> current categorical unsupported failure before attachment source selection/dispatch;
- no fallback to text composition.

## Settled `message_send_text.body` behavior

`body` is required and must be a non-empty string.

Remove the current missing-body MCP form elicitation completely.

Required behavior:

- missing `body` -> terminal input error, zero destination lookup side effect that could lead to composition/submission, zero confirmation request, zero send;
- non-string/malformed `body` -> terminal input error, zero send;
- empty string -> existing empty-body error (or equally clear established body-validation error), zero send;
- valid non-empty string -> preserve the existing text pipeline exactly.

Do **not** ask the user/LLM for a missing body through elicitation. The user explicitly rejected that UX during manual testing.

This does **not** remove or weaken final send confirmation. In Ask Before Sending mode, existing-conversation text still uses the configured confirmation mechanism after destination resolution. MCP form confirmation, when selected as the confirmation presentation method, is a separate authorization surface and must remain intact.

If `MessageSendError.inputDeclined` / `inputCancelled` or other cases become dead solely because missing-body elicitation is removed, remove them only after verifying no other production path uses them. Do not churn unrelated error types.

## Downstream behavior that must remain unchanged

This task is a public input/parser correction. Do not redesign the accepted/reviewed send engines.

Preserve for text:

- exact destination preparation and revalidation;
- verified-new-recipient human-controlled composition;
- live global `MessagesSendingMode` evaluation per call;
- Ask-mode final confirmation / Send-Automatically confirmation skip;
- non-prompting preflight rules;
- Automation/TCC and exact chat addressability;
- one text dispatch, no retry/fallback;
- privacy-redacted logging/errors/results;
- submitted/completed, never delivered, truthfulness.

Preserve for attachments:

- existing exact destination preparation and revalidation;
- current file picker/validator/access pipeline **temporarily**, without presenting it as the final product design;
- live global `MessagesSendingMode` behavior;
- file identity/property revalidation;
- Automation/TCC and exact chat addressability;
- one typed-file dispatch, no retry/fallback;
- privacy/result semantics.

Do not add attachment path/bytes/source fields in this task.

## Attachment-ingress product state — explicit exclusion

The user has already decided that ordinary `message_send_attachment` execution should eventually be programmatic, not picker-driven. Settled future direction:

- persistent user-approved filesystem root + relative path, with a dedicated staging area as the primary/simple case;
- bounded serialized attachment content staged into app-owned temporary storage;
- file picker only in Settings/onboarding when granting a persistent filesystem root, not per send;
- staging deletion is an iMCP Settings lifecycle policy, not an MCP argument; factory default keeps staging files, optional deletion applies only after definitive successful staging-file submission.

Do **not** implement any of that here. It has a separate UX/security/entitlement acceptance boundary and will follow this correction.

## Schema and implementation guidance

Prefer the smallest change that keeps the downstream code recognizable.

A good shape is:

- replace the public `recipient` + `recipients` schema properties with one `recipients` property whose value schema is string-or-nonempty-string-array;
- keep `chat_id` as the alternative;
- replace duplicated destination parsing with a small shared parser only if doing so clearly reduces duplication without touching resolution/revalidation behavior;
- internally map scalar/one-item array to the existing direct destination case and 2+ valid distinct normalized items to the existing group destination case;
- remove body elicitation from the text input parser and require a body directly.

Do not introduce a compatibility alias for `recipient`; this feature-completion branch has no released compatibility requirement for it.

Top-level `additionalProperties: false` remains.

## Required focused tests

Preserve all still-valid tests and update/add focused coverage. At minimum prove:

1. Both public send schemas contain `recipients` and `chat_id`, and contain **no `recipient` property**.
2. `message_send_text` additionally exposes required `body`; `message_send_attachment` does not expose body/caption/file/path/bytes/source yet.
3. Encoded/schema representation of `recipients` accepts a scalar string and a nonempty array of strings via the local property-union idiom.
4. Scalar `recipients` on text follows direct-recipient behavior.
5. One-item array `recipients` on text follows the same direct-recipient behavior.
6. Scalar and one-item array produce equivalent exact-existing-direct destination behavior in synthetic tests.
7. Two-or-more array items follow exact-group behavior.
8. Duplicate or normalized-colliding 2+ group input fails rather than degenerating into direct intent.
9. Empty array fails; non-string array member fails; malformed scalar fails.
10. `recipients` + `chat_id` together fail; neither fails.
11. Verified-new text behavior is preserved for scalar and, if inexpensive, one-item-array input.
12. Verified-new attachment behavior remains unsupported for scalar/one-item-array input, before picker/composer/dispatch.
13. Missing body causes an immediate input error and **does not issue any elicitation request**, confirmation request, composition, Automation request, or dispatch.
14. Malformed/non-string body fails with zero side effect.
15. Empty body still fails with zero side effect.
16. A valid body in Ask Before Sending still reaches exactly one final confirmation for an existing conversation.
17. A valid body in Send Automatically still skips only that final confirmation and retains destination revalidation/Automation/exactly-one dispatch.
18. Existing attachment Ask/Automatic, picker cancellation, stale destination, changed file, Automation denial/unavailability, and one-dispatch coverage remains green after destination parser changes.
19. Tool-list tests still expose only `message_send_text` and `message_send_attachment` as send operations; no old/unified alias returns.
20. Read-only Messages/Contacts behavior and unrelated services are unchanged.

Use only synthetic handles/files in tests. Do not access real Messages/Contacts data.

## ADR and documentation reconciliation

The two-tool split in ADR 0012 remains accepted. This task changes destination input shape and reverses ADR 0012's restored missing-body elicitation behavior.

Create the next ADR (expected ADR 0013 if repository numbering agrees) recording the user's explicit 2026-08-17 decision:

- retain `message_send_text` / `message_send_attachment`;
- remove singular `recipient`;
- `recipients` accepts scalar or one-or-more array plus mutually exclusive `chat_id`;
- scalar/one-item array = direct intent; 2+ array = exact-existing-group intent with duplicate/degenerate failure;
- require non-empty `message_send_text.body` and do not elicit a missing body;
- final confirmation elicitation remains separate and unchanged;
- attachment source redesign is explicitly deferred to a later ADR/milestone.

Mark ADR 0012 as superseded **only for these public-input details** if that matches the repository's ADR convention; do not imply its two-tool split or carried-forward safety contracts were rejected.

Update as applicable:

- `docs/decisions/README.md`;
- ADR 0010/0012 cross-references only where needed for current truth;
- `docs/messages-write-plan.md`;
- `README.md` if it documents these argument names/semantics;
- current tool descriptions/parameter descriptions in `App/Services/Messages.swift`;
- any current-facing documentation that says callers should use singular `recipient` or that missing text body is elicited.

Historical reports/ADRs may retain old names/behavior as historical narration; add a concise forward note only if needed to prevent readers mistaking superseded behavior for current truth. Do not rewrite history.

Create a concise sanitized project report under `docs/project-reports/` for this correction. It must identify starting reviewed head `fa5733b91f383eba0b8e257f1132bacc58e98aae`, final commit(s), exact schema/behavior changes, verification, unresolved attachment-ingress milestone, and any manual gate. No raw logs/private values.

## Security and privacy invariants

This correction must not weaken:

- exact handle validation;
- direct/group ambiguity and complete-membership checks;
- destination revalidation immediately before dispatch;
- verified-new route distinction;
- app-owned global Sending mode and caller inability to override it;
- final confirmation semantics in Ask mode;
- Automation/TCC and exact chat addressability;
- attachment file validation/revalidation in the temporary picker path;
- fixed AppleScript source and descriptor-only untrusted inputs;
- one-dispatch/no-retry/no-fallback;
- cancellation-before-dispatch;
- privacy redaction;
- submitted-not-delivered truthfulness.

Production logs must not add recipient handles, chat IDs, message bodies, filenames, paths, or attachment contents.

## Verification

Run focused parser/schema/body tests first, then the full applicable verification.

At minimum:

- focused `MessageSendTests`;
- focused destination/schema portions of `MessageAttachmentSendTests`;
- affected tool-list/schema regression tests;
- `swift format lint --strict --recursive App AppTests`;
- `git diff --check`;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- `imcp-server`/CLI build if shared compilation requires it;
- do not spend time on the known unrelated `CLITests/test_elicitation_proxy.py` `DYLD_FRAMEWORK_PATH` fragility unless this task changes that path;
- regenerate the signed `.build/ManualVerification` app using the established procedure;
- `codesign --verify --strict` the signed app;
- confirm effective entitlements and Hardened Runtime remain unchanged.

No automated verification may send a real message or attachment.

Perform adversarial self-review for: a hidden singular-recipient alias; scalar/array disagreement; group duplicate degeneration into direct intent; malformed body accidentally reaching confirmation/composition; loss of final confirmation because missing-body elicitation was removed; changed new-recipient behavior; weakened destination/file race checks; caller-controlled automatic bypass; retry/fallback; privacy leak.

## Manual checkpoint to prepare, but do not execute

After supervising review of the exact pushed implementation head, prepare for a small non-destructive human check:

1. Refresh/reconnect the MCP client and inspect `message_send_text` / `message_send_attachment`: `recipient` is absent; `recipients` is represented as scalar-or-array; `chat_id` remains alternative.
2. Call `message_send_text` without `body`; verify an immediate error and **no missing-body form appears**.
3. In Ask Before Sending, call `message_send_text` with a scalar `recipients` value and a deliberately chosen test body to an explicitly authorized existing conversation; verify the normal final send confirmation appears, then cancel. Nothing needs to be sent.
4. If the client can conveniently express it, repeat with a one-item `recipients` array and verify it reaches the same final confirmation; cancel.

Do not use the current attachment picker as a product-acceptance test. Attachment ingress remains explicitly pending redesign.

Any real message test would require separate explicit authorization of exact destination and body. The checklist above should require no actual send.

## Explicit exclusions

Do not implement in this task:

- filesystem/staging attachment ingress;
- serialized/base64 attachment ingress;
- Managed File Access Settings/onboarding;
- staging delete-after-send setting/runtime;
- attachment picker removal;
- verified-new attachment sending;
- unattended new-recipient text sending;
- body + attachment/caption in one operation;
- multiple attachments;
- per-client or operation-class authorization;
- circuit breaker;
- Recent Automation Activity;
- cross-call idempotency;
- trusted-client identity hardening;
- CLI test-harness cleanup;
- upstream PR decomposition;
- unrelated refactors.

## Git and handoff

Use additive commits only. Do not rewrite `fa5733b9...` or any reviewed history.

A reasonable implementation commit message is:

`refactor: simplify Messages send destination inputs`

Commit implementation/tests/docs/report changes and push normally to:

`origin/feat/messages-write-foundation`

Then:

- `git fetch origin`;
- verify local HEAD exactly equals `origin/feat/messages-write-foundation`;
- verify worktree clean.

Do not open or merge a maintainer PR. Do not force-push.

## Stopping point

STOP after:

- both send tools expose only scalar-or-array `recipients` plus `chat_id` for destination selection;
- singular `recipient` is gone with no alias;
- scalar/one-item input preserves direct/new-recipient semantics and 2+ array preserves exact-group semantics;
- duplicate/degenerate group input fails closed;
- `message_send_text.body` is required/non-empty and missing body never elicits;
- final confirmation and all downstream send safety/authorization behavior remain intact;
- attachment ingress is deliberately not redesigned;
- ADR/docs/report accurately describe current state;
- focused/full verification and signed-build checks pass;
- implementation/report commits are pushed normally, local HEAD equals origin, and worktree is clean.

Do not perform the human checkpoint. The next gate is supervising review of the exact pushed head, followed by the compact non-destructive schema/text-input checkpoint above.

When complete, the user should only need to say **done**.
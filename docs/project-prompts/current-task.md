# Current Claude Code Task

**Status:** active implementation

**Recommended session:** continue the current Claude Code session if available; otherwise a fresh session is fine  
**Recommended model:** Sonnet  
**Effort:** high — this is primarily an API consolidation/refactor, but it crosses two already-reviewed security-sensitive send paths and must preserve their behavior exactly.

This file is the canonical supervising prompt for one bounded coding task.

## Repository and reviewed state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The latest remote production head before this prompt is expected to be:

`3b9a4a71f33245c511adcdd64f129c24e48f3603` — `feat: honor global Sending mode for existing attachments`

State of that head:

- existing-conversation plain-text `messages_send` automatic-mode wiring is fully accepted, including a real runtime checkpoint, with accepted implementation ancestry at `eb64ee2de11a50d63bc1d64362136d1251f0bdf4`;
- picker-based `messages_send_attachment` automatic-mode wiring at `3b9a4a71...` passed supervising code review and full automated verification (275/275 tests), but its separate-tool manual runtime checkpoint was deliberately **deferred** after the user chose to consolidate the public API first;
- the attachment implementation itself is therefore the reviewed implementation base for this task, not rejected work.

The branch will also contain the prompt-only commit that publishes this file. That commit is trajectory evidence, not production acceptance.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow `imessage-mcp/coding-agent-bootstrap` from Hexa as required by `AGENTS.md`;
3. verify repository, branch, remotes, local/origin HEAD equality, and clean worktree;
4. verify `3b9a4a71f33245c511adcdd64f129c24e48f3603` is in history;
5. inspect commits after `3b9a4a71...` and confirm they are only this expected prompt-only trajectory commit;
6. inspect `MessageService.tools`, the existing `messages_send` and `messages_send_attachment` closures, destination preparation/revalidation helpers, `MessagesSendingMode`, attachment picker/validator/access code, sender adapters, `MessageSendTests`, `MessageAttachmentSendTests`, tool-schema conventions, and ADRs 0002/0009/0010.

If unexpected production source/test changes exist after `3b9a4a71...`, stop and report exact state rather than absorbing them.

Do not amend, rebase, squash, reset, force-push, or rewrite reviewed history.

## Settled product decision

The separate public `messages_send_attachment` tool was useful as an incremental implementation boundary, but it is **not** the desired final MCP API.

There should be **one public Messages send operation: `messages_send`**.

Keep the existing mutually exclusive destination selectors:

- `recipient`
- `recipients`
- `chat_id`

Each call must also contain **exactly one payload type**:

1. **Text:** the existing top-level `body` string.
2. **Attachment:** a top-level `attachment` object.

For this task the attachment object supports only:

```json
{"source":"picker"}
```

`body` and `attachment` are mutually exclusive and exactly one is required.

Do **not** support body + attachment/caption in one call. Messages AppleScript submits either text or a file as one direct parameter, and this project preserves one-dispatch/no-retry semantics. A caption remains a separate text `messages_send` call.

This shape deliberately preserves current text-call ergonomics while giving future attachment ingress an extensible namespace: later approved `attachment.source` variants may add handoff-directory and serialized-content sources without creating more top-level send tools.

Remove `messages_send_attachment` from the public tool list rather than preserving it as a permanent alias. This feature branch has no established released compatibility requirement for that standalone tool. If repository evidence proves otherwise, stop and report that evidence before introducing an alias/deprecation layer.

## Unified routing semantics

The single public tool routes internally by payload type while preserving the already-reviewed pipelines.

### Text payload: `body`

Preserve current `messages_send` behavior exactly:

- exact existing direct/group/chat_id -> existing AppleScript text-send pipeline;
- verified-new direct recipient -> existing human-completed `NSSharingService` Messages compose flow;
- ambiguous/incomplete/stale/unaddressable destination -> fail closed;
- global `MessagesSendingMode` applies to existing-conversation text: Ask requires the existing final confirmation; Send Automatically skips only that confirmation;
- no new group creation, fallback, retry, transport selector, or delivery claim.

Existing text callers using `body` should require no new wrapper object or migration.

### Attachment payload: `attachment: {"source":"picker"}`

Route to the already-reviewed picker attachment pipeline currently behind `messages_send_attachment`:

1. resolve one exact existing destination;
2. verified-new recipient fails unsupported before picker/composition/dispatch;
3. non-prompting addressability preflight when safe;
4. native single-file picker;
5. security-scoped access + existing bounded file validation;
6. authorize according to global Sending mode: Ask presents existing immutable attachment confirmation; Send Automatically skips only that final confirmation;
7. destination revalidation;
8. file identity/property revalidation;
9. Automation/TCC + exact chat addressability verification;
10. exactly one typed-file attachment dispatch;
11. existing privacy-redacted submitted result.

The picker remains mandatory in both modes and is never itself treated as authorization.

Do not rewrite the fixed AppleScript sender or attachment validator merely because the public router is changing.

## Schema and validation contract

`messages_send` must expose only the destination selectors plus the two payload alternatives needed now:

- `recipient`
- `recipients`
- `chat_id`
- `body`
- `attachment`

`attachment` must be an object whose current public contract requires/accepts only `source: "picker"` and rejects unknown fields. Top-level `additionalProperties: false` remains.

Preserve current destination missing-input/elicitation behavior. Do **not** invent payload-type elicitation in this task.

For payload validation:

- body only -> text path;
- attachment only -> attachment path;
- both body and attachment -> categorical invalid-input failure before picker/confirmation/Automation/dispatch;
- neither -> categorical invalid-input failure before picker/confirmation/Automation/dispatch;
- unsupported attachment source or extra attachment fields -> fail before picker/Automation/dispatch.

If the vendored SDK cleanly supports an existing repository-style schema construct that expresses the exactly-one payload rule without harming client compatibility, use it. Otherwise enforce the same invariant in code and make it explicit in descriptions/tests. Do not introduce a schema framework or dependency for this.

No caller-facing argument may select Sending mode, confirmation bypass, file path, filename, or raw bytes in this task.

## Implementation guidance

Prefer the smallest refactor that leaves the reviewed security-sensitive logic recognizable.

A good shape is one `messages_send` tool closure that parses/validates destination + payload, then delegates to private text/attachment helpers containing the existing reviewed pipeline code. Extract helpers only as needed to avoid one giant closure or duplicated logic; do not generalize into a new send framework.

Preserve a single dispatch call site per payload implementation. The unified public router must never cause a fallback from one payload path to the other or two submissions from one tool call.

The existing live `sendingMode` provider remains app-owned and evaluated per call. No attachment-specific or payload-specific authorization policy is introduced.

Do not add private-value production logging. Payload type may be categorical if existing logging genuinely needs it, but recipient, participant set, chat ID, body, file path/name/type/size/content, and underlying filesystem error text remain excluded from production diagnostics/results.

## Required focused tests

Refactor existing tests rather than discarding their coverage. At minimum prove:

1. `MessageService.tools` exposes `messages_send` and no longer exposes `messages_send_attachment`.
2. Existing text call shape with `body` remains valid and preserves direct/group/chat_id behavior.
3. `attachment: {"source":"picker"}` reaches the existing attachment path for direct/group/chat_id destinations.
4. Exactly-one-payload validation: body+attachment and neither payload both fail with zero picker, confirmation, Automation request, composition, or dispatch.
5. Attachment object rejects unsupported source values and extra fields with zero side effects.
6. Ask Before Sending still requests exactly one text confirmation for existing-conversation text and one attachment confirmation for picker attachment.
7. Send Automatically still skips only final confirmation for both existing-conversation payload types while preserving all downstream validation/revalidation/Automation/one-dispatch behavior.
8. Live Sending-mode changes remain observed without reinitializing `MessageService` for both payload types; reuse existing coverage where possible rather than duplicating unnecessarily.
9. Text verified-new recipient still opens human-controlled Messages composition and never routes through attachment logic.
10. Attachment verified-new recipient still fails before picker/composer/dispatch.
11. Picker cancellation, destination staleness, file change/replacement, Automation denial/unavailability, and Ask-mode confirmation decline/cancel remain fail-closed with zero dispatch.
12. Attachment path/file bytes are still not accepted by the current public schema.
13. Text + attachment/caption in one call is rejected and can never cause two dispatches.
14. Success semantics remain submitted/completed, never delivered.
15. Existing read-only Messages behavior and unrelated services remain unchanged.

Preserve or strengthen existing ordering assertions. Do not weaken tests merely to make consolidation easier.

## ADR and documentation reconciliation

This changes a public API decision and must be documented as such.

Per `AGENTS.md` ADR rules:

- create a new ADR for the unified Messages send API (next available number, expected ADR 0011 if repository state agrees);
- the user explicitly approved the consolidation decision, so the new ADR may be `Accepted`;
- mark ADR 0009 `Superseded` by the new ADR because its decision to expose a separate public attachment tool is no longer current;
- the new ADR must explicitly carry forward the still-binding attachment security/validation contract from ADR 0009 so superseding the old public-tool decision does **not** imply picker, file validation/revalidation, security-scoped access, typed descriptor, privacy, or one-dispatch protections are obsolete;
- update ADR 0010 references/runtime wording so global Sending mode is described against the unified public `messages_send` API rather than two permanent public tools;
- update `docs/decisions/README.md`.

Also inspect/update:

- `README.md`;
- `docs/messages-write-plan.md`;
- tool descriptions/parameter descriptions in `App/Services/Messages.swift`;
- existing text/attachment automatic-mode reports only with small forward cross-references if useful; do not rewrite their historical evidence;
- any documentation that presents `messages_send_attachment` as the desired final public API.

Create one concise sanitized implementation report under `docs/project-reports/` for this consolidation. It must state the reviewed starting head `3b9a4a71...`, the fact that its attachment manual checkpoint was deliberately deferred/superseded by this consolidation, implementation SHA(s), schema decision, files/symbols changed, focused/full verification, remaining manual gate, and next bounded action.

No raw logs, private values, or real file paths.

## Security and privacy invariants

Consolidation must not weaken:

- exact destination selector validation;
- direct/group ambiguity and incomplete membership failure;
- verified-new-recipient route distinction;
- non-prompting-only preflight before authorization;
- mandatory picker for picker-source attachment;
- bounded attachment validation;
- security-scoped access lifetime;
- destination revalidation;
- attachment file revalidation;
- app-owned global Sending mode and caller inability to override it;
- Messages Automation/TCC checks;
- exact chat addressability verification;
- cancellation before dispatch;
- fixed AppleScript source;
- descriptor-only untrusted text/chat/file input;
- one-dispatch/no-retry/no-fallback semantics;
- ambiguous-submission handling;
- privacy-redacted logs/errors/results;
- submitted-not-delivered truthfulness.

Use only synthetic values in tests/docs. Do not access, print, log, or commit real Messages/Contacts data or private attachment paths/content.

## Verification

Run narrow schema/router tests first, then the full applicable repository verification.

At minimum:

- focused `MessageSendTests` and `MessageAttachmentSendTests` for the unified schema and both payload paths;
- strict Swift format lint over `App` and `AppTests`;
- `git diff --check`;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- `imcp-server`/CLI build if shared compilation requires it;
- do not spend time debugging the known unrelated `CLITests/test_elicitation_proxy.py` `DYLD_FRAMEWORK_PATH` fragility unless this task materially changes that path;
- regenerate the signed `.build/ManualVerification` app using the established procedure;
- `codesign --verify --strict` the signed app;
- confirm effective entitlements and Hardened Runtime are unchanged/unweakened.

No automated verification may send a real message or attachment.

Perform an adversarial self-review specifically for: payload ambiguity, a call reaching both pipelines, duplicated dispatch, text/attachment fallback, caller-controlled Sending mode, picker bypass, weakened destination/file race checks, schema accidentally accepting file paths/bytes, privacy leaks, or changed new-recipient behavior.

## Manual checkpoint to prepare, but do not execute

Do not perform the previously deferred standalone-`messages_send_attachment` manual checkpoint. The next human checkpoint occurs **after supervising review of this consolidated implementation** and uses only the unified `messages_send` API.

Prepare the signed build so the later checkpoint can validate, with the fewest real sends necessary:

- existing text path still enters Ask-mode confirmation through unified `messages_send` (cancel is sufficient);
- picker attachment path enters Ask-mode confirmation through unified `messages_send` and cancel sends nothing;
- without app restart, Send Automatically permits one explicitly authorized picker attachment submission through unified `messages_send` after file selection with no final confirmation;
- switching back to Ask restores attachment confirmation on the next call;
- verified-new text composition and attachment-new-recipient rejection remain distinguishable if a non-sending check is practical.

Any real send requires separate explicit human authorization of the exact destination and exact body/file. Claude must not perform real-message manual verification.

## Explicit exclusions

Do not implement in this task:

- handoff-directory attachment source;
- serialized/base64 attachment source;
- arbitrary local path/file-name/file-bytes MCP input;
- multiple attachments;
- text + attachment/caption atomic sending;
- verified-new-recipient attachment composition;
- unattended new-recipient text sending;
- Shortcuts/Accessibility experiments;
- per-client authorization;
- direct/group/text/attachment authorization granularity;
- circuit breaker UI/defaults;
- cross-call idempotency;
- Recent Automation Activity;
- trusted-client identity hardening;
- CLI path-fragility cleanup;
- upstream PR decomposition;
- unrelated cleanup/refactors.

## Git and handoff

Use additive commits only. Meaningful checkpoint commits are fine. Do not rewrite reviewed history.

A reasonable implementation commit message is:

`refactor: unify Messages text and attachment send tool`

Commit implementation/docs/report changes and push normally to `origin/feat/messages-write-foundation`.

Then:

- `git fetch origin`;
- verify local HEAD exactly equals `origin/feat/messages-write-foundation`;
- verify worktree clean.

Do not open or merge a maintainer PR. Do not force-push.

## Stopping point

STOP after:

- one public `messages_send` tool supports exactly one of existing `body` text or `attachment: {"source":"picker"}`;
- standalone `messages_send_attachment` is removed from the public tool surface;
- existing reviewed text and attachment pipelines remain behaviorally intact behind the unified router;
- one-dispatch/no-fallback and all authorization/revalidation/privacy invariants remain intact;
- ADR/docs accurately record the final public API decision;
- focused/full tests and builds pass;
- signed ManualVerification build is regenerated and verified;
- sanitized report is committed;
- branch is pushed normally, local HEAD equals origin, and worktree is clean.

Do not perform the real manual checkpoint. The next gate is supervising review of the exact pushed consolidation head, then the unified human runtime checkpoint.

When complete, the user should only need to say **done**.
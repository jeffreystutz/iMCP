# Current Claude Code Task

**Status:** active correction implementation

**Recommended session:** continue the current Claude Code session if available; otherwise a fresh session is fine  
**Recommended model:** Sonnet  
**Effort:** high — the public-API change is straightforward, but it crosses two security-sensitive send paths that already have accepted behavior and must be preserved exactly.

This file is the canonical supervising prompt for one bounded correction task.

## Repository and current state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

Expected remote HEAD before this prompt-only commit:

`801f3418f4a713d1ffa9aa784d972c3452952eb5` — `refactor: unify Messages text and attachment send tool`

That commit implemented one unified public `messages_send` tool and passed supervising structural/code review plus full automated verification (275/275 tests), but **it was never manually accepted**. Before the human runtime checkpoint, the user explicitly reversed that public-API decision.

Important accepted ancestry:

- `eb64ee2de11a50d63bc1d64362136d1251f0bdf4` — existing-conversation text automatic-send wiring, fully accepted including real runtime verification;
- `3b9a4a71f33245c511adcdd64f129c24e48f3603` — picker-attachment automatic-send wiring, supervising code-review accepted with full automated verification; its manual runtime checkpoint was deliberately deferred and remains pending.

The current `801f3418...` implementation is therefore a superseded API experiment sitting on top of two still-valid reviewed internal pipelines. Correct it additively; do not reset or rewrite history.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow `imessage-mcp/coding-agent-bootstrap` from Hexa as required by `AGENTS.md`;
3. verify repository, branch, remotes, local/origin HEAD equality, and clean worktree;
4. verify `801f3418f4a713d1ffa9aa784d972c3452952eb5` is in history and inspect commits after it; only this prompt-only trajectory commit should follow it;
5. inspect `MessageService.tools`, the unified `messages_send` router at current HEAD, the pre-consolidation implementations at `3b9a4a71...`, `MessagesSendingMode`, destination preparation/revalidation, attachment picker/validator/access code, sender adapters, `MessageSendTests`, `MessageAttachmentSendTests`, tool-schema conventions, and ADRs 0002/0009/0010/0011.

If any unexpected production source/test commit exists after `801f3418...`, stop and report exact state rather than absorbing it.

Do not amend, rebase, squash, reset, force-push, or rewrite reviewed history.

## Settled product decision

The user explicitly reversed the unified `messages_send` public API before manual acceptance.

The desired final public send surface is **exactly two tools with these exact names**:

- `message_send_text`
- `message_send_attachment`

Do not normalize those names back to the older plural `messages_*` send names. Other existing read-only Messages tools retain their existing names; this task changes only the public send-tool names/surface.

Do not retain `messages_send`, `messages_send_attachment`, or any unified/legacy send alias unless repository evidence establishes a released compatibility requirement. None is currently known on this feature-completion branch. If you find such evidence, stop and report it before adding compatibility surface.

### Why the split is now intentional

Messages' installed scripting interface submits one direct `send` parameter as either text or file. A body plus attachment therefore requires two sequential Messages submissions, introducing partial-success semantics and violating this project's one-dispatch-per-operation/no-retry invariant.

The final API should map one MCP send operation to one Messages submission class:

- `message_send_text` -> one text submission or, for a verified-new direct recipient, the existing human-controlled Messages composition flow;
- `message_send_attachment` -> one picker-selected file submission to one existing conversation.

Do not support atomic body + attachment/caption in either tool. A caption is a separate `message_send_text` operation with its own authorization/submission semantics.

## `message_send_text` contract

Restore the pre-consolidation text-tool behavior, under the new exact public name `message_send_text`.

Inputs:

- exactly one destination selector: `recipient`, `recipients`, or `chat_id`;
- `body`: non-empty plain-text message body.

No attachment/file/path/bytes/source argument belongs on this tool.

Preserve the previously reviewed text routing exactly:

- unique existing direct conversation -> existing AppleScript text-send pipeline;
- exact existing group or explicit `chat_id` -> same existing AppleScript text-send pipeline;
- verified-new direct recipient -> existing human-completed `NSSharingService.Name.composeMessage` flow;
- ambiguous, incomplete, stale, invalid, or automation-unaddressable destination -> fail closed;
- no new group creation, transport selector, retry, fallback, or delivery claim.

### Restore missing-body elicitation

The unified experiment removed the old missing-body elicitation. Restore the established text-only behavior because the payload is unambiguous again:

- if the caller supplies a valid destination but omits `body`, request the existing MCP form elicitation for the missing non-empty body;
- accepting the input supplies the body, but is **not** final send authorization;
- in Ask Before Sending mode, the exact destination + resolved body must still go through the separate final confirmation before an existing-conversation submission;
- in Send Automatically mode, the app-owned mode may skip only that final confirmation, not the missing-input elicitation;
- for verified-new-recipient composition, the elicited body seeds the same human-controlled Messages composer and there is no separate immutable iMCP final confirmation because the human can edit/send in system UI;
- decline/cancel/malformed missing-body elicitation remains terminal with zero submission/composition as appropriate.

Prefer restoring the previously tested pre-consolidation implementation from repository history rather than inventing a new elicitation model.

## `message_send_attachment` contract

Restore the already-reviewed standalone picker attachment behavior from `3b9a4a71...`, under the new exact public name `message_send_attachment`.

Inputs in this slice:

- exactly one destination selector: `recipient`, `recipients`, or `chat_id`;
- **no body/caption**;
- **no attachment wrapper/source argument**;
- **no path, filename, URL, file bytes, or serialized content**.

The native picker itself supplies the file after destination resolution.

Preserve the reviewed pipeline:

1. validate/resolve one exact existing destination;
2. verified-new recipient fails unsupported before picker/composition/dispatch;
3. run the existing non-prompting addressability preflight when safe;
4. present the native single-file picker;
5. acquire security-scoped access and enforce the existing bounded file policy;
6. authorize according to the global Sending mode: Ask shows the existing immutable attachment confirmation; Send Automatically skips only that final confirmation;
7. revalidate the exact destination;
8. revalidate file identity/properties;
9. request/verify Messages Automation/TCC and exact chat addressability;
10. dispatch exactly once through the fixed typed-file AppleScript path;
11. return the existing privacy-redacted submitted result.

The picker remains mandatory in both Sending modes and is never itself authorization.

Future handoff-directory and serialized/base64 attachment ingress are separate work. When later approved, they should extend `message_send_attachment` rather than create another top-level send tool.

## Global Sending mode remains unchanged

There is still one app-owned global `MessagesSendingMode`:

- Ask Before Sending: payload-specific final confirmation is required for eligible existing-conversation sends;
- Send Automatically: explicit user opt-in skips only that final confirmation.

Both `message_send_text` and `message_send_attachment` use the same live provider, evaluated per call. No caller argument, elicitation response, client name, environment variable, build flag, or debug path may enable or override automatic mode.

Do not reintroduce direct/group/text/attachment authorization granularity.

## Implementation guidance

Prefer the smallest correction that makes the reviewed paths recognizable.

The current unified `sendText`/`sendAttachment` private helpers may be reused if that produces a cleaner diff, but do not preserve the unified payload router merely for its own sake. The final public tools should each parse only their own schema and call exactly one internal pipeline.

For text, restore the pre-consolidation missing-body elicitation behavior from history. For attachment, remove the unified `attachment: {"source":"picker"}` input shape and return to picker-only input semantics.

Preserve one dispatch call site per operation and no fallback between tools.

Do not modify the fixed AppleScript sender, file validator, destination resolution semantics, or signing/entitlement architecture unless repository reality reveals a concrete defect directly caused by this correction. If so, stop and report before broadening scope.

## Required focused tests

Refactor existing consolidation tests back toward the final split surface without discarding the security coverage. At minimum prove:

1. `MessageService.tools` advertises **exactly** `message_send_text` and `message_send_attachment` as send-capable Messages tools; `messages_send`, `messages_send_attachment`, and the unified alias are absent.
2. `message_send_text` schema exposes destination selectors + `body`, no attachment/file/path/source/mode/bypass fields, and preserves existing text input semantics.
3. `message_send_attachment` schema exposes only destination selectors in the current slice, with no body/caption/path/file/bytes/source/mode/bypass fields.
4. Text direct/group/chat_id behavior remains intact.
5. Missing text body is elicited again; accepted elicited body is still followed by separate Ask-mode final confirmation for an existing conversation.
6. Missing-body elicitation decline/cancel/malformed content sends nothing.
7. Ask Before Sending requests exactly one final text confirmation for existing-conversation text and exactly one final attachment confirmation after picker selection for attachments.
8. Send Automatically skips only those final confirmations while preserving all downstream revalidation/Automation/one-dispatch behavior for both tools.
9. Live Sending-mode changes are observed without reinitializing `MessageService` for both operations; reuse existing coverage where practical.
10. Text verified-new recipient still opens human-controlled Messages composition; attachment verified-new recipient still fails before picker/composer/dispatch.
11. Picker cancellation, stale destination, changed/replaced/enlarged/disappeared file, Automation denial/unavailability, and Ask-mode attachment confirmation decline/cancel remain fail-closed with zero attachment dispatch.
12. Neither public tool can express body + attachment in one invocation; there is no code path that turns one MCP operation into two Messages submissions.
13. Existing read-only Messages behavior and unrelated services are unchanged.
14. Result semantics remain submitted/completed, never delivered.

Preserve or strengthen existing event/order assertions. Do not weaken race-defense or authorization tests to make the API correction easier.

## ADR and documentation reconciliation

This is another explicit public-API decision change. Preserve decision history rather than rewriting it.

Repository state currently has Accepted ADR 0011 for the unified `messages_send` design. The user explicitly reversed that design before manual acceptance.

Create the next ADR (expected ADR 0012 if repository state agrees) for the final two-tool public API. It may be `Accepted` because the user explicitly chose it.

ADR requirements:

- mark ADR 0011 `Superseded` by ADR 0012;
- explain that ADR 0011 was implemented and code-reviewed but never manually accepted before the user reversed the API decision;
- keep ADR 0009's historical supersession chain intact rather than pretending history did not happen;
- ADR 0012 must explicitly carry forward the still-binding attachment safety/validation contract from ADR 0009 and the global Sending-mode behavior from ADR 0010;
- explain why separate text/attachment operations now intentionally map to one Messages submission class each and avoid partial-success semantics from text + file;
- record the exact final tool names `message_send_text` and `message_send_attachment`;
- record restored text missing-body elicitation as part of returning to a dedicated text operation.

Update `docs/decisions/README.md` and reconcile ADR 0010 wording to the final two-tool surface.

Inspect/update as applicable:

- `README.md`;
- `docs/messages-write-plan.md`;
- tool descriptions/parameter descriptions in `App/Services/Messages.swift`;
- `docs/project-reports/unified-messages-send-tool-2026-08-16.md` with a short forward note that the unified API was superseded before manual acceptance; do not rewrite its historical evidence;
- earlier text/attachment automatic-mode reports only with concise forward references if needed;
- any documentation that still presents unified `messages_send` or old plural send-tool names as the desired final public API.

Create one concise sanitized report for this correction under `docs/project-reports/`. It must state current starting head `801f3418...`, the user reversal, final tool names, implementation commit(s), restored elicitation behavior, files/symbols changed, verification evidence, remaining manual gate, and next bounded action. No raw logs or private values.

## Security and privacy invariants

This API correction must not weaken:

- exact destination selector validation;
- direct/group ambiguity and incomplete-membership failure;
- verified-new-recipient route distinction;
- non-prompting-only preflight before final authorization;
- mandatory picker for the current attachment operation;
- bounded attachment validation;
- security-scoped access lifetime;
- destination revalidation;
- file identity/property revalidation;
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

Use only synthetic values in tests/docs. Do not access, print, log, or commit real Messages/Contacts contents or private attachment paths/content.

## Verification

Run narrow tool-schema/text-elicitation/attachment-path tests first, then full verification.

At minimum:

- focused `MessageSendTests` and `MessageAttachmentSendTests` for the final two public tools;
- any tool-list/schema regression tests affected by the renamed surface;
- `swift format lint --strict --recursive App AppTests`;
- `git diff --check`;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- `imcp-server`/CLI build if shared compilation requires it;
- do not spend time debugging the known unrelated `CLITests/test_elicitation_proxy.py` `DYLD_FRAMEWORK_PATH` fragility unless this correction materially changes that path;
- regenerate the signed `.build/ManualVerification` app with the established signing procedure;
- `codesign --verify --strict` the signed app;
- confirm effective entitlements and Hardened Runtime are unchanged/unweakened.

No automated verification may send a real message or attachment.

Perform adversarial self-review for: any legacy/unified alias still advertised; a tool reaching the wrong internal pipeline; text missing-body elicitation being mistaken for final authorization; caller-controlled automatic-send bypass; picker bypass; weakened destination/file race checks; two dispatches from one MCP operation; retry/fallback; privacy leak; or changed new-recipient behavior.

## Manual checkpoint to prepare, but do not execute

Do not perform any real send during implementation or automated verification.

After supervising review, the human checkpoint should be minimal and use only the final tool names:

1. Confirm the connected MCP client advertises `message_send_text` and `message_send_attachment` and does not advertise unified/old send aliases.
2. With Ask Before Sending selected, invoke `message_send_text` for an existing conversation and cancel its final confirmation; verify nothing sends. If practical, also exercise omitted-body elicitation non-destructively and then cancel final confirmation.
3. Still in Ask mode, invoke `message_send_attachment`, choose an explicitly selected supported file, then cancel final confirmation; verify nothing sends.
4. Without restarting iMCP, switch to Send Automatically and perform **one explicitly authorized attachment submission** through `message_send_attachment`; picker still appears, final confirmation does not.
5. Switch back to Ask Before Sending and verify a later attachment invocation presents final confirmation again; cancel is sufficient.

No additional real text send is required merely because the public text tool was renamed; its automatic runtime path was already accepted before this correction unless supervising review finds a reason to reopen that gate.

Any real send requires separate explicit human authorization of the exact destination and exact body/file. Claude must not choose or perform those values.

## Explicit exclusions

Do not implement:

- a unified send alias;
- body + attachment/caption in one operation;
- handoff-directory attachment ingress;
- serialized/base64 attachment ingress;
- arbitrary local path/file-name/file-bytes MCP input;
- multiple attachments;
- verified-new-recipient attachment composition;
- unattended new-recipient text sending;
- Shortcuts/Accessibility experiments;
- per-client authorization;
- operation-class authorization granularity;
- circuit breaker defaults/UI;
- cross-call idempotency;
- Recent Automation Activity;
- trusted-client identity hardening;
- CLI path-fragility cleanup;
- upstream PR decomposition;
- unrelated cleanup/refactors.

## Git and handoff

Use additive commits only. Do not rewrite `801f3418...` or any reviewed history.

A reasonable implementation commit message is:

`refactor: split Messages text and attachment send tools`

Commit implementation/docs/report changes and push normally to `origin/feat/messages-write-foundation`.

Then:

- `git fetch origin`;
- verify local HEAD exactly equals `origin/feat/messages-write-foundation`;
- verify worktree clean.

Do not open or merge a maintainer PR. Do not force-push.

## Stopping point

STOP after:

- the only public Messages send tools are exactly `message_send_text` and `message_send_attachment`;
- text missing-body elicitation is restored and remains distinct from final send authorization;
- existing reviewed text and attachment pipelines and global Sending-mode behavior remain intact;
- one-dispatch/no-fallback and all validation/revalidation/privacy invariants remain intact;
- ADR/docs accurately preserve the unified experiment as superseded history and record the final split-tool decision;
- focused/full tests and builds pass;
- signed ManualVerification build is regenerated and verified;
- sanitized report is committed;
- branch is pushed normally, local HEAD equals origin, and worktree is clean.

Do not perform the human runtime checkpoint. The next gate is supervising review of the exact pushed correction head, then the compact manual verification above.

When complete, the user should only need to say **done**.
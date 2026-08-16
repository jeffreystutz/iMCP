# Current Claude Code Task

**Status:** active implementation

**Recommended session:** continue the current Claude Code session if available; otherwise a fresh session is fine  
**Recommended model:** Sonnet  
**Effort:** high — the code change is localized, but it crosses the Messages authorization boundary and must preserve exact fail-closed sequencing.

This file is the canonical supervising prompt for the next bounded coding task.

## Repository and accepted state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The simplified global Sending-mode Settings/model implementation is fully accepted after supervising code review and the user's manual Settings UX acceptance on 2026-08-16.

Accepted source implementation:

`968b703a901a1ec16056fc98ebab9f03c15c16e6` — `checkpoint: simplify automatic sending settings`

Accepted reviewed branch head including documentation/verification:

`b2795b45cce861ffc6b8577d932ca8ab10ee2fef`

A supervising governance commit after that accepted head is expected:

`6b79f309c42ed5340912958a473102cab1b6dad7` — updates only `AGENTS.md` so the binding safety contract matches the accepted global Sending mode. It does not change production code.

The branch will also contain the prompt-only commit that published this file. Prompt/governance commits are trajectory evidence, not production acceptance.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow `imessage-mcp/coding-agent-bootstrap` from Hexa as required by `AGENTS.md`;
3. verify repository, branch, remotes, local/origin HEAD equality, and clean worktree;
4. verify `b2795b45cce861ffc6b8577d932ca8ab10ee2fef` is in history;
5. inspect commits after `b2795b45...` and confirm they are only the expected supervising `AGENTS.md` reconciliation and this prompt file;
6. inspect the current `messages_send` implementation, `MessagesSendingMode`, `MessageSendTests`, confirmation requester seam, and relevant ADRs before changing source.

If unexpected production source/test changes exist after `b2795b45...`, stop and report the exact state rather than absorbing or redesigning around them.

Do not amend, rebase, squash, reset, force-push, or rewrite reviewed history.

## Settled product behavior

There is one app-owned global `MessagesSendingMode` for all connected MCP clients:

- `askBeforeSending` — factory default;
- `sendAutomatically` — explicit user opt-in in iMCP Settings.

No MCP argument, prompt, elicitation response, client name, connection metadata, build flag, environment variable, debug path, or injected caller-controlled Boolean may enable, weaken, or override this mode.

This task wires the accepted mode into **existing-conversation plain-text `messages_send` only**.

For an existing direct or group conversation:

- **Ask Before Sending:** preserve the current final confirmation behavior exactly, including the existing confirmation-presentation choice (Best available / MCP form / iMCP app).
- **Send Automatically:** bypass only that final per-send confirmation, then continue through the same cancellation check, destination revalidation, Automation authorization/addressability verification, one dispatch, no retry, redacted result, and submitted-not-delivered semantics.

The mode is global, so direct vs. group and recipient/recipients/chat_id selectors do not get separate authorization behavior.

### Explicitly unchanged in this slice

- Verified-new-recipient sending remains the current human-completed `NSSharingService` Messages compose flow. It never becomes unattended here.
- `messages_send_attachment` remains confirmation-required even when global Sending mode is Send Automatically. Attachment runtime wiring is the next separate slice.
- Tool input schemas must not gain a sending-mode/confirmation-bypass argument.
- Destination selection/matching behavior does not change.
- AppleScript source and descriptor-based dispatch architecture do not change.

## Current text-send sequence to preserve

At the accepted head, an existing-conversation `messages_send` call follows this shape:

1. resolve/validate input;
2. prepare one exact destination;
3. if verified-new recipient, return through system Messages composition;
4. non-prompting preflight addressability check when existing Automation authority makes that safe;
5. build and request the final existing-chat confirmation;
6. cancellation check;
7. revalidate that the exact destination is still unchanged;
8. cancellation check;
9. request/verify Messages Automation authority and exact chat addressability;
10. perform exactly one `sender.submit`;
11. return the existing redacted submitted result.

The automatic-mode path should differ at only step 5: it skips the final confirmation. It must then rejoin the same post-authorization sequence before any permission prompt or dispatch.

Do not create a second dispatch path that duplicates revalidation or send logic.

## Implementation guidance

Use the smallest repository-native seam that makes the mode deterministic in tests and live-updatable in production.

The production authorization decision must read the current app-owned `MessagesSendingMode` for each send, not snapshot it only when `MessageService` is initialized. A Settings change must therefore affect a later call without restarting the service.

A small injected mode-provider closure/value source on `MessageService`, defaulting to `MessagesSendingMode.load()` at call time, is reasonable if it fits existing test conventions. Do not introduce a new configuration subsystem, client policy object, or generalized authorization framework for this slice.

Place the authorization branch immediately around the existing final-confirmation request so both modes share the same preparation, preflight, cancellation, revalidation, Automation, dispatch, logging, and result code.

Update comments/docstrings that currently equate "authorized" exclusively with an accepted per-send confirmation. Under the accepted architecture, an existing text send is authorized either by the required final confirmation in Ask Before Sending mode or by the user's persistent app-owned Send Automatically setting. This wording change must not weaken any other invariant.

Do not add new production logs merely to record message content, destination, mode history, or client identity. If any categorical mode logging is genuinely useful, it must contain no recipient, participant, chat ID, body, file, or other private value; prefer no new logging unless required.

## Required behavior and tests

Extend existing repository test seams, primarily `AppTests/MessageSendTests.swift`, and add only focused support code needed for deterministic mode control.

At minimum prove:

1. **Ask Before Sending preserves existing behavior**: an existing-conversation text send requests exactly one final confirmation before revalidation/Automation/dispatch.
2. **Automatic direct send**: an existing direct conversation in Send Automatically mode requests zero final confirmations and still performs exactly one successful dispatch only after destination revalidation and Automation/addressability verification.
3. **Automatic group send**: an existing group conversation gets the same global bypass behavior and still dispatches once to the exact resolved chat; no group is created or substituted.
4. **Live mode changes are observed**: changing the mode between two calls on the same service instance changes whether confirmation is requested, without rebuilding/reinitializing the service.
5. **Automatic mode does not weaken stale-destination defenses**: if the existing conversation changes/disappears between preparation and dispatch, the call fails closed with zero dispatch even though confirmation was skipped.
6. **Automation denial/unavailability still fails with zero dispatch** in automatic mode.
7. **Verified-new recipient remains human-completed composition** in automatic mode and does not route through `sender.submit`.
8. **Attachments are not wired yet**: with Send Automatically selected, `messages_send_attachment` still reaches its existing final confirmation path. Add a focused regression test in the existing attachment test file if the current seams make this inexpensive.
9. **Caller cannot request bypass**: tool schema remains unchanged, with no new mode/automatic/confirmation-bypass input. Existing `additionalProperties: false` behavior remains.
10. Existing confirmation decline/cancel/malformed paths in Ask Before Sending remain terminal with zero dispatch.
11. Existing result truthfulness is unchanged: success means Messages accepted one submission, never delivery.

Preserve or strengthen any existing ordering assertions around preflight, confirmation, revalidation, Automation permission, and dispatch. Do not weaken tests merely to accommodate the new branch.

## Security and privacy invariants

Automatic mode bypasses only final confirmation for this accepted operation class.

It must not bypass or weaken:

- exact recipient/group/chat_id validation;
- direct/group ambiguity failure;
- incomplete membership failure;
- exact matched-conversation equality;
- explicit chat-id re-resolution;
- destination revalidation immediately before dispatch;
- non-prompting-only preflight rule before authorization;
- Messages Automation/TCC permission checks;
- exact chat addressability verification;
- cancellation before dispatch;
- fixed AppleScript source;
- Apple Event descriptor inputs for chat GUID/body;
- one-dispatch/no-retry semantics;
- ambiguous-submission handling;
- log/result privacy redaction;
- submitted-not-delivered truthfulness.

No real Messages or Contacts data may appear in tests, logs, docs, prompts, reports, or commits. Use synthetic values only.

## Documentation and ADR reconciliation

The manual Settings UX checkpoint has now passed. Update repository documentation accordingly.

At minimum inspect and update:

- `docs/decisions/0010-global-automatic-send-authorization-policy.md`;
- `docs/decisions/0002-messages-automation-security-boundary.md`;
- `docs/decisions/README.md` if its status/index text needs adjustment;
- `docs/messages-write-plan.md`;
- `README.md` where it currently implies every existing-chat text send always requires confirmation;
- `docs/project-reports/global-send-authorization-settings-2026-08-16.md`.

Required documentation meaning:

- ADR 0010 may now be marked **Accepted** because the user explicitly chose the global binary model and manually accepted the final Settings UX.
- Reconcile ADR 0002's older absolute "confirmation for every submission, no opt-out" language with accepted ADR 0010. ADR 0010 supersedes only that unconditional-confirmation portion; preserve ADR 0002's fixed-script, exact-destination, revalidation, TCC, privacy, one-dispatch/no-retry, and truthful-result security boundaries. Do not casually mark the whole ADR superseded if that would imply those remaining boundaries are obsolete.
- Record that the text-send runtime path is now being wired to the accepted mode, while attachments remain confirmation-required until their separate slice.
- Update `messages_send` public description/copy so it no longer falsely promises required confirmation for every existing-chat send. It should explain that existing-chat text submission follows the user's global Sending mode, while verified-new recipients still open Messages UI for human completion.
- Do not add a tool argument for the mode.
- Clean the prior Settings report's stale self-referential documentation-SHA wording rather than trying to make a document name the commit that contains itself.

Create one concise sanitized implementation report for this runtime-wiring slice under `docs/project-reports/`. It must identify the accepted starting head, implementation SHA(s), files/symbols changed, test/build evidence, unresolved manual gate, and next bounded action. No raw logs or private values.

## Verification

Run the narrowest relevant tests first, then the full applicable repository verification.

At minimum:

- focused `MessageSendTests` covering both modes and fail-closed ordering;
- focused attachment regression test if added;
- `swift format lint --strict --recursive App AppTests` (or the repository's stronger established lint command if current instructions require it);
- `git diff --check`;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- `imcp-server`/CLI build if shared compilation requires it;
- do not spend time debugging the known unrelated `CLITests/test_elicitation_proxy.py` `DYLD_FRAMEWORK_PATH` path-fragility unless this task changes that path or its behavior materially changes;
- regenerate the signed `.build/ManualVerification` app using the established procedure;
- `codesign --verify --strict` the signed app;
- confirm the effective entitlement set and Hardened Runtime are unchanged/unweakened.

No automated verification step may send a real message.

Perform an adversarial self-review of the task diff for any path that could dispatch without either Ask-mode confirmation or the accepted global automatic authorization, any caller-controlled bypass, duplicated dispatch path, retry/fallback, privacy leak, or attachment/new-recipient scope creep.

## Manual checkpoint to prepare, but do not execute

After supervising review of the exact pushed head, the user will perform the externally observable test. Claude must **not** send any real message during implementation or verification.

Prepare the signed app so the later human checkpoint can verify:

1. In Ask Before Sending, an existing-conversation text call still presents the configured final confirmation; cancel sends nothing.
2. In Send Automatically, an explicitly authorized existing-conversation text call submits without the final iMCP/MCP confirmation.
3. Switching back to Ask Before Sending restores confirmation on the next call without app restart.
4. New-recipient behavior still opens human-controlled Messages composition.
5. Attachment sending still requires its existing picker + confirmation in this slice.

Any real send in that checkpoint requires separate explicit user authorization of the exact destination/conversation and exact body. Do not choose those values yourself and do not perform that test as the coding agent.

## Git and handoff

Use additive commits only. Meaningful checkpoint commits are allowed; do not amend/rewrite accepted history.

A reasonable implementation commit message is:

`feat: honor global Sending mode for existing text sends`

Update/create the sanitized tracked report, commit it additively, and push normally to:

`origin/feat/messages-write-foundation`

Then:

- `git fetch origin`;
- verify `git rev-parse HEAD` exactly equals `git rev-parse origin/feat/messages-write-foundation`;
- verify the worktree is clean.

Do not open or merge a maintainer PR. Do not force-push.

## Explicit exclusions

Do not implement in this task:

- attachment automatic-mode bypass;
- persistent attachment handoff directory;
- serialized/base64 attachment ingress;
- unattended new-recipient sending;
- Shortcuts experiments;
- Accessibility/UI scripting;
- per-client authorization;
- direct/group/text/attachment authorization granularity;
- circuit breaker defaults or UI;
- cross-call idempotency;
- Recent Automation Activity;
- trusted-client identity hardening;
- CLI path-fragility cleanup;
- upstream PR decomposition;
- unrelated refactors or cleanup.

## Stopping point

STOP after:

- existing-conversation plain-text `messages_send` honors the accepted global Sending mode exactly as specified;
- Ask mode behavior remains intact;
- automatic mode skips only final confirmation and preserves every downstream safety step;
- new-recipient and attachment behavior remain unchanged;
- docs/ADRs/public description accurately reflect the accepted state;
- focused and full verification pass;
- signed ManualVerification build is regenerated and verified;
- implementation/report commits are pushed normally;
- local HEAD equals origin and the worktree is clean.

Do not perform the real-message manual checkpoint. The next gate is supervising review of the exact pushed head, then explicit user-authorized manual verification.

When complete, the user should only need to say **done**; do not require copy/paste of the report.
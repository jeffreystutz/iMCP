# Current Claude Code Task

**Status:** active implementation

**Recommended session:** continue the current Claude Code session if available; otherwise a fresh session is fine  
**Recommended model:** Sonnet  
**Effort:** high — the code change is localized, but it crosses the Messages authorization boundary and must preserve destination/file race defenses and one-dispatch semantics.

This is the canonical supervising prompt for the next bounded coding task.

## Repository and accepted state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The global binary Messages Sending mode and its existing-conversation plain-text runtime wiring are fully accepted.

Latest fully accepted production/review head:

`eb64ee2de11a50d63bc1d64362136d1251f0bdf4` — `feat: honor global Sending mode for existing text sends`

That head passed supervising code review and the user completed the real runtime checkpoint on 2026-08-16:

- Ask Before Sending presented the existing text confirmation and cancel sent nothing;
- without restarting iMCP, Send Automatically submitted one explicitly authorized existing-conversation text message without a final iMCP/MCP confirmation;
- switching back to Ask Before Sending restored confirmation on the next call.

The branch will also contain the prompt-only commit that published this file. Prompt/report/governance commits are trajectory evidence, not production acceptance.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow `imessage-mcp/coding-agent-bootstrap` from Hexa as required by `AGENTS.md`;
3. verify repository, branch, remotes, local/origin HEAD equality, and clean worktree;
4. verify `eb64ee2de11a50d63bc1d64362136d1251f0bdf4` is in current history;
5. inspect commits after `eb64ee2d...` and confirm they are only the expected prompt-only trajectory commit for this task;
6. inspect the current `messages_send_attachment` implementation, `MessagesSendingMode`, the existing injected `sendingMode` seam on `MessageService`, `MessageAttachmentSendTests`, `MessageSendTests`, attachment validation/access code, and ADRs 0009/0010 before changing source.

If unexpected production source/test changes exist after `eb64ee2d...`, stop and report the exact state rather than absorbing them.

Do not amend, rebase, squash, reset, force-push, or rewrite reviewed history.

## Concrete goal

Make **existing-conversation picker-based `messages_send_attachment`** honor the same accepted global app-owned `MessagesSendingMode` already used by existing-conversation text sends.

There is one global mode for all eligible existing-conversation programmatic sends:

- `askBeforeSending` — factory default;
- `sendAutomatically` — explicit user opt-in in iMCP Settings.

No MCP argument, prompt, elicitation response, client identity/name, connection metadata, build flag, environment variable, debug path, or caller-controlled Boolean may enable or override this mode.

This task does **not** add fully unattended attachment ingress. The existing native file picker remains mandatory because the MCP tool still supplies no file path or bytes.

## Required attachment behavior

The current accepted attachment flow is:

1. resolve one exact existing destination;
2. reject verified-new recipients rather than composing or falling back;
3. run the existing non-prompting addressability preflight when safe;
4. present the native single-file picker;
5. acquire security-scoped read access and validate the selected file against the existing bounded file policy;
6. request immutable final confirmation naming the exact destination and file display name/type/size;
7. cancellation check;
8. revalidate the exact destination;
9. revalidate the selected file and require unchanged identity/bounded properties;
10. cancellation check;
11. request/verify Messages Automation authority and exact chat addressability;
12. perform exactly one attachment dispatch;
13. return the existing redacted submitted result.

After this task:

### Ask Before Sending

Preserve the sequence above exactly. The existing attachment confirmation remains mandatory and uses the existing configured confirmation presentation mechanism.

### Send Automatically

Preserve steps 1–5 exactly, then **skip only step 6, the final attachment confirmation**. Rejoin the exact same shared sequence at the existing cancellation check and continue through destination revalidation, file revalidation, Automation/addressability verification, exactly one dispatch, logging, and truthful result handling.

Do not create a second attachment dispatch path or duplicate revalidation logic.

The current global mode should be read at the authorization decision after file selection/validation, using the existing live `sendingMode` provider already on `MessageService`. Do not snapshot the mode only when the service is initialized. A later call on the same service instance must observe a Settings change without app restart.

## Important product semantics

In Send Automatically mode, the native picker is still shown. Selecting a file is **not** a substitute per-send authorization mechanism; the user's persistent app-owned Send Automatically choice is the authorization that permits the final-confirmation step to be skipped. The picker remains solely the trusted local file-selection/input mechanism for this slice.

Therefore:

- do not add a second warning or confirmation after the picker in automatic mode;
- do not remove or bypass the picker;
- do not turn picker selection into a new persisted permission;
- do not expose the selected path to MCP;
- do not claim this slice is fully unattended attachment automation.

Persistent handoff-directory and serialized/base64 attachment ingress are separate later work.

## Explicitly unchanged

- `messages_send` text behavior at accepted head `eb64ee2d...`.
- Verified-new-recipient text composition through human-controlled `NSSharingService`.
- Verified-new-recipient attachment behavior remains unsupported and fails without composition or fallback.
- The attachment tool accepts no path, file name, file bytes, body, caption, mode, or confirmation-bypass argument.
- Destination matching/resolution semantics remain unchanged.
- Existing file policy remains exactly one regular nonempty supported file, at most 25 MiB, with the existing type/package/symlink/executable restrictions.
- Security-scoped access must remain active through validation/revalidation and synchronous dispatch, then be released.
- AppleScript source and typed file-URL descriptor dispatch remain unchanged unless repository reality shows a necessary bug fix; if so, stop and report before broadening scope.
- No new group creation, transport selection, retry, fallback, queue, or delivery claim.

## Implementation guidance

Reuse the existing `MessageService.sendingMode` provider introduced and accepted in the text-send slice. Do not add another policy object or attachment-specific mode.

Place the mode branch immediately around the existing attachment final-confirmation construction/request. In automatic mode, avoid constructing the confirmation presentation at all. Both modes must share all code before and after that branch.

Keep the guard that proves an exact existing chat is present before the authorization branch. In Ask mode it supplies confirmation content; in automatic mode it still represents a fail-closed invariant that the destination is an existing resolvable conversation.

Update comments that currently assume final confirmation is always the authorization boundary. Under the accepted architecture, an attachment send is authorized either by Ask-mode final confirmation or by the user's persistent app-owned Send Automatically setting.

Do not add production logs containing destination, handles, chat IDs, file path, file name, file type, file size, file contents, or mode history. Prefer no new logging unless needed.

## Required focused tests

Extend `AppTests/MessageAttachmentSendTests.swift` using the existing deterministic `sendingMode` seam. Preserve all existing tests.

At minimum prove:

1. **Ask Before Sending remains unchanged:** an existing attachment send presents exactly one final confirmation before destination/file revalidation, Automation, and dispatch.
2. **Automatic direct attachment:** picker still runs; selected file is validated; zero final confirmations are requested; exact destination and file are still revalidated; exactly one attachment dispatch occurs only after Automation/addressability verification.
3. **Automatic group attachment:** same global bypass applies to an exact existing group, with the group still re-resolved/revalidated and exactly one dispatch to the exact resolved chat.
4. **Live mode changes:** two attachment calls on the same `MessageService` instance observe Ask then Automatic (and, if inexpensive, Automatic then Ask) without rebuilding/reinitializing the service.
5. **Picker cancellation in automatic mode:** cancellation dispatches nothing. Automatic mode must never bypass the picker.
6. **Destination change/disappearance in automatic mode:** stale destination still fails closed with zero dispatch.
7. **File change/replacement/modification/enlargement/disappearance in automatic mode:** existing file revalidation still fails closed with zero dispatch. One or more representative focused tests may reuse existing mutation seams; do not duplicate the entire file-policy test matrix if the common code is demonstrably shared.
8. **Automation denial/unavailability in automatic mode:** still fails with zero dispatch.
9. **Verified-new recipient remains unsupported:** automatic mode does not open a composer or dispatch an attachment.
10. **Tool schema remains unchanged:** no file/path/bytes/mode/bypass input is added; `additionalProperties: false` remains.
11. **Ask-mode decline/cancel/malformed confirmation paths remain terminal with zero dispatch.**
12. **Result truthfulness remains unchanged:** success means Messages accepted one attachment submission, never delivery.

Preserve or strengthen existing event/order assertions around preflight, picker/validation, confirmation when applicable, destination/file revalidation, Automation permission, addressability, and dispatch. Do not weaken existing tests to accommodate the mode branch.

## Security/privacy invariants

Automatic mode bypasses only the final attachment confirmation. It must not bypass or weaken:

- exact destination selector validation;
- direct/group ambiguity and incomplete-membership failure;
- verified-new-recipient rejection;
- non-prompting-only preflight rule before authorization;
- mandatory native picker in this slice;
- bounded file validation;
- security-scoped file access lifetime;
- destination revalidation before dispatch;
- file identity/property revalidation before dispatch;
- Messages Automation/TCC permission checks;
- exact chat addressability verification;
- cancellation before dispatch;
- fixed AppleScript source;
- typed file-URL Apple Event descriptor input;
- one-dispatch/no-retry/no-fallback behavior;
- ambiguous-submission handling;
- privacy redaction in logs/errors/results;
- submitted-not-delivered truthfulness.

Use only synthetic values in tests/docs. Do not access, print, log, or commit real Messages/Contacts data or private file paths/content.

## Documentation reconciliation

Update documentation so it no longer says picker-based attachments are always confirmation-required once this implementation exists.

At minimum inspect/update as applicable:

- `README.md`;
- `docs/decisions/0010-global-automatic-send-authorization-policy.md`;
- `docs/decisions/0009-attachment-only-existing-chat-submission.md`;
- `docs/messages-write-plan.md`;
- `docs/project-reports/existing-conversation-text-send-automatic-mode-wiring-2026-08-16.md` only if a small cross-reference is needed; do not rewrite its accepted evidence;
- any tool description/comment in `App/Services/Messages.swift` that promises attachment confirmation unconditionally.

Required documentation meaning:

- the global Sending mode applies equally to eligible existing-conversation text and picker-based attachment submissions;
- Ask Before Sending still presents the existing attachment confirmation with destination + file name/type/size;
- Send Automatically skips that final confirmation but **does not skip the native picker** or file/destination revalidation;
- picker-based attachment sends are therefore not fully unattended;
- no caller can select or override the mode;
- verified-new-recipient attachments remain unsupported;
- persistent handoff-directory and serialized-content ingress remain separate future mechanisms needed for fully unattended attachment workflows.

ADR 0009 describes the accepted original confirmation-required attachment slice. Reconcile its unconditional-confirmation wording narrowly with accepted ADR 0010 rather than implying its file-trust, revalidation, fixed-script, or one-dispatch boundaries are obsolete.

Create one concise sanitized implementation report for this slice under `docs/project-reports/`. It must identify accepted starting head `eb64ee2d...`, implementation commit(s), files/symbols changed, focused/full verification evidence, remaining human runtime gate, and next bounded action. No raw logs or private values.

## Verification

Run narrow attachment-mode tests first, then the full applicable verification.

At minimum:

- focused `MessageAttachmentSendTests` for Ask/Automatic behavior and fail-closed ordering;
- relevant `MessageSendTests` regression coverage to ensure accepted text behavior is unchanged;
- `swift format lint --strict --recursive App AppTests` (or stronger repository-required lint if current instructions require it);
- `git diff --check`;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- `imcp-server`/CLI build if shared compilation requires it;
- do not spend time debugging the known unrelated `CLITests/test_elicitation_proxy.py` `DYLD_FRAMEWORK_PATH` path fragility unless this task materially changes that path;
- regenerate the signed `.build/ManualVerification` app using the established procedure;
- `codesign --verify --strict` the signed app;
- confirm effective entitlements and Hardened Runtime are unchanged/unweakened.

No automated verification step may send a real message or attachment.

Perform an adversarial self-review for any path that can dispatch without either Ask-mode confirmation or the accepted global automatic authorization, any picker bypass, any caller-controlled bypass, any weakened destination/file race defense, duplicated dispatch path, retry/fallback, privacy leak, or new-recipient scope creep.

## Manual checkpoint to prepare, but do not execute

After supervising review of the exact pushed implementation head, the user will perform the externally observable test. Claude must not send any real attachment during implementation or verification.

Prepare the signed build so a later human checkpoint can verify:

1. With Ask Before Sending selected, invoke `messages_send_attachment` for an existing conversation, select an explicitly chosen supported test file, then cancel the final confirmation; verify nothing sends.
2. Without restarting iMCP, switch to Send Automatically, invoke `messages_send_attachment` for the same explicitly authorized existing conversation, select the exact explicitly authorized test file, and verify the file submits after picker selection **without** an iMCP/MCP final confirmation.
3. Switch back to Ask Before Sending and verify a later attachment call again presents final confirmation; cancel is sufficient.

Any real attachment send requires separate explicit human authorization of the exact destination/conversation and exact file. Do not choose those values and do not perform that test as the coding agent.

## Git and handoff

Use additive commits only. Meaningful checkpoint commits are allowed. Do not rewrite accepted history.

A reasonable implementation commit message is:

`feat: honor global Sending mode for existing attachments`

Commit implementation/docs/report changes additively and push normally to:

`origin/feat/messages-write-foundation`

Then:

- `git fetch origin`;
- verify `git rev-parse HEAD` exactly equals `git rev-parse origin/feat/messages-write-foundation`;
- verify the worktree is clean.

Do not open or merge a maintainer PR. Do not force-push.

## Explicit exclusions

Do not implement in this task:

- persistent attachment handoff directory;
- serialized/base64 attachment ingress;
- any MCP attachment path/name/bytes input;
- verified-new-recipient attachment composition;
- unattended new-recipient text sending;
- Shortcuts experiments;
- Accessibility/UI scripting;
- per-client authorization;
- direct/group/text/attachment authorization granularity;
- circuit breaker defaults/UI;
- cross-call idempotency;
- Recent Automation Activity;
- trusted-client identity hardening;
- CLI path-fragility cleanup;
- upstream PR decomposition;
- unrelated refactors or cleanup.

## Stopping point

STOP after:

- picker-based existing-conversation `messages_send_attachment` honors the accepted global Sending mode exactly as specified;
- Ask behavior remains intact;
- automatic mode skips only final attachment confirmation while preserving picker, destination/file validation and revalidation, Automation/addressability, and exactly-one dispatch;
- text/new-recipient behavior remains unchanged;
- docs/public description accurately reflect the new state and its non-unattended picker limitation;
- focused and full verification pass;
- signed ManualVerification build is regenerated and verified;
- implementation/report commits are pushed normally;
- local HEAD equals origin and worktree is clean.

Do not perform the real-attachment manual checkpoint. The next gate is supervising review of the exact pushed head, then explicit user-authorized manual verification.

When complete, the user should only need to say **done**; do not require copy/paste of the report.
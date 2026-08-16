# Current Claude Code Task

**Status:** resume from implementation checkpoint

**Recommended session:** continue the current Claude Code session if available; otherwise a fresh session is fine  
**Recommended model:** Sonnet  
**Effort:** high

This is the canonical handoff for the remaining work on the simplified Messages Sending mode Settings slice.

## Repository state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The simplified Sending-mode implementation has already been durably checkpointed and pushed as:

`968b703a901a1ec16056fc98ebab9f03c15c16e6` — `checkpoint: simplify automatic sending settings`

At the checkpoint, local HEAD and `origin/feat/messages-write-foundation` were verified to match exactly and the worktree was clean.

That checkpoint contains the implementation changes for the product-approved simplification, including the binary `MessagesSendingMode` model, updated Settings UI, confirmation-label cleanup, removal of the rejected granular automatic-send policy, tests, project-file changes, and ADR work already completed before the usage-limit stop.

Do **not** amend, squash, rebase, rewrite, or otherwise modify checkpoint commit `968b703...`.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`
2. verify local HEAD equals `origin/feat/messages-write-foundation`;
3. verify `968b703a901a1ec16056fc98ebab9f03c15c16e6` is in the current history;
4. verify the worktree is clean.

A newer prompt-only commit may exist after `968b703`; that is expected and is not a production change. If there are any other unexpected production changes after `968b703`, stop and report them.

## Settled product model

There is one global Messages **Sending mode** for all connected MCP clients:

- **Ask before sending** — factory default.
- **Send automatically** — explicit user opt-in.

No direct/group or text/attachment authorization matrix remains. That granular model was explicitly rejected after the manual UX checkpoint.

When **Ask before sending** is active, Settings exposes the subordinate **Confirmation method** control:

- **Best available** — existing runtime semantics formerly labeled Automatic;
- **MCP form**;
- **iMCP app**.

When **Send automatically** is active, Confirmation method is irrelevant and should not be presented as a peer control.

Verified-new-recipient sending remains the human-completed `NSSharingService` Messages compose flow. Automatic mode does not make that route unattended.

This milestone is still Settings/model only. Runtime send execution must continue requiring confirmation exactly as before. Do not wire `MessagesSendingMode` into `messages_send`, `messages_send_attachment`, `MessagesSender`, attachment dispatch, or new-recipient composition in this task.

## Remaining task

The implementation checkpoint is already committed. Finish only the remaining documentation and verification work unless verification exposes an actual defect.

### 1. Finish documentation updates

Update the repository documentation that still describes the removed granular category model.

At minimum update:

- `docs/messages-write-plan.md`, especially the Automatic-send authorization policy section;
- `docs/project-reports/global-send-authorization-settings-2026-08-16.md`.

Also inspect the already-edited ADR:

- `docs/decisions/0010-global-automatic-send-authorization-policy.md`

and make only consistency corrections if it still conflicts with the implementation at `968b703`.

The documentation must accurately record:

- global rather than per-client authorization was chosen for product simplicity;
- the first direct/group × text/attachment Settings model failed the human UX checkpoint as too complex;
- the user explicitly chose one binary global Sending mode instead;
- direct/group and text/attachment authorization granularity was removed;
- confirmation presentation is subordinate to Ask before sending;
- the former Automatic presentation label is now Best available while preserving its runtime semantics;
- new-recipient composition remains human-completed;
- runtime send execution still ignores `MessagesSendingMode` in this slice, so confirmation remains mandatory today;
- the next gate is human manual acceptance of the simplified Settings UI.

Keep ADR 0010 `Proposed` until that human manual checkpoint passes.

Do not create a second implementation report. Update the existing report.

### 2. Run final verification

Because the implementation checkpoint changed persisted model and SwiftUI behavior, run the full applicable verification against the exact post-checkpoint state:

- `swift format lint --strict --recursive App AppTests`;
- `git diff --check`;
- focused Sending-mode tests if useful to isolate failures;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- CLI/proxy build if required by shared compilation;
- do not spend time debugging the known unrelated `CLITests/test_elicitation_proxy.py` `DYLD_FRAMEWORK_PATH` fragility unless this task changed that path or its behavior materially changes;
- regenerate the signed `.build/ManualVerification` app using the established repository procedure;
- run `codesign --verify --strict` on the signed manual build;
- confirm effective entitlements are not weakened relative to the prior accepted/manual-verification build.

Do not send a real message and do not access private Messages or Contacts contents.

If verification reveals a real implementation defect in `968b703`, make the smallest additive fix commit needed and document it. Do not rewrite `968b703`.

### 3. Prepare the manual checkpoint

The resulting signed ManualVerification build should allow the user to verify:

1. one clear Sending mode choice;
2. Ask before sending is the default;
3. Confirmation method appears under Ask before sending with Best available / MCP form / iMCP app;
4. choosing Send automatically shows one warning; Cancel preserves Ask before sending, acceptance enables automatic mode;
5. Confirmation method is hidden or clearly inactive under Send automatically;
6. mode persists across Settings reopen and app relaunch;
7. returning to Ask before sending needs no warning and restores Confirmation method;
8. new-recipient copy remains clear that Messages UI is human-completed;
9. Phone Number Region and Trusted Clients remain normal.

No real message is needed for this checkpoint.

### 4. Commit and push the remaining work

Use additive commits only.

Commit the documentation updates and any verification-driven correction separately from `968b703` as appropriate.

Push normally to:

`origin/feat/messages-write-foundation`

Then:

- `git fetch origin`;
- verify `git rev-parse HEAD` exactly equals `git rev-parse origin/feat/messages-write-foundation`;
- verify the worktree is clean.

Do not open or merge a PR. Do not force-push.

## Stopping point

STOP after:

- documentation is consistent with the binary `MessagesSendingMode` implementation;
- final automated/build/signing verification is complete;
- the signed ManualVerification app is ready;
- all remaining changes are committed additively and pushed;
- local HEAD exactly matches origin and the worktree is clean.

Do not wire automatic sending into runtime send execution.

When complete, the user should only need to say **done**; do not require them to copy/paste a report.
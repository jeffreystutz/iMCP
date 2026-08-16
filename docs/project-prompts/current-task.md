# Current Claude Code Task

**Status:** active correction

**Recommended session:** continue the current Claude Code session if it still has the completed slice in context; otherwise use a fresh session  
**Recommended model:** Sonnet  
**Effort:** high

This file is the canonical supervising prompt for the next bounded coding task.

Before doing anything else, run a normal fast-forward pull of `origin/feat/messages-write-foundation`, then read this entire file and execute it as the task specification. Do not rely on prior Claude conversation context unless you are continuing the immediately preceding implementation session.

---

You are making a small additive review correction to the global automatic-send Settings slice in the iMCP macOS project.

## Repository and exact review state

Repository:
- `jeffreystutz/iMCP`
- branch: `feat/messages-write-foundation`

Latest fully accepted production implementation baseline:
- `1822a44b3f40dbda7246ad2753978113aa235de3`

Prompt-only trajectory commit before the implementation:
- `5636e6a8392fab773b017cfb505355cdc75f908b`

Implementation commit under review:
- `d6dc2adbf9df77d8dfc6f1dbeb8f7ca67b348ddf`

Tracked implementation report commit under review:
- `cab286f2caa6be4060c6bd09e59b62047baa3a1e`

The supervising review found the implementation architecture and tests generally sound, but identified two documentation/UX-copy issues that must be corrected before manual Settings acceptance.

Do **not** amend, rebase, squash, or rewrite any of the reviewed commits. Corrections must be additive commits on the active branch.

Before editing:
1. `git pull --ff-only origin feat/messages-write-foundation`
2. verify local HEAD equals origin;
3. verify the reviewed commit chain above is present;
4. verify the worktree is clean.

If the branch contains unexpected production changes after `cab286f2caa6be4060c6bd09e59b62047baa3a1e`, stop and report instead of continuing.

## Settled product decision that documentation must represent accurately

The user explicitly chose **one global set of Messages automatic-send authorization controls that applies to all connected MCP clients**.

The reason for that product choice is primarily **product simplicity**: client-specific approval controls are not worth the additional UX, configuration, pairing/authentication, and implementation complexity for this project.

A prior investigation also established that `clientInfo.name` is caller-supplied/spoofable and therefore should not be described as an authenticated client identity. That is useful supporting context and a reason not to build a fake security boundary on the existing name string, but it was **not the user's decisive reason for choosing the global product model**.

Do not rewrite the user's product decision as though per-client controls were rejected because durable client authentication was technically impossible or mandatory. Per-client authentication work was considered and explicitly rejected as unnecessary complexity.

The pre-existing `trustedClients` name-spoofing issue remains separate and is not a blocker for the global automatic-send policy.

## Correction 1 — contradictory Settings copy

In `App/Views/SettingsView.swift`, the existing Message Sending explanatory copy currently ends with:

> A confirmation is always required.

That is now contradictory to the adjacent Automatic Sending policy and would become false once the already-planned execution wiring is added.

Revise this existing confirmation-presentation help text so it truthfully expresses the distinction:

- `MessagesSendConfirmationMode` controls **how confirmation is presented when confirmation is required**;
- the new global automatic-send policy controls **whether confirmation is required for an eligible operation class**.

Use concise, native Settings copy consistent with the surrounding prose. Do not imply that the new stored policy already changes send behavior in this Settings-only slice.

Preserve the existing statement that new-recipient composition is separate and human-completed.

Do not otherwise redesign the Settings UI.

## Correction 2 — product-decision rationale drift

Correct the rationale in all task-owned repository documentation added/changed by the slice where it currently says or implies that the global policy was selected *because* there is no unspoofable client identity.

At minimum inspect and correct:

- `docs/decisions/0010-global-automatic-send-authorization-policy.md`
- `docs/messages-write-plan.md`
- `docs/project-reports/global-send-authorization-settings-2026-08-16.md`

Required meaning:

1. Per-client automation controls were considered.
2. The user explicitly rejected them as unnecessary product complexity and chose one global policy.
3. Separately, the investigation found `clientInfo.name` is spoofable; therefore the project also should not pretend that the existing declared name is an authenticated authorization identity.
4. No client-profile/pairing/token project is required or planned for the global policy.
5. The pre-existing `trustedClients` spoofing weakness may be hardened separately if desired, but it is not a prerequisite for this feature.

Remove language such as “the product decision, made explicitly given that finding” or equivalent causal claims that substitute the supervising assistant's earlier security recommendation for the user's actual decision.

Do not reopen the settled global-policy decision and do not propose per-client authentication work.

### ADR status

Keep ADR 0010 at its current review-stage status until the supervising reviewer and user complete the Settings manual acceptance checkpoint. Do not mark it Accepted in this correction task.

## Preserve the accepted implementation shape under review

Do not alter the policy model merely because documentation is being corrected.

The reviewed implementation should remain:

- one global `MessagesAutomaticSendPolicy`;
- four current categories: existing direct/group × text/attachment;
- all automatic categories off by factory default;
- one app-owned persisted policy value;
- no new-recipient automatic category yet;
- no per-client policy;
- no client/profile token or pairing;
- no MCP caller-controlled policy mutation;
- no send-path consumption of the policy in this slice.

Do not change send execution.

## Verification

Because this is a small copy/documentation correction:

- run `swift format lint --strict --recursive App AppTests` if Swift source was touched;
- run `git diff --check`;
- build the iMCP Debug app if Settings Swift source changed;
- focused/full tests are optional only if no executable behavior changed beyond static Settings text; if you skip them, state why and retain the prior 260/260 evidence as belonging to `d6dc2ad`, not to the new correction SHA;
- do not send any real message;
- do not perform the manual Settings acceptance yourself.

The signed ManualVerification build may be regenerated if needed so the user's upcoming checkpoint reflects the corrected copy. If regenerated, verify its signature using the established procedure.

## Tracked report

Update the existing tracked report additively in the correction commit so it:

- records the new correction SHA once known;
- describes the two supervising corrections;
- preserves the original implementation/verification evidence accurately;
- states that send execution still ignores the policy;
- uses the corrected product rationale;
- leaves the same manual Settings checkpoint pending.

Do not create a second report for this tiny correction unless repository conventions force it.

Do not attempt to edit old Git commit messages merely because the report-only commit message may contain stale pre-rebase wording. Git history is immutable for this review; the current report file is the authoritative correction.

## Git discipline and handoff

Use additive commit(s) only.

Suggested correction commit message:
- `fix: align automatic-send Settings copy and decision rationale`

Push normally to:
- `origin/feat/messages-write-foundation`

Verify local HEAD equals origin.

Do not open/merge a PR.
Do not force-push.

For this tiny immediate correction, no separate new report file is required beyond updating the existing implementation report.

## Stopping point

STOP after:

- correcting the Settings help text;
- correcting the product rationale in task-owned docs/report;
- running applicable verification;
- regenerating the signed manual-verification build if needed;
- additive commit(s);
- normal push;
- verifying local HEAD equals origin.

Do **not** wire automatic sending into `messages_send` or `messages_send_attachment`.

The next gate is supervising review of the correction SHA followed by the user's manual Settings acceptance checklist.

The user should only need to say **“done”**; do not require copy/paste of the result.

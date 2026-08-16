# Current Claude Code Task

**Status:** active correction

**Recommended session:** continue the current Claude Code session if it still has the automatic-send Settings work in context; otherwise use a fresh session  
**Recommended model:** Sonnet  
**Effort:** high

This file is the canonical supervising prompt for the next bounded coding task.

Before doing anything else, run a normal fast-forward pull of `origin/feat/messages-write-foundation`, then read this entire file and execute it as the task specification. Do not rely on prior Claude conversation context unless you are continuing the immediately preceding implementation session.

---

You are correcting the global automatic-send Settings slice in the iMCP macOS project after its human manual UX checkpoint failed.

## Repository and exact review state

Repository:
- `jeffreystutz/iMCP`
- branch: `feat/messages-write-foundation`

Latest previously accepted production implementation baseline before this milestone:
- `1822a44b3f40dbda7246ad2753978113aa235de3`

Current supervising code-reviewed milestone head before this correction:
- `7329f5ecfd252ef41a4e3ebfc0482ff9e2567b4f`

That head contains the Settings-only automatic-send policy implementation plus additive documentation corrections. It is code-reviewed but **not manually accepted** because the human Settings checkpoint rejected the UX as too complex.

The branch may be one prompt-only trajectory commit ahead of `7329f5e` when you start. That prompt commit changes only this file and is not production implementation.

Before editing:
1. `git pull --ff-only origin feat/messages-write-foundation`
2. verify repository and branch;
3. verify local HEAD equals origin;
4. inspect commits after `7329f5ecfd252ef41a4e3ebfc0482ff9e2567b4f` and confirm any intervening commit is prompt/report trajectory only;
5. verify the worktree is clean.

If unexpected production source/test changes exist after `7329f5e`, stop and report the exact state instead of continuing.

Do not amend, squash, rebase, or rewrite reviewed history. This correction must be additive.

## Why this correction exists

The first Settings implementation exposed:

- an existing `Send confirmation` presentation control;
- four separate automatic-send toggles for direct/group × text/attachment;
- `Allow Everything Automatically`;
- `Require Confirmation for Everything`.

The supervising code review passed, but the human manual checkpoint did not. The user stopped the test because the control surface itself felt too complex.

The user explicitly approved a simpler replacement model. This is a settled product decision, not an implementation suggestion.

## Settled simplified product model

There is one global **Sending mode** for all connected MCP clients:

1. **Ask before sending** — factory default.
2. **Send automatically** — explicit user opt-in.

This mode applies to every currently eligible **existing-conversation programmatic send**. Do not expose different automatic-send authorization for:

- direct vs. group conversations;
- text vs. attachments.

Those four authorization categories are rejected product design, not advanced settings to preserve.

Verified-new-recipient sends remain separate: they use the current human-completed `NSSharingService` Messages compose flow. Selecting `Send automatically` must not make that route unattended.

### Confirmation method

The existing confirmation-presentation setting is still useful only while confirmation is required.

When **Ask before sending** is selected, show a subordinate **Confirmation method** control using the existing `MessagesSendConfirmationMode` capability.

User-facing choices should be:

- **Best available** — rename the existing presentation choice currently displayed as **Automatic**;
- **MCP form**;
- **iMCP app**.

Preserve the existing stored/raw semantic value for the presentation mode where practical; this is primarily a user-facing label clarification, not a reason to break stored compatibility.

When **Send automatically** is selected, the Confirmation method control is irrelevant. Prefer hiding it. Disabling it is acceptable only if hiding creates materially worse/native-inconsistent layout behavior. Do not present it as an equally important peer control while automatic mode is active.

### Warning

Transition from **Ask before sending** to **Send automatically** must show one clear native warning before committing the setting.

The warning should communicate that all connected MCP clients may submit eligible existing-conversation Messages sends without asking each time.

Cancel leaves the mode at Ask before sending.

Switching from Send automatically back to Ask before sending requires no warning.

Do not add per-category warnings or an onboarding wizard.

## Goal of this correction

Replace the rejected granular policy model and Settings UX with the settled binary Sending mode.

This task includes:

1. persisted global Sending mode model;
2. simplified Settings UI;
3. safe handling of the development-only persisted granular policy from the rejected intermediate implementation;
4. focused tests;
5. updates to task-owned docs/ADR/report so they describe the simplified product contract accurately.

**Do not wire the Sending mode into any send execution path yet.**

At the end of this task, every programmatic existing-chat text or attachment send must still require the same confirmation it requires at `7329f5e`, regardless of the selected new mode. The next milestone will wire execution only after this simpler Settings UX passes human acceptance.

## Data model requirements

Replace or simplify `MessagesAutomaticSendPolicy` / `MessagesAutomaticSendCategory` so the persisted product model directly represents the binary global state rather than retaining obsolete direct/group/text/attachment granularity.

Use repository-native naming. A small enum/value type such as a send authorization/sending mode is appropriate; choose names consistent with existing code.

Requirements:

- factory/default mode: Ask before sending;
- persistent across relaunch;
- malformed, missing, unknown, or stale values fail safely to Ask before sending;
- no MCP tool argument, prompt, elicitation response, or caller-controlled field can change the mode;
- Settings/app-owned code is the only mutation path;
- no per-client state;
- no operation-class state;
- no new-recipient automatic state.

### Development-only migration from the rejected four-category model

The prior granular model was never manually accepted or shipped as an accepted product state. Do not over-engineer compatibility for it.

Safety requirement: an old granular persisted value must **never accidentally enable Send automatically** merely because one or more old categories were enabled during manual testing.

The simplest acceptable behavior is to ignore/retire the old granular storage and default the new binary mode to Ask before sending unless the new mode has been explicitly set through the new Settings UI.

If you choose a different migration, it must be equally fail-safe and must not infer broad automatic authorization from a partial old category set.

Add a test covering this transition behavior.

## Settings UX requirements

Replace the current `Message Sending` + `Automatic Sending` conceptual split with one coherent sending section rather than two competing authorization sections.

The exact native control can be a Picker, radio-style choice, or another repository-consistent two-state control. Optimize for clarity and compactness.

The Settings surface should communicate, in concise native copy:

- Ask before sending is the safe default;
- Send automatically applies globally to all connected MCP clients for eligible existing-conversation sends;
- new recipients still open Messages for human review/send;
- destination resolution and other safety checks are unchanged by the mode.

When Ask before sending is selected, expose the Confirmation method choice beneath it. Rename user-facing `Automatic` confirmation presentation to `Best available`.

Remove the rejected UI:

- four automatic-send category toggles;
- `Allow Everything Automatically`;
- `Require Confirmation for Everything`;
- category-specific explanatory copy.

Do not add attachment-specific automation controls.
Do not add direct/group controls.
Do not add per-client controls.
Do not add advanced disclosure for the removed granularity.

Keep Phone Number Region and Trusted Clients behavior/layout otherwise unchanged.

## Preserve the meaning of confirmation presentation

`MessagesSendConfirmationMode` still controls **how confirmation is presented when Ask before sending is active**.

Its behavior should remain:

- Best available: use MCP form when supported, otherwise native iMCP confirmation;
- MCP form: explicitly use MCP form behavior, with existing fail-closed semantics;
- iMCP app: explicitly use the native iMCP confirmation.

This correction must not change those runtime presentation semantics. Only the user-facing label `Automatic` → `Best available` and conditional Settings visibility are intended here.

## Send execution is explicitly out of scope

Do not modify confirmation gating or dispatch behavior in:

- `messages_send`;
- `messages_send_attachment`;
- `MessagesSender`;
- attachment dispatch;
- new-recipient composition.

No send service should consult the new Sending mode in this task.

If refactoring the policy type requires compile-time call-site changes, there should be no runtime send call sites yet; verify that assumption before editing. If repository reality contradicts it, stop and report rather than redesigning silently.

## Tests

Replace/update the prior granular policy tests with focused coverage for at least:

- factory/default Sending mode is Ask before sending;
- persistence round-trip for both modes;
- absent/corrupt/unknown stored value fails to Ask before sending;
- rejected old granular persisted state cannot accidentally enable Send automatically;
- confirmation presentation setting remains independent and preserves its existing stored semantics;
- user-facing confirmation presentation title for the former Automatic mode is now Best available;
- no send behavior has changed from the reviewed pre-correction head.

Use existing repository test seams. Do not invent GUI automation.

## Documentation

Update task-owned repository documentation so it no longer describes four global authorization categories as the intended product.

At minimum inspect/update:

- `docs/decisions/0010-global-automatic-send-authorization-policy.md`;
- `docs/messages-write-plan.md`;
- `docs/project-reports/global-send-authorization-settings-2026-08-16.md`.

Required product record:

- global rather than per-client was chosen for product simplicity;
- the first four-category UX failed the manual Settings checkpoint;
- the user explicitly chose one binary global Sending mode instead;
- direct/group and text/attachment authorization granularity is removed;
- confirmation presentation becomes subordinate to Ask before sending;
- Automatic presentation is labeled Best available;
- new-recipient composition remains human-completed;
- send execution still ignores the new mode in this correction.

Keep ADR 0010 at `Proposed` until this simplified Settings UX passes the next human checkpoint.

Do not rewrite old Git history or old commit messages.

Update the existing implementation report rather than creating another report unless repository conventions genuinely require a new one.

## Privacy and safety

- Do not send any real message.
- Do not access or print private Messages or Contacts contents.
- Do not log recipient handles, bodies, chat IDs, attachment paths/names/contents, or private data.
- Do not weaken App Sandbox or entitlements.
- Do not add Accessibility or private-framework behavior.

## Verification

Run the strongest applicable existing verification because this correction changes persisted model and SwiftUI behavior:

- `swift format lint --strict --recursive App AppTests`;
- `git diff --check`;
- focused tests for the simplified model;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- CLI/proxy build if shared compilation requires it;
- do not spend time debugging the previously identified unrelated `CLITests/test_elicitation_proxy.py` `DYLD_FRAMEWORK_PATH` fragility unless this task changes that path or the failure materially changes;
- regenerate the signed `.build/ManualVerification` app using the established process;
- `codesign --verify --strict` the manual build and confirm entitlements are not weakened.

Do not perform the human Settings checkpoint yourself.

## Manual checkpoint to prepare

The regenerated signed app should let the user verify only the simplified UX:

1. Settings shows one clear Sending mode choice.
2. Ask before sending is the default.
3. Under Ask before sending, Confirmation method is visible with Best available / MCP form / iMCP app.
4. Choosing Send automatically presents one warning; Cancel does not change the mode; accepting changes it.
5. Under Send automatically, Confirmation method is hidden or clearly inactive.
6. The mode persists across Settings reopen and app relaunch.
7. Switching back to Ask before sending requires no warning and restores the Confirmation method control.
8. New-recipient copy remains clear that Messages UI is human-completed.
9. Phone Number Region and Trusted Clients remain normal.

No message is sent during this checkpoint.

## Git discipline and tracked handoff

Use additive commits only. Do not amend/rebase/squash reviewed history.

Suggested implementation commit message:
- `fix: simplify global Messages sending mode settings`

Update the existing tracked report with this manual-UX-driven redesign and new verification evidence. No raw session logs.

Push normally to:
- `origin/feat/messages-write-foundation`

Verify local HEAD equals origin.

Do not open/merge a PR.
Do not force-push.

## Stopping point

STOP after:

- replacing the granular policy with the binary persisted Sending mode;
- simplifying Settings as specified;
- updating tests and task-owned docs/report;
- full applicable automated verification;
- regenerating/verifying the signed ManualVerification build;
- additive commit(s);
- normal push;
- verifying local HEAD equals origin.

Do **not** wire automatic sending into runtime send execution.

The next gate is supervising review of the exact pushed head followed by the user's simplified Settings manual checkpoint.

The user should only need to say **“done”**; do not require copy/paste of the result.

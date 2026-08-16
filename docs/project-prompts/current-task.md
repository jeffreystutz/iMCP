# Current Claude Code Task

**Status:** active

**Recommended session:** fresh Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high

This file is the canonical supervising prompt for the next bounded coding task.

Before doing anything else, run a normal fast-forward pull of `origin/feat/messages-write-foundation`, then read this entire file and execute it as the task specification. Do not rely on prior Claude conversation context.

---

You are implementing the first bounded slice of global automatic-send authorization for the iMCP macOS project.

## Repository and Git preflight

Repository:
- `jeffreystutz/iMCP`
- branch: `feat/messages-write-foundation`

Latest fully accepted **production implementation** baseline:
- `1822a44b3f40dbda7246ad2753978113aa235de3`

The active branch is expected to be ahead of that SHA by one or more **prompt/report-only tracked commits**. Those trajectory commits do not change production implementation and are intentionally excluded from the accepted implementation baseline.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`
2. verify the repository and branch;
3. verify local HEAD equals `origin/feat/messages-write-foundation`;
4. inspect commits after `1822a44b3f40dbda7246ad2753978113aa235de3` and confirm any pre-task commits are prompt/report-only rather than production changes;
5. verify the worktree is clean.

If production source/tests have unexpectedly changed beyond the accepted implementation baseline before you begin, stop and report the exact state rather than building on an unreviewed implementation.

This is an **IMPLEMENTATION task**.

## Current product behavior

iMCP currently supports:

- existing direct/group Messages conversation resolution;
- text sends to exact existing chats through the public Messages AppleScript interface;
- verified-new direct-recipient composition through `NSSharingService`;
- existing-chat attachment sending through a native file picker;
- mandatory final confirmation for programmatic existing-chat text and attachment sends;
- destination/file revalidation after confirmation;
- one semantic dispatch, no retry/fallback;
- privacy-preserving logs/errors/results;
- confirmation presentation settings already exposed in Settings.

Existing confirmation-required sending is fully supervising-accepted through production SHA:
`1822a44b3f40dbda7246ad2753978113aa235de3`

Do not regress it.

## Settled product decision

There is **one global Messages send-authorization policy for the application**.

It applies equally to all connected MCP clients.

Do **not** implement:

- per-client automatic-send permissions;
- `ClientPolicy` maps keyed by client name;
- profile tokens;
- pairing;
- Default settings for new clients;
- inheritance/reset behavior by client;
- client identity as part of send authorization.

`clientInfo.name` may continue to exist for current connection/trust/display behavior, but it is irrelevant to this new authorization policy.

Factory behavior remains safe: all automatic-send categories are OFF by default, so sends continue to require confirmation.

The product should eventually let a power user automate all supported send categories globally.

## Goal of this slice

Implement **only**:

1. persisted global Messages automatic-send policy; and
2. Settings UI for viewing/changing that policy.

**Do not wire the policy into any send path yet.**

At the end of this task, changing these new settings must have ZERO effect on whether messages or attachments require confirmation.

Existing sends must behave exactly as they do at the accepted production baseline.

This deliberate separation creates a manual Settings checkpoint before confirmation bypass is possible.

## Policy shape

Represent currently meaningful automatic-send categories along these dimensions:

- existing direct conversation + text;
- existing group conversation + text;
- existing direct conversation + attachment;
- existing group conversation + attachment.

Do not expose an automatic-new-recipient control yet.

Reason: the current new-recipient path is `NSSharingService` composition and remains human-completed. A separate investigation is still open for whether a safe unattended new-recipient mechanism exists.

Choose repository-native naming/types rather than mechanically copying the labels above.

Prefer one coherent value-type policy rather than a loose collection of unrelated `UserDefaults` booleans if that fits existing architecture cleanly.

Requirements:

- persistent across app relaunch;
- factory default: all categories confirmation-required;
- forward-compatible enough that a future new-recipient capability can be added without redesigning the entire Settings architecture;
- no caller/tool input can mutate this policy;
- Settings/app code owns all mutation.

## Settings UX

Add an upstream-consistent Settings section for Messages send authorization.

Do not broadly redesign Settings.

The UX must make these facts clear:

- default behavior is confirmation before sending;
- enabling automatic behavior applies to **all connected MCP clients**;
- an enabled category may submit eligible messages without per-send confirmation once execution wiring is added in a later task;
- changing these controls does not alter destination-resolution or other safety checks.

Expose the four currently supported categories in a compact, understandable form.

Also provide a clear convenience mechanism equivalent to:

**Allow everything automatically**

It should enable all currently supported automatic categories.

Provide an equally obvious way to return everything to confirmation-required behavior.

This may be:

- a complementary “Require confirmation for everything” action;
- an overall mode control;
- or another compact native Settings interaction.

Choose the smallest native UX consistent with the existing app.

Do not hide the granular controls merely because the convenience action exists.

If enabling the first automatic category warrants a warning/confirmation, implement a simple native warning consistent with the app’s existing Settings patterns.

The warning should communicate the consequence without being alarmist: connected MCP clients will be able to send eligible Messages operations without asking each time once automatic execution is wired in the next implementation slice.

Do not show a warning repeatedly for every individual checkbox if one transition-level warning is sufficient.

Do not introduce onboarding, a wizard, or a new window.

## Important existing settings

Preserve the existing confirmation-presentation controls.

The new authorization policy answers:

> Is confirmation required for this operation class?

Existing presentation settings answer:

> If confirmation is required, how is it presented?

Do not collapse those concepts or remove existing options.

## Architecture

Inspect existing Settings persistence and send-confirmation seams before choosing placement.

Prefer:

- a small app-owned policy model;
- testable policy logic separate from SwiftUI rendering;
- repository-native persistence patterns;
- dependency injection where existing tests already use it.

Do not prematurely modify Messages send execution merely to make the Settings model convenient.

No send service should consult the new policy in this task.

If clean architecture naturally introduces a policy-reading abstraction that will be used in the next slice, that is fine, but it must not alter current execution.

## Tests

Add focused automated coverage for at least:

- factory/default policy is confirmation-required for every supported category;
- policy persistence round-trip;
- individual category updates do not mutate unrelated categories;
- Allow Everything enables all currently supported automatic categories;
- reset/Require Confirmation enables confirmation for all categories;
- migration/absence of new persisted values safely resolves to confirmation-required;
- existing confirmation presentation settings remain independent;
- no send behavior has been changed by this slice.

Use the repository’s existing test seams and conventions.

Do not invent UI automation if the repo does not already support it.

## Manual verification checkpoint

This slice **must stop at a Settings manual-verification checkpoint**.

Build the appropriate signed/manual-verification app using the established repository procedure.

The supervising user should be able to verify:

1. Settings opens normally.
2. New Messages authorization controls are visible and understandable.
3. Initial state is confirmation-required for everything.
4. Enabling one automatic category persists after closing/reopening Settings and, if practical, app relaunch.
5. Allow Everything updates all supported categories.
6. Returning to confirmation-required resets them all.
7. Existing confirmation-presentation controls still work/display normally.
8. No message needs to be sent during this checkpoint.

Do **not** perform a real send to verify this slice.

## Exclusions

Do not implement:

- any confirmation bypass;
- changes to `messages_send` execution;
- changes to `messages_send_attachment` execution;
- automatic new-recipient sending;
- Shortcuts experiments;
- Accessibility automation;
- new attachment ingress;
- handoff-directory support;
- serialized attachments;
- circuit breakers;
- rate limits;
- idempotency;
- Recent Automation Activity;
- `trustedClients` hardening;
- client authentication;
- upstream PR decomposition;
- unrelated cleanup/refactoring.

Do not change public tool schemas in this slice unless strictly necessary for compilation, which is not expected.

## Privacy and safety

- Do not access or print private Messages or Contacts data.
- Do not send a real message.
- Do not log recipient handles, message bodies, chat IDs, file paths, file names, attachment contents, or private Settings values unnecessarily.
- Do not weaken App Sandbox or current entitlements.

## Verification

Run the strongest applicable existing verification, including:

- strict swift-format lint over the relevant project/test sources;
- `git diff --check`;
- focused new tests;
- full test suite if available under the established runner;
- Debug app build;
- CLI/proxy verification if affected by compilation/shared code;
- signed ManualVerification build using the established process.

If the known duplicate-bundle-ID GUI test-runner issue occurs because a ManualVerification app is running, identify it accurately rather than repeatedly retrying.

## Git discipline

Use additive commits.

Do not amend/rewrite previously reviewed history.

Commit the implementation and tests in the smallest coherent checkpoint structure.

Then create a concise tracked implementation report under the established project-report location, for example:

`docs/project-reports/global-send-authorization-settings-2026-08-16.md`

The report must be sanitized and self-contained. Include:

- accepted starting production implementation SHA;
- prompt/report-only SHA(s) that preceded implementation, if any;
- final implementation SHA;
- files/symbols changed;
- policy shape;
- Settings behavior;
- defaults;
- verification evidence;
- manual checkpoint instructions;
- any unresolved issue;
- explicit statement that send execution still ignores the policy and confirmation remains mandatory.

Do not commit raw `.codex-log/` content or transcripts.

The report may be part of the final implementation checkpoint commit or a separate additive report commit, whichever produces the clearest review state.

Push normally to:
`origin/feat/messages-write-foundation`

Verify local HEAD equals origin.

Do not open or merge a PR.
Do not force-push.

## Stopping point

STOP after:

- implementation;
- automated verification;
- signed/manual-verification build preparation;
- tracked report;
- normal push.

Do not wire automatic sending into Messages execution.

The supervising reviewer will inspect the exact pushed remote state first.

The user should only need to say **“done”**; do not require them to paste the report back into chat.

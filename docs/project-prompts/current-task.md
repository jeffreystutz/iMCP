# Current Claude Code Task

**Status:** ready for implementation

**Recommended session:** fresh Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high

Use a fresh session because the previous work was attachment-ingress-specific and this milestone is a compact SwiftUI/menu-bar UX change with a separate manual visual gate.

## Repository and exact accepted state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The exact fully accepted production head before this prompt-only trajectory commit is:

`7bafd275217b731faaf9e3b678edfc33bbf4a3af` — `test: align automatic attachment revalidation ordering`

That head is accepted through supervising code review, hosted CI, and the human attachment Settings/MCP Inspector checkpoint.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow the Hexa coding-agent bootstrap required by `AGENTS.md`;
3. verify repository, branch, clean worktree, remotes, recent history, and local/origin equality;
4. verify that every commit after `7bafd275217b731faaf9e3b678edfc33bbf4a3af` is prompt/report/governance-only and that there are no unexpected production changes;
5. inspect the exact current implementations of `App/App.swift`, `App/Views/ContentView.swift`, `App/Views/SettingsView.swift`, `App/Services/MessagesSendingMode.swift`, the menu icon asset sets, and existing sending-mode tests before choosing the smallest implementation.

If repository reality materially contradicts this prompt, STOP and report the contradiction rather than silently redesigning.

Do not amend, rebase, reset, squash, force-push, or rewrite reviewed history.

## Current relevant behavior

The accepted app already has one global, app-owned `MessagesSendingMode` persisted under `MessagesSendingMode.storageKey`:

- `Ask Before Sending` is the factory default;
- `Send Automatically` is explicit user opt-in;
- MCP callers cannot enable, override, or weaken it;
- automatic mode skips only final per-send confirmation for eligible **existing-conversation** text and attachment sends;
- verified-new direct text recipients still open human-completed Messages composition;
- verified-new attachment recipients remain unsupported.

`GeneralSettingsView` already owns the accepted Settings control and warning for switching into Send Automatically. Returning to Ask Before Sending needs no warning.

`App/App.swift` currently chooses the menu-bar icon only from server enablement:

- enabled -> `MenuIcon-On`;
- disabled -> `MenuIcon-Off`.

`MenuIcon-On` is a 16x16 template SVG using `currentColor`, so macOS controls its normal light/dark foreground treatment. `MenuIcon-Off` already has its own light/dark behavior and represents a disabled server.

`ContentView` is the existing menu-bar window. Its first row is `Enable MCP Server`, followed by service controls and the existing menu actions.

## Settled product decision

When automatic sending is operationally active, iMCP must make that state visible **before the user opens Settings** and make it one action to stop.

The accepted design is:

1. **Menu-bar icon indicator**
   - When the MCP server is enabled **and** global Sending mode is Send Automatically, keep the existing base iMCP glyph visually native/monochrome and add a **small amber/orange status dot or accent**.
   - Do **not** tint the entire glyph.
   - Do **not** change or paint the menu-bar item's background.
   - Ask Before Sending + server enabled must retain the current normal `MenuIcon-On` appearance.
   - Server disabled must retain the current `MenuIcon-Off` appearance and takes precedence over the automatic indicator. The persisted Sending mode is not changed merely because the server is disabled.

2. **In-menu operational status and Pause**
   - When the server is enabled and Sending mode is Send Automatically, show a compact status surface near the top of the existing menu-bar window, immediately understandable as **“Automatic sending is on”**.
   - Provide one prominent, single-action **Pause** / **Pause automatic sending** affordance in that surface.
   - Include concise secondary copy making the scope truthful: eligible **existing-conversation text and attachment** sends can submit without per-send confirmation; new-recipient text still opens Messages for human review/send.
   - Do not imply automatic new-recipient sending or delivery guarantees.
   - When the server is disabled, do not present automatic sending as currently active in the menu window. The setting remains persisted, so re-enabling the server restores the automatic indicator/status if the mode was not paused in Settings.

3. **Pause semantics**
   - Pause is **not** a second state machine.
   - One click simply writes the global Sending mode back to `Ask Before Sending` using the existing storage key/model.
   - No confirmation dialog is needed for Pause because it only makes behavior safer.
   - The icon/status surface must update reactively and disappear immediately.
   - Pause must not disable the MCP server, disconnect clients, alter confirmation-method preference, or change any destination/file/runtime semantics.

## Implementation guidance

Preserve the existing upstream UI architecture and make the smallest coherent change.

Use the same `MessagesSendingMode.storageKey` / `MessagesSendingMode.decode` source of truth everywhere. Do not introduce a separate “paused” boolean, duplicate persistent policy, timer, client-specific state, or new authorization layer.

For the menu-bar icon, preserve native light/dark/highlight behavior of the base glyph. Because `MenuIcon-On` is currently a template image, simply putting amber inside that same template asset would cause the whole asset to be template-tinted. Prefer a SwiftUI/custom `MenuBarExtra` label that overlays a small amber/orange dot/accent on the existing template image **if the public API supports that cleanly in this repository**. If that approach is not viable, a dedicated automatic-mode asset with light/dark-safe base-glyph treatment plus amber accent is acceptable. Keep the implementation public-API-only, minimal, and visually native.

Do not modify `MenuBarExtraAccess` dependency behavior merely to implement the icon. Do not use private APIs, Accessibility automation, status-item hacks, or background-window tricks.

The menu status row belongs in the existing `ContentView`; do not create a separate window or settings pane. Reuse the current visual language and spacing rather than inventing a new design system.

A small pure helper for state derivation is fine if it materially improves correctness/testability, but do not build a framework around this two-condition state.

## Invariants that must remain unchanged

- Preserve the original upstream connection approval and remembered/trusted-client behavior exactly; do not remove, refactor, or reinterpret `trustedClients`.
- Do not use `clientInfo.name` as a Messages-specific authorization boundary.
- Do not change the global Sending mode's runtime semantics for text or attachments.
- Do not change the existing Settings warning for entering Send Automatically except for a tiny wording consistency fix if objectively necessary for the new visible status language.
- Do not alter destination resolution, exact-existing-group behavior, destination/file revalidation, verified-new composition, attachment grant behavior, Automation/TCC ordering, AppleScript dispatch, one-dispatch/no-retry behavior, privacy/redaction, or submitted-not-delivered truthfulness.
- Do not add circuit-breaker behavior yet.
- Do not add Recent Send Activity yet.
- No real Messages sends and no private Messages/Contacts reads for verification.

## Automated verification

Add focused automated coverage for any new non-view logic you introduce. Prefer deterministic unit tests over fragile SwiftUI snapshot/UI automation.

At minimum:

1. extend `MessagesSendingModeTests` or another focused test only if new state-selection/pause logic exists outside direct SwiftUI bindings;
2. verify stale/corrupt stored values still fail closed to Ask Before Sending if shared decode behavior is touched;
3. verify Pause cannot produce a third persistent state if a helper is introduced;
4. `swift format lint --strict --recursive .`;
5. `git diff --check`;
6. Debug app build;
7. `imcp-serverTests` build-for-testing and one ordinary full-suite test attempt.

The current machine has repeatedly hit `IDELaunchErrorDomain` code 20 before local XCTest launch. Make one normal full-suite attempt. If the same LaunchServices failure recurs before tests execute, record that exact infrastructure limitation and continue with build-for-testing rather than spending time debugging the runner or inventing alternate GUI automation. Do not claim tests executed if they did not.

If ordinary focused/full XCTest execution works, report the actual counts/results.

Verify any new asset catalog entries compile cleanly. If production source/assets changed, produce the normal signed ManualVerification app artifact if the existing project workflow makes that available without unrelated changes, and verify signing/entitlements remain unchanged. Do not modify entitlements for this task.

## Manual visual/interaction checkpoint

This milestone is not manually accepted by automated tests or code inspection. Prepare this compact checkpoint for the user; do not claim it passed yourself unless you genuinely have an ordinary interactive environment and can observe it directly without automation workarounds.

1. With server enabled and Sending mode = Ask Before Sending, confirm the menu-bar icon looks exactly like the current normal enabled icon and no automatic-status row appears.
2. In Settings, switch to Send Automatically using the already-accepted warning flow.
3. Confirm the menu-bar icon keeps the normal base glyph and gains only a small amber/orange status dot/accent. Confirm there is no custom background treatment and the icon remains legible in the current macOS appearance; check both light/dark appearance if easy.
4. Open the iMCP menu and confirm a compact near-top surface clearly says `Automatic sending is on`, accurately scopes automatic sending to eligible existing-conversation text/attachment sends, and offers a one-action Pause.
5. Click Pause once. Confirm the global mode immediately becomes Ask Before Sending, the amber indicator disappears, the status surface disappears, and Settings reflects Ask Before Sending. No extra confirmation should appear.
6. Set Send Automatically again, then disable the MCP server. Confirm the existing disabled/off icon takes precedence and the menu does not claim automatic sending is currently active. Re-enable the server and confirm the amber indicator/status returns because the configured mode remained automatic.

No real message or attachment send is required for this checkpoint.

## Documentation/report handoff

Write a concise self-contained report to:

`docs/project-reports/automatic-send-visible-state-and-pause-2026-08-18.md`

Include:

- repository/branch;
- accepted starting implementation SHA `7bafd275217b731faaf9e3b678edfc33bbf4a3af`;
- ending production SHA(s);
- exact files/symbols/assets changed;
- icon rendering approach chosen and why it preserves native menu-bar behavior;
- Pause implementation and proof that it writes the existing global Ask mode rather than a second state;
- focused/full verification actually executed, distinguishing `build-for-testing` from executed tests;
- any local XCTest launch limitation;
- signing/entitlement verification if performed;
- unresolved manual visual/interaction gate;
- confirmation that connection auth/trusted-client behavior and Messages runtime semantics were untouched.

Do not include private Messages/Contacts content, raw logs, secrets, local private file paths, or chain-of-thought.

## Git handoff

Use additive commits only. A suitable implementation commit message is:

`feat: surface automatic sending state and pause`

A separate report-only commit is fine if useful. Stage only task-owned files.

Push normally to `origin/feat/messages-write-foundation`, verify local HEAD equals origin, and leave the worktree clean.

Do not open an upstream PR, merge anything, force-push, or rewrite history.

## Stopping point

STOP after the visible automatic-mode indicator, in-menu status/Pause action, focused verification, full applicable build/test attempt, and sanitized report are committed and pushed for supervising review.

Do **not** start the automatic-send circuit breaker, Recent Send Activity, final consistency sweep, or upstream PR decomposition.

When complete, the user should only need to say **done**.
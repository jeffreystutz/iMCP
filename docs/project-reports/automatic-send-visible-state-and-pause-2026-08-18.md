# Visible automatic-send state and one-action Pause

- Repository: `jeffreystutz/iMCP`.
- Branch: `feat/messages-write-foundation`.
- Accepted starting implementation SHA: `7bafd275217b731faaf9e3b678edfc33bbf4a3af`
  — `test: align automatic attachment revalidation ordering`. That head was
  accepted through supervising code review, hosted CI, and the human
  attachment Settings/MCP Inspector checkpoint.
- Intervening trajectory-only commit before this slice (no production
  change): `7e6c7d32a062e9a884e297cbcc9cd5be78f3c915` — "docs: publish
  automatic send status and pause task" (`docs/project-prompts/current-task.md`).
- Ending production SHA(s): identified by commit title, not embedded hash,
  per the established convention — see `git log --oneline` on this branch
  for the exact implementation and report commits pushed after this file.

## Preflight verification performed

Before editing, repository state was verified directly against Git and Hexa:

- Working tree was clean; local `HEAD` equaled `origin/feat/messages-write-foundation`
  (`7e6c7d32a062e9a884e297cbcc9cd5be78f3c915`).
- Every commit after the accepted SHA `7bafd275...` was confirmed to touch
  only `docs/project-prompts/current-task.md` — no unexpected production
  changes.
- Retrieved the required Hexa bootstrap and knowledge documents
  (`imessage-mcp/coding-agent-bootstrap`, `overview`, `current-status`,
  `working-method`, `architecture`, `automation-product-design`,
  `messages-write-architecture`, `implementation-supervision-working-style`,
  plus the four `global-instructions/engineering/*` documents) and confirmed
  `AGENTS.md` carries the required `Preflight contract: 1` marker and points
  to the `imessage-mcp` Hexa organization.
- Inspected the exact current implementations of `App/App.swift`,
  `App/Views/ContentView.swift`, `App/Views/SettingsView.swift`,
  `App/Services/MessagesSendingMode.swift`, the `MenuIcon-On`/`MenuIcon-Off`
  asset catalog entries, and `AppTests/MessagesSendingModeTests.swift` before
  implementing.

## Files/symbols/assets changed

- **New** `App/Services/MenuBarIconAppearance.swift` — a small, pure,
  side-effect-free enum (`serverDisabled` / `askBeforeSending` /
  `automaticSendingActive`) with a single `resolve(isServerEnabled:sendingMode:)`
  static function and an `isAutomaticSendingActive` accessor. It reads only
  the existing `isEnabled` app-storage flag and the existing
  `MessagesSendingMode`; it introduces no new persisted state, timer, or
  second state machine. Server-disabled always takes precedence over the
  persisted Sending mode, matching the settled product decision.
- **New** `App/Views/MenuBarIconView.swift` — the menu-bar status item label
  view. Renders the unchanged `MenuIcon-Off`/`MenuIcon-On` assets for the
  disabled/ask states, and for `automaticSendingActive` renders the same
  `MenuIcon-On` template image with a small (5×5pt) non-template
  `Color.orange` `Circle` overlaid at `.bottomTrailing`. Sets an
  `accessibilityLabel` in all three cases (mirroring/extending the
  accessibility title the previous string-based `MenuBarExtra` initializer
  provided automatically).
- **Modified** `App/App.swift` — replaced the string-image-name
  `MenuBarExtra("iMCP", image: ...)` initializer with the closure-based
  `MenuBarExtra(content:label:)` initializer so the label can be
  `MenuBarIconView(appearance:)`. Added an `@AppStorage` binding to
  `MessagesSendingMode.storageKey` (same key `GeneralSettingsView` already
  reads/writes) so the icon appearance recomputes reactively whenever either
  `isEnabled` or the Sending mode changes.
- **Modified** `App/Views/ContentView.swift` — added an `@AppStorage` binding
  to `MessagesSendingMode.storageKey`, a private `isAutomaticSendingActive`
  computed property (delegating to `MenuBarIconAppearance.resolve(...)`), a
  private `pauseAutomaticSending()` method, and a conditional status block
  placed immediately after the existing "Enable MCP Server" row (before the
  Services section): a small orange dot + "Automatic sending is on" title, a
  secondary line scoping automatic sending to eligible existing-conversation
  text/attachment sends (new recipients still open Messages), and a
  `Button("Pause Automatic Sending")` styled `.borderedProminent`/`.tint(.orange)`.
- **New (test)** `AppTests/MenuBarIconAppearanceTests.swift` — five focused
  unit tests: factory precedence of `serverDisabled` over either sending
  mode, `askBeforeSending` and `automaticSendingActive` resolve correctly
  when enabled, `isAutomaticSendingActive` is `true` for exactly one case,
  and disabling-then-re-enabling the server while the persisted mode remains
  `sendAutomatically` returns to `automaticSendingActive` rather than some
  new third/paused case.
- **Modified** `iMCP.xcodeproj/project.pbxproj` — registered the new test
  file. `AppTests` is a manually-enumerated `PBXGroup` (not a synchronized
  file-system group like `App/`), so a `PBXFileReference`, a `PBXBuildFile`,
  a group-membership entry, and a `imcp-serverTests` target Sources-phase
  entry were added by hand, following the exact existing pattern used for
  `MessagesSendingModeTests.swift`. Validated with `plutil -lint` after
  editing.
- No asset catalog entries were added or changed. `MenuIcon-On.imageset` and
  `MenuIcon-Off.imageset` are byte-for-byte unchanged.
- `App/Views/SettingsView.swift` was **not** modified — its existing Sending
  mode description was reviewed against the new in-menu copy and found
  already consistent; no wording fix was judged objectively necessary.

## Icon rendering approach chosen and why it preserves native menu-bar behavior

Chose the preferred approach named in the task: a custom SwiftUI
`MenuBarExtra(content:label:)` label that overlays a small amber accent on
the existing template image, rather than authoring a new dedicated asset.

- `.serverDisabled` and `.askBeforeSending` render `Image("MenuIcon-Off")` /
  `Image("MenuIcon-On")` exactly as the previous string-based initializer
  did — same assets, same `template-rendering-intent: template` metadata for
  `MenuIcon-On`, so macOS continues to own that glyph's normal light/dark and
  highlighted-state rendering. These two states are pixel-for-pixel
  unchanged from the accepted baseline.
- `.automaticSendingActive` composes the same unmodified `MenuIcon-On`
  template image with a small solid `Color.orange` `Circle` overlay. The
  base glyph is never tinted as a whole, and no background/highlight
  treatment is applied to the status item itself — only the small circle is
  added on top.
- This is public-API-only: `MenuBarExtra(content:label:)` and `Image`
  overlay/`.overlay(alignment:)` are standard SwiftUI, no `MenuBarExtraAccess`
  behavior was touched, and no private API, Accessibility automation, or
  status-item hack was used.
- Verified compiling/linking cleanly for a Debug build (see Verification
  below). The precise pixel behavior of the overlay under macOS's
  status-item highlight/selection state (e.g., while the menu is open) could
  not be confirmed without an interactive session, so this remains part of
  the unresolved manual visual checkpoint below, per
  `engineering/review-and-validation`'s manual/rendered boundary — code
  compiling is not accepted as rendered/manual acceptance.

## Pause implementation and proof it writes the existing global Ask mode

`ContentView.pauseAutomaticSending()` is exactly:

```swift
private func pauseAutomaticSending() {
    sendingModeRaw = MessagesSendingMode.askBeforeSending.rawValue
}
```

`sendingModeRaw` is an `@AppStorage(MessagesSendingMode.storageKey)` property
— the identical storage key `GeneralSettingsView.sendingMode` in
`SettingsView.swift` already reads and writes, and the identical key
`App.swift`'s new `sendingModeRaw` reads for the menu-bar icon. There is no
new storage key, no new persisted boolean, no timer, and no second state
machine: writing this one value is the entire Pause action, and because all
three call sites (`App.swift`, `ContentView.swift`, `GeneralSettingsView`)
observe the same `@AppStorage` key, the menu-bar icon, the in-menu status
surface, and Settings' Sending picker all update reactively and immediately
from the single write. `MenuBarIconAppearanceTests.testDisablingServerWhileAutomaticDoesNotProduceAThirdCase`
and the full existing `MessagesSendingModeTests` suite together demonstrate
that only the two documented modes (`askBeforeSending` / `sendAutomatically`)
are ever representable in storage; Pause cannot produce or read a third
value.

Pause does not touch `isEnabled` (the MCP server toggle), does not touch
`MessagesSendConfirmationMode` (confirmation-method preference), and does
not touch any destination, file, or send-runtime code path — it is scoped
entirely to `MessagesSendingMode.storageKey`.

## Verification actually executed

- `swift format lint --strict --recursive App AppTests` — clean (no
  findings) after one line-length fix in `ContentView.swift`.
- `swift format lint --strict --recursive .` (full repository, excluding
  `.build/`) — clean.
- `git diff --check` — clean, no whitespace errors.
- `plutil -lint iMCP.xcodeproj/project.pbxproj` — OK, after the manual
  `AppTests` registration edits.
- `xcodebuild -project iMCP.xcodeproj -scheme iMCP -configuration Debug build`
  — **BUILD SUCCEEDED**. Confirmed via full log inspection: zero `error:`
  occurrences, `iMCP.app` linked and registered with LaunchServices.
- `xcodebuild -project iMCP.xcodeproj -scheme iMCP -configuration Debug build-for-testing`
  — **TEST BUILD SUCCEEDED**. All existing `AppTests`/`CLITests` sources plus
  the new `MenuBarIconAppearanceTests.swift` compiled and linked into
  `imcp-serverTests.xctest` without error.
- `xcodebuild -project iMCP.xcodeproj -scheme imcp-serverTests -configuration Debug test`
  (one ordinary full-suite attempt, `iMCP` scheme itself has no test action
  configured — the actual test target/scheme is `imcp-serverTests`, hosted
  inside `iMCP.app`) — **did not execute**. Failed immediately at launch with
  `IDELaunchErrorDomain` code 20 ("Could not launch imcp-serverTests. ... The
  LaunchServices launcher has returned an error"), the exact local
  infrastructure limitation the task prompt anticipated. Per the task's
  explicit instruction, this was attempted once and not debugged further;
  build-for-testing success stands in place of executed-test evidence for
  this slice. **No test counts/results were produced** — this must not be
  read as tests passing or as full-suite regression coverage for this
  change.

## Signing/entitlement verification

No entitlements were modified for this task (none were touched). The Debug
build used the project's existing "Sign to Run Locally" ad-hoc identity for
`imcp-server`, unchanged from prior accepted builds; `iMCP.app` itself is
unsigned in this Debug configuration exactly as before. No
`ManualVerification` signed artifact workflow was invoked, since the task's
own verification list only requires it "if the existing project workflow
makes that available without unrelated changes," and doing so was not
necessary to establish code-completion for this slice.

## Unresolved manual visual/interaction gate

The following from the task's manual checkpoint were **not** performed by
this agent and remain for human acceptance in an ordinary interactive
session:

1. Ask Before Sending + enabled: confirm the icon is pixel-identical to the
   prior accepted appearance and no status row appears.
2. Switch to Send Automatically via the existing warning flow in Settings.
3. Confirm the icon keeps the native base glyph and gains only the small
   amber/orange dot, with no background treatment, legible in both light and
   dark appearance — including while the status item is highlighted/the menu
   is open, which is the one behavior this agent could not verify from code
   or a non-interactive build.
4. Open the menu and confirm the "Automatic sending is on" surface, its
   scope copy, and the Pause button appear near the top.
5. Click Pause once; confirm immediate, unprompted return to Ask Before
   Sending in the icon, the status surface, and Settings.
6. Re-enable automatic mode, then disable the MCP server; confirm the
   disabled icon takes precedence and the menu does not claim automatic
   sending is active; re-enable the server and confirm the amber
   indicator/status returns.

No real Messages send or attachment send was performed or is required for
this checkpoint.

## Confirmation of preserved invariants

- The original upstream MCP connection-approval flow and `trustedClients`
  remembered-client behavior in `App/Views/SettingsView.swift` /
  `ServerController` were not touched.
- `clientInfo.name` was not read, referenced, or used as any authorization
  boundary by this change.
- `MessagesSendingMode`'s runtime semantics, its `decode`/fail-closed
  behavior, and its storage key were not modified — only read from three
  call sites and written from the one new Pause action, which writes the
  same `.askBeforeSending` value the existing Settings "Cancel"/back-to-Ask
  path already writes.
- No destination resolution, exact-existing-group behavior,
  destination/file revalidation, verified-new composition, attachment grant
  behavior, Automation/TCC ordering, AppleScript dispatch, one-dispatch/
  no-retry behavior, privacy/redaction, or submitted-not-delivered
  truthfulness was touched.
- No circuit-breaker behavior and no Recent Send Activity surface were
  added, per the task's explicit exclusions.
- No real Messages data was read, logged, or committed; all test fixtures
  use only synthetic enum/boolean values.

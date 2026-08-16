# Global Messages automatic-send authorization policy — Settings-only slice

- Starting implementation SHA: `1822a44b3f40dbda7246ad2753978113aa235de3`
- Final implementation SHA (four-category model, later rejected): `d6dc2ad`
- Correction commit (Settings copy + rationale, no behavior change): "fix: align automatic-send Settings copy and decision rationale"
- Redesign implementation commit (binary Sending mode, replacing the four-category model): "checkpoint: simplify automatic sending settings"
- Redesign documentation commit (this update): "docs: describe binary Sending mode redesign in plan and report"
- Branch: `feat/messages-write-foundation`

A commit's own hash cannot be embedded accurately in that same commit's
content — amending to fill it in changes the hash again. Later revisions of
this report therefore identify each commit by title rather than by a hash
that would go stale the moment it was written; run
`git log --oneline -- docs/project-reports/global-send-authorization-settings-2026-08-16.md`
for the exact SHA of each revision.

Between the start of this task and its push, `origin/feat/messages-write-foundation`
advanced by one non-conflicting, docs-only commit
(`5636e6a`, "docs: publish current Claude task prompt", adding
`docs/project-prompts/current-task.md`, which does not touch any file this
slice changes). This work was rebased cleanly onto that commit before pushing;
no production file was affected by the rebase.

## Summary

Implements the first bounded slice of global automatic-send authorization: a
persisted, app-owned, global Messages automatic-send policy and its Settings UI.
This slice deliberately does **not** wire the policy into any send path.
Confirmation remains mandatory for every existing send, exactly as at the
starting SHA.

Per the settled product decision (see ADR 0010), the policy is global rather than
per-client. Per-client automation authorization was considered and explicitly
rejected by the user as unnecessary product complexity — the additional UX,
configuration, and (to be trustworthy) pairing or authentication work is not
worth it for this project. Separately, an investigation found the current MCP
connection stack exposes no OS-derived, unspoofable client identity, only a
caller-supplied `clientInfo.name` already used, unauthenticated, for the
existing `trustedClients` connection-approval feature. That finding did not
drive the global-policy decision, but it is a reason the project should not
describe `clientInfo.name` as an authenticated identity or build a per-client
authorization boundary on top of it later without first establishing real
client identity. No client-profile/pairing/token project is required or planned
for this policy, and the pre-existing `trustedClients` spoofing weakness may be
hardened separately if desired but is not a prerequisite for this feature.

## Supervising review corrections (this update)

A supervising review of `d6dc2ad`/`cab286f` found the implementation and tests
sound but identified two documentation/UX-copy issues, corrected additively in
this update without touching the reviewed commits:

1. **Contradictory Settings copy.** The existing "Message Sending" help text in
   `App/Views/SettingsView.swift` ended with "A confirmation is always
   required," which contradicts the adjacent Automatic Sending policy and would
   become false once send-path wiring is added. Revised to state that this text
   describes *how* confirmation is presented *when* confirmation is required,
   and that *whether* confirmation is required at all is controlled separately
   in the Automatic Sending section below.
2. **Product-decision rationale drift.** This report, the ADR, and the plan
   document previously implied the global (rather than per-client) policy was
   chosen *because* `clientInfo.name` is spoofable. That reversed the actual
   reasoning: the user chose the global policy for product simplicity, and
   explicitly rejected per-client controls as unneeded complexity; the
   spoofability finding is separate supporting context for why the project
   should not fake a per-client boundary on top of the existing declared-name
   signal, not the decisive reason for the product choice. Corrected in this
   report (above), in `docs/decisions/0010-global-automatic-send-authorization-policy.md`,
   and in `docs/messages-write-plan.md`.

ADR 0010 remains at status `Proposed` — this correction does not mark it
Accepted; that remains gated on the manual Settings acceptance checkpoint below.

## Manual Settings UX rejection and simplified redesign (this update)

The four-category implementation above (`d6dc2ad`, corrected in `7329f5e`) was
code-reviewed and passed automated verification, but **failed the human manual
Settings acceptance checkpoint**: the user found the four independent toggles
plus "Allow Everything Automatically"/"Require Confirmation for Everything"
more control surface than the product needs, and explicitly approved a
simpler binary replacement rather than iterating on that design's copy or
layout.

The replacement, committed as `968b703` ("checkpoint: simplify automatic
sending settings"), removes `MessagesAutomaticSendPolicy` /
`MessagesAutomaticSendCategory` entirely and replaces them with
`MessagesSendingMode` — a two-case enum, `askBeforeSending` (factory default)
and `sendAutomatically` — with no operation-class or per-client dimension. The
rest of this report is updated to describe that settled model. Everything
below the "Files and symbols changed" section describes the current
(redesigned) state, not the rejected four-category one; the sections above are
kept as a historical record of what was tried and why it changed.

ADR 0010 was revised in place (not superseded) to describe the binary model,
and remains at status `Proposed` pending the next manual Settings acceptance
checkpoint using the corrected UX.

## Files and symbols changed

### Original four-category slice (`d6dc2ad`/`7329f5e`) — superseded by the redesign below

New: `App/Services/MessagesAutomaticSendPolicy.swift`,
`AppTests/MessagesAutomaticSendPolicyTests.swift`,
`docs/decisions/0010-global-automatic-send-authorization-policy.md`.
Changed: `App/Views/SettingsView.swift`, `iMCP.xcodeproj/project.pbxproj`,
`docs/messages-write-plan.md`, `docs/decisions/README.md`.

### Redesign (`968b703`) — current state

Deleted: `App/Services/MessagesAutomaticSendPolicy.swift` (122 lines),
`AppTests/MessagesAutomaticSendPolicyTests.swift` (162 lines).

New: `App/Services/MessagesSendingMode.swift` — `MessagesSendingMode`
(`String, CaseIterable, Identifiable, Sendable`; cases `askBeforeSending`,
`sendAutomatically`; `storageKey`, `defaultValue`, `title`, `decode(_:)`,
`load(from:)`). `AppTests/MessagesSendingModeTests.swift` — 6 focused tests.

Changed:

- `App/Services/MessagesSendConfirmation.swift` — one string literal: the
  `automatic` case's `title` changed from `"Automatic"` to `"Best available"`.
  Its `rawValue` (`"automatic"`, the stored/raw semantic value) and every
  runtime presentation-selection code path are unchanged.
- `App/Views/SettingsView.swift` — `GeneralSettingsView` replaces the
  two-section split ("Message Sending" + "Automatic Sending") with one
  "Message Sending" section containing a single "Sending" `Picker`
  (`MessagesSendingMode`), a conditional "Confirmation method" `Picker`
  (`MessagesSendConfirmationMode`, shown only while Ask Before Sending is
  active), and one `.alert` for the Ask→Send-Automatically transition warning.
  The `requestSendingModeChange(_:)` helper replaces
  `requestAutomaticSendPolicyChange(_:)`. Phone Number Region and Trusted
  Clients sections are unmodified.
- `iMCP.xcodeproj/project.pbxproj` — swaps the manually-registered test-file
  entries (`AppTests` is not a file-system-synchronized group) from
  `MessagesAutomaticSendPolicyTests.swift` to `MessagesSendingModeTests.swift`.
- `docs/decisions/0010-global-automatic-send-authorization-policy.md` —
  revised in place (still `Proposed`) to describe the binary model; keeps the
  global-vs-per-client reasoning, adds the four-category-rejection history.
- `docs/messages-write-plan.md` — "Automatic-send authorization policy"
  section and status summary rewritten for the binary model (this update).
- This report (this update).

Explicitly unchanged throughout every revision of this slice:
`App/Services/MessagesSender.swift`, `App/Services/Messages.swift`,
`App/Services/MessagesAttachment.swift`, and every MCP tool schema.

## Sending mode shape

`MessagesSendingMode` (`String, CaseIterable, Identifiable, Sendable`):

- `askBeforeSending` (factory default)
- `sendAutomatically`

No operation-class dimension (no direct/group or text/attachment distinction)
and no automatic-new-recipient state — new-recipient sending stays
human-completed `NSSharingService` composition (ADR 0006) regardless of the
selected mode. Persisted as a raw string under its own `UserDefaults` key
(`me.mattt.iMCP.messagesSendingMode`), distinct from the earlier four-category
type's key (`me.mattt.iMCP.messagesAutomaticSendPolicy`). The earlier key is
simply never read by `MessagesSendingMode`, so any categories a developer
enabled while manually testing the rejected design cannot resolve into
`sendAutomatically` now — verified by
`testRejectedOldGranularPersistedStateCannotAccidentallyEnableSendAutomatically`.
An absent, empty, or unrecognized stored value resolves to `askBeforeSending`,
never guessed toward `sendAutomatically`.

## Settings behavior

`GeneralSettingsView`'s "Message Sending" section now contains:

- A "Sending" picker: **Ask Before Sending** (default) / **Send Automatically**.
- Explanatory text stating: Ask Before Sending is the safe default; Send
  Automatically applies to every connected MCP client; neither changes how a
  destination is resolved or verified; neither applies to a new recipient.
- While Ask Before Sending is active, a "Confirmation method" picker for
  `MessagesSendConfirmationMode`: **Best available** (renamed from
  "Automatic") / **MCP form** / **iMCP app**, with its own explanatory text.
  This control is hidden entirely (not shown disabled) while Send
  Automatically is active.
- Selecting Send Automatically from Ask Before Sending shows one native
  `.alert`, "Send Automatically?": "All connected MCP clients will be able to
  submit an eligible existing-conversation Messages send without asking each
  time. You can switch back to Ask Before Sending at any time." Canceling
  leaves the mode unchanged. Switching back to Ask Before Sending never warns.

## Defaults

Factory default: `MessagesSendingMode.defaultValue == .askBeforeSending`. An
absent, empty, corrupt, or unrecognized stored value — including a
plausible-looking but unrecognized string — all resolve to this same default.
An old four-category persisted value (under its separate, no-longer-read key)
cannot resolve to `sendAutomatically` under any content, verified explicitly.

## Verification evidence (original slice, `d6dc2ad`)

- `swift format lint --strict --recursive App AppTests` — clean (fixed two
  formatting violations with `swift format format --in-place`, then re-linted
  clean).
- `git diff --check` — clean.
- `xcodebuild -scheme imcp-serverTests -configuration Debug ... test` —
  **260/260 tests passed, 0 failures** (252 at the starting SHA + 8 new). A
  stale `ManualVerification` `iMCP.app` process from an earlier session (PID
  12431) was occupying the shared bundle identifier and blocking the test
  runner's launch — the known duplicate-bundle-ID issue; it was identified and
  terminated before retrying, not repeatedly retried against.
- `xcodebuild -scheme iMCP -configuration Debug ... build` — succeeded.
- `imcp-server` (CLI proxy) target build — succeeded (unaffected by this
  slice's changes, confirmed directly rather than assumed).
- `python3 CLITests/test_elicitation_proxy.py <built imcp-server>` — passed.
- Signed `.build/ManualVerification` build,
  `DEVELOPMENT_TEAM=4LC533SNYD` (derived from the installed "Apple Development:
  Jeffrey Stutz (J34W2Q43JN)" identity's `OU`) — succeeded.
  `codesign --verify --strict` valid. Entitlements unchanged from the starting
  SHA: `app-sandbox`, `automation.apple-events`,
  `files.bookmarks.app-scope`, `files.user-selected.read-write`,
  `temporary-exception.apple-events` (`com.apple.MobileSMS`),
  `temporary-exception.files.absolute-path.read-write`
  (`/Users/*/Library/Messages/`) all present and unweakened.
- `git status --porcelain=v1 -uall` clean immediately before committing (only
  the intended files staged).

## Correction verification evidence (Settings copy + rationale, no behavior change)

This correction changed one Swift string literal (`App/Views/SettingsView.swift`)
and prose in three documentation files. It did not add, remove, or change any
type, property, method, control-flow, or test.

- `swift format lint --strict --recursive App AppTests` — clean, no violations.
- `git diff --check` — clean.
- `git status --porcelain=v1 -uall` before staging showed exactly the four
  expected files changed: `App/Views/SettingsView.swift`,
  `docs/decisions/0010-global-automatic-send-authorization-policy.md`,
  `docs/messages-write-plan.md`, and this report.
- `xcodebuild -scheme iMCP -configuration Debug ... build` — succeeded.
- `xcodebuild -scheme imcp-serverTests -configuration Debug ... test` — re-ran
  the full suite despite the copy-only scope, for extra confidence:
  **260/260 tests passed, 0 failures**, identical to the original slice's
  result. No stale `ManualVerification` process was running this time.
- `python3 CLITests/test_elicitation_proxy.py <built imcp-server>` —
  **could not complete**, for a reason unrelated to this correction: the
  script computes `DYLD_FRAMEWORK_PATH` from the binary's path
  (`CLITests/test_elicitation_proxy.py`, four `os.path.dirname` calls) and, in
  this local `.build/DerivedData` state, that computed path
  (`.../DerivedData/PackageFrameworks`) does not match where the just-built
  `imcp-server`'s `PackageFrameworks` actually live
  (`.../DerivedData/Build/Products/Debug/PackageFrameworks`). Confirmed by
  direct inspection: launching the binary with the script's exact environment
  produces `dyld: Library not loaded: @rpath/Logging_..._PackageProduct...`,
  a link-resolution issue, not a behavior change from this correction — no
  code this correction touches is on that binary's link path, and this
  correction does not modify `CLI/`, entitlements, or build settings.
- Signed `.build/ManualVerification` build regenerated with the same
  `DEVELOPMENT_TEAM=4LC533SNYD` — succeeded. `codesign --verify --strict`
  valid. Entitlement key set identical to the original slice's signed build
  (`app-sandbox`, `automation.apple-events`, `files.bookmarks.app-scope`,
  `files.user-selected.read-write`, both Messages temporary-exception keys,
  and the unrelated pre-existing entitlements carried from the base project),
  none weakened.

## Redesign verification evidence (`968b703` + this documentation update)

This redesign deletes one Swift service file and its tests, changes one string
literal in `MessagesSendConfirmation.swift`, rewrites the Settings section in
`App/Views/SettingsView.swift`, adds a new service file and test file, updates
`project.pbxproj`'s manually-managed test registration, and rewrites the ADR
and plan doc. It changes no send-execution file.

- `swift format lint --strict --recursive App AppTests` — clean.
- `git diff --check` — clean.
- `xcodebuild -scheme iMCP -configuration Debug ... build` — succeeded.
- `imcp-server` (CLI proxy) target build — succeeded, unaffected.
- `xcodebuild -scheme imcp-serverTests -configuration Debug ... test` —
  **258/258 tests passed, 0 failures** (252 base + 6 new
  `MessagesSendingModeTests`, replacing the 8 removed
  `MessagesAutomaticSendPolicyTests`: 260 − 8 + 6 = 258, confirming the swap
  was exact). A stale `ManualVerification` process from an earlier session (PID
  21586) blocked the first attempt — identified and terminated, not blindly
  retried, matching the established procedure for this known issue class.
- `-only-testing:imcp-serverTests/MessagesSendingModeTests` — all 6 new tests
  individually confirmed passing.
- Signed `.build/ManualVerification` build regenerated with
  `DEVELOPMENT_TEAM=4LC533SNYD` — succeeded. `codesign --verify --strict`
  valid. Entitlement key set identical to every earlier signed build in this
  slice, none weakened.
- `python3 CLITests/test_elicitation_proxy.py <built imcp-server>` — not
  re-attempted this pass; the pre-existing `DYLD_FRAMEWORK_PATH` path-fragility
  issue documented in the correction pass above is unrelated to this
  redesign (no `CLI/` code touched) and was left as noted prior art rather than
  re-diagnosed.
- `git status --porcelain=v1 -uall` showed exactly the expected files before
  staging this documentation update.

## Manual verification checkpoint

Using the signed build at
`.build/ManualVerification/Build/Products/Debug/iMCP.app`:

1. Launch the app and open Settings — it opens normally.
2. In the "Message Sending" section, confirm one **Sending** choice is visible,
   defaulting to **Ask Before Sending**.
3. Confirm a **Confirmation method** choice (**Best available** / **MCP form**
   / **iMCP app**) is visible beneath it while Ask Before Sending is active.
4. Select **Send Automatically**. Confirm one warning appears ("Send
   Automatically?"). Confirm **Cancel** leaves the mode at Ask Before Sending.
   Confirm **Send Automatically** (the alert's action button) applies the
   change.
5. Confirm the Confirmation method control is now hidden.
6. Close and reopen Settings — Send Automatically persists. Quit and relaunch
   the app — it is still selected.
7. Switch back to **Ask Before Sending** — no warning appears, and the
   Confirmation method control reappears, still set to its previous value.
8. Confirm no four-category toggles, "Allow Everything Automatically," or
   "Require Confirmation for Everything" controls remain anywhere in Settings.
9. Confirm the Phone Number Region and Trusted Clients sections still display
   and behave normally, unaffected by any of the above.

No message needs to be sent during this checkpoint, and none was sent during
implementation or automated verification.

## Explicit statement

**Send execution still ignores this mode.** `messages_send` and
`messages_send_attachment` are byte-for-byte unchanged from the starting SHA
across every revision of this slice. Every send — direct, group, text, or
attachment — still requires the existing mandatory final confirmation
regardless of the selected Sending mode. Wiring this mode into the send paths
is separate, later work with its own manual checkpoint, gated on this
redesigned UX passing manual acceptance.

## Unresolved issues

- Consuming this mode from `messages_send`/`messages_send_attachment` is not
  yet implemented — intentionally out of scope for this slice.
- No automatic-new-recipient state exists; adding one depends on a still-open
  investigation into whether any safe unattended new-recipient mechanism exists
  (see `imessage-mcp/automation-product-design` in Hexa).
- The pre-existing `trustedClients` spoofing gap noted during the client-identity
  investigation (any local process can claim a previously-trusted
  `clientInfo.name`) is unrelated to this slice and was not touched here.
- `CLITests/test_elicitation_proxy.py`'s `DYLD_FRAMEWORK_PATH` computation
  (four `os.path.dirname` calls from the binary path) pointed at the wrong
  directory in local `.build/DerivedData` state during the correction pass, so
  the script could not complete against a freshly rebuilt `imcp-server`. Still
  unresolved; a pre-existing test-harness path-fragility issue, not a
  regression from any revision of this slice; worth a small fix separately.

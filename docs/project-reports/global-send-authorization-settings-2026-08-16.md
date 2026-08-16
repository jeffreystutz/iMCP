# Global Messages automatic-send authorization policy — Settings-only slice

- Starting implementation SHA: `1822a44b3f40dbda7246ad2753978113aa235de3`
- Final implementation SHA: `d6dc2ad` (`feat/messages-write-foundation`)
- Correction SHA (Settings copy + rationale, no behavior change): `5dd68a6`
- Branch: `feat/messages-write-foundation`

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

## Files and symbols changed

New:

- `App/Services/MessagesAutomaticSendPolicy.swift` — `MessagesAutomaticSendCategory`
  (four cases) and `MessagesAutomaticSendPolicy` (the persisted value type:
  `isAutomatic(_:)`, `setAutomatic(_:for:)`, `allowEverythingAutomatically()`,
  `requireConfirmationForEverything()`, `isAnyCategoryAutomatic`,
  `isEveryCategoryAutomatic`, `decode(_:)`, `load(from:)`, `encoded()`,
  `save(to:)`).
- `AppTests/MessagesAutomaticSendPolicyTests.swift` — 8 focused tests.
- `docs/decisions/0010-global-automatic-send-authorization-policy.md` — ADR
  (Proposed), full context/rationale/consequences.

Changed:

- `App/Views/SettingsView.swift` — `GeneralSettingsView` gains an "Automatic
  Sending" section (category toggles, "Allow Everything Automatically",
  "Require Confirmation for Everything"), the `automaticSendPolicy` computed
  property, `requestAutomaticSendPolicyChange(_:)` transition-warning helper,
  and a `.alert` for the one-time "off → on" warning. `SettingsView` itself is
  unchanged; the existing "Message Sending" (confirmation-presentation) and
  "Phone Number Region" sections and the Trusted Clients list are unmodified.
- `iMCP.xcodeproj/project.pbxproj` — registers the new test file (`AppTests` is
  a manually-managed `PBXGroup`, not a file-system-synchronized group, so the
  new file needed explicit `PBXFileReference`/`PBXBuildFile` entries and a
  `Sources` build-phase entry for `imcp-serverTests`).
- `docs/messages-write-plan.md` — new "Automatic-send authorization policy"
  section plus a status-summary sentence.
- `docs/decisions/README.md` — ADR 0010 index row.

Explicitly unchanged: `App/Services/MessagesSender.swift`,
`App/Services/Messages.swift`, `App/Services/MessagesAttachment.swift`,
`App/Services/MessagesSendConfirmation.swift`, and every MCP tool schema.

## Policy shape

`MessagesAutomaticSendCategory` (`String`, `CaseIterable`, `Codable`):

- `existingDirectConversationText`
- `existingGroupConversationText`
- `existingDirectConversationAttachment`
- `existingGroupConversationAttachment`

No automatic-new-recipient category exists yet — new-recipient sending stays
human-completed `NSSharingService` composition (ADR 0006) regardless of this
policy, so a category for it would be speculative.

`MessagesAutomaticSendPolicy` wraps `Set<MessagesAutomaticSendCategory>` — the
categories currently exempt from confirmation — JSON-encoded into one
`UserDefaults` entry, `me.mattt.iMCP.messagesAutomaticSendPolicy`, following the
same encode-a-`Codable`-value-into-`Data` pattern already used for
`trustedClients` in `ServerController`. A category absent from a stored value
(including every category on first launch, and any category unknown to a given
build) is confirmation-required — never guessed to be automatic.

## Settings behavior

`GeneralSettingsView` gains an "Automatic Sending" section, positioned after the
existing "Message Sending" (confirmation-presentation) section:

- Explanatory text stating: default is confirmation-required; enabling a
  category applies to every connected MCP client; it does not change how a
  destination is resolved or verified; it does not apply to a new recipient.
- One toggle per category.
- "Allow Everything Automatically" (disabled once every category is already
  automatic) and "Require Confirmation for Everything" (disabled while no
  category is automatic).
- Turning on the **first** automatic category — via an individual toggle or
  "Allow Everything Automatically," whichever control causes the "zero
  automatic → at least one automatic" transition — shows one native `.alert`:
  "Connected MCP clients will be able to send eligible Messages operations
  without asking each time. You can turn this off again at any time." Enabling
  further categories while at least one is already automatic does not repeat
  the warning. "Require Confirmation for Everything" never warns.

The existing `MessagesSendConfirmationMode` picker ("Send confirmation:
Automatic / MCP form / iMCP app") is unchanged and remains independent — it
answers "how is confirmation presented," this policy answers "is confirmation
required at all."

## Defaults

Factory default: every category confirmation-required
(`MessagesAutomaticSendPolicy.defaultValue == .confirmationRequiredForEverything`).
No stored value, an empty stored value, a corrupt stored value, or a stored value
containing an unrecognized category all resolve to this same default — the whole
decode fails safely rather than partially trusting a payload.

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

## Manual verification checkpoint

Using the signed build at
`.build/ManualVerification/Build/Products/Debug/iMCP.app`:

1. Launch the app and open Settings — it opens normally.
2. Confirm the new "Automatic Sending" section is visible in General settings,
   below "Message Sending," with clear explanatory text.
3. Confirm all four category toggles start **off** (confirmation-required) and
   "Require Confirmation for Everything" is disabled (nothing to reset).
4. Enable one category toggle. Confirm the "Allow Automatic Sending?" warning
   appears exactly once, with "Cancel" and "Allow Automatically" options.
   Confirm "Cancel" leaves the toggle off; confirm "Allow Automatically" turns
   it on.
5. Close and reopen Settings — the enabled category stays on. Quit and relaunch
   the app — it is still on.
6. Enable a second category — no warning repeats.
7. Click "Allow Everything Automatically" — all four categories turn on, no
   further warning (at least one was already automatic).
8. Click "Require Confirmation for Everything" — all four categories turn off,
   no warning.
9. Confirm the existing "Send confirmation" picker (Automatic / MCP form / iMCP
   app) and the Phone Number Region and Trusted Clients sections still display
   and behave normally, unaffected by any of the above.

No message needs to be sent during this checkpoint, and none was sent during
implementation or automated verification.

## Explicit statement

**Send execution still ignores this policy.** `messages_send` and
`messages_send_attachment` are byte-for-byte unchanged from the starting SHA.
Every send — direct, group, text, or attachment — still requires the existing
mandatory final confirmation regardless of any setting added in this slice.
Wiring this policy into the send paths is separate, later work with its own
manual checkpoint.

## Unresolved issues

- Consuming this policy from `messages_send`/`messages_send_attachment` is not
  yet implemented — intentionally out of scope for this slice.
- No automatic-new-recipient category exists; adding one depends on a still-open
  investigation into whether any safe unattended new-recipient mechanism exists
  (see `imessage-mcp/automation-product-design` in Hexa).
- The pre-existing `trustedClients` spoofing gap noted during the client-identity
  investigation (any local process can claim a previously-trusted
  `clientInfo.name`) is unrelated to this slice and was not touched here.
- `CLITests/test_elicitation_proxy.py`'s `DYLD_FRAMEWORK_PATH` computation
  (four `os.path.dirname` calls from the binary path) pointed at the wrong
  directory in this local `.build/DerivedData` state during the correction
  pass, so the script could not complete against the freshly rebuilt
  `imcp-server`. This is a pre-existing test-harness path-fragility issue, not
  a regression from this correction; worth a small fix separately, out of
  scope here.

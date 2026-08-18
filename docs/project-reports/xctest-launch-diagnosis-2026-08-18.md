# Local XCTest launch failure — root-cause diagnosis (no fix implemented)

- Repository: `jeffreystutz/iMCP`, branch `feat/messages-write-foundation`.
- Starting head for this task: `9d74d619863c70d3402463ee473ea9c6e61791cd` —
  `docs: publish XCTest launch root-cause task` (prompt-only; no production
  change).
- Accepted production baseline referenced by the task:
  `7bafd275217b731faaf9e3b678edfc33bbf4a3af`.
- Upstream control baseline: `mattt/iMCP` `main` at
  `b84f266a7649125a407feb3c303570f1798e04dc` (verified via `git fetch
  upstream` immediately before use — matched exactly).
- Local environment used: macOS 26.5.2 (25F84), Xcode 26.6 (17F113),
  `xcode-select` pointed at `/Applications/Xcode.app`.
- **Outcome: STOP.** Root cause is narrowed to a specific, reproducible
  LaunchServices/codesign registration failure that is unique to the fork's
  app-hosted `imcp-serverTests` conversion, but every safe, disposable,
  command-line-only signing experiment permitted by the task — including the
  most fully correct one available on this machine (real development-team
  identity, Hardened Runtime enabled) — still failed to launch the test
  host. The next untried lever is a **persistent** change to the Debug
  signing identity/configuration for the `iMCP` and `imcp-server` targets,
  which the task's stop conditions reserve for explicit user/architecture
  decision. No project, scheme, or build-setting file was modified. No
  production or test code was modified.

## Preflight verification performed

- Hexa `imessage-mcp/coding-agent-bootstrap` and its always-retrieve set
  (`overview`, `current-status`, `working-method`, `architecture`) plus
  `global-instructions` engineering docs were retrieved and followed.
- `AGENTS.md` contains the literal marker `Preflight contract: 1` and routes
  to the same Hexa organization — no drift detected.
- `git pull --ff-only origin feat/messages-write-foundation` fast-forwarded
  cleanly; local `HEAD` (`9d74d61...`) equals `origin/feat/messages-write-foundation`.
- Working tree was clean before and after this task; only the single
  prompt-only commit exists after the accepted baseline `0f2fa87e...`.
- `git fetch upstream` confirmed `upstream/main` is exactly
  `b84f266a7649125a407feb3c303570f1798e04dc`.

## Reproduction (step 1)

`xcodebuild -project iMCP.xcodeproj -scheme imcp-serverTests -configuration
Debug -destination 'platform=macOS' -derivedDataPath <fresh disposable path>
test` fails before any test case executes, on every attempt:

```
Domain: IDELaunchErrorDomain
Code: 20
Recovery Suggestion: The LaunchServices launcher has returned an error.
IDERunOperationFailingWorker = IDELaunchServicesLauncher
```

This matches the reported symptom exactly and reproduced identically across
every fresh disposable `DerivedData` path used below.

## Resolved host/signing facts (step 2)

- `imcp-serverTests` resolves `TEST_HOST =
  $(BUILT_PRODUCTS_DIR)/iMCP.app/Contents/MacOS/iMCP` and
  `BUNDLE_LOADER = $(TEST_HOST)`, confirming the fork's app-hosted
  conversion described in the task prompt.
- The `iMCP` app target's Debug configuration resolves
  `CODE_SIGNING_ALLOWED = NO`, `CODE_SIGNING_REQUIRED = NO`,
  `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = -`.
- In an unmodified build, Xcode never runs a `CodeSign` build step against
  `iMCP.app` itself (only against the embedded `imcp-server` CLI tool, the
  test bundle, and their frameworks individually). `codesign -dv` on the
  resulting `iMCP.app` shows `flags=0x20002(adhoc,linker-signed)`,
  `Info.plist=not bound`, `Sealed Resources=none`, and `codesign --verify`
  reports "code has no resources but signature indicates they must be
  present." This is a real, independent defect (the app wrapper is only
  linker-signed, never resealed after Resources/Frameworks/PlugIns are
  copied in) — but, as shown below, fixing it alone does not fix the launch
  failure.
- The built executable is a thin `arm64` Mach-O (no `x86_64` or `arm64e`
  slice), consistent with `ONLY_ACTIVE_ARCH = YES` on Debug.

## Upstream control (step 3)

A temporary detached worktree at `b84f266a76...` was created, built, and
tested with a fresh disposable `DerivedData` path on the same local Xcode
26.6. Upstream's untouched, standalone `imcp-serverTests` (no `TEST_HOST`,
no `BUNDLE_LOADER`, no app dependency) **executed successfully**:

```
Test Suite 'All tests' passed at 2026-08-18 11:55:50.594.
** TEST SUCCEEDED **
```

The worktree was removed afterward with `git worktree remove --force`; no
commits were made from it.

**This rules out a blanket local Xcode 26.6 / macOS 26.5.2 regression.**
Standalone XCTest launch works fine on this machine. The failure is
specific to the app-hosted launch path that only the fork's target
conversion exercises.

## Signing/host hypothesis experiments (step 4)

All experiments used command-line build-setting overrides only, against
fresh disposable `DerivedData` paths. No project file was modified at any
point.

1. **`CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES`** — build fails
   before signing completes: "Signing for 'iMCP' requires selecting either
   a development team or a provisioning profile." Confirms the target's
   `Manual` signing style has no configured identity to fall back to.

2. **+ `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`** (explicit ad hoc) —
   build succeeds. `iMCP.app` now receives a full `CodeSign` step and a
   properly resealed signature: `codesign --verify` reports "valid on disk"
   and "satisfies its Designated Requirement," `Sealed Resources version=2
   rules=13 files=24`. **The test launch still fails identically** — same
   `IDELaunchErrorDomain` Code 20.

3. **Stale-registration control** — a targeted, tightly-scoped `log show`
   query around the failure timestamp (`process == lsd`) surfaced:
   ```
   SecStaticCodeIterateArchitectures(<private> arm64e err=-67049
   SecStaticCodeIterateArchitectures(<private> x86_64 err=-67049
   Failed to register <private> trusted: NSOSStatusErrorDomain/-67062
   ```
   (`-67049` = `errSecCSReqInvalid`, `-67062` = `errSecCSUnsigned`.) The
   local LaunchServices database held 9 stale registrations for bundle
   identifier `co.dododo.iMCP` from prior local builds, one of them signed
   with a real Apple Development team identity from an earlier Xcode-GUI
   run. All 9 were unregistered with `lsregister -u <path>` (a narrow,
   reversible, per-path operation touching only this repository's own past
   build products; LaunchServices re-registers automatically on the next
   build; no other application's registration was touched). Re-running the
   default (unmodified) configuration against a brand-new disposable
   `DerivedData` path **reproduced the identical failure from a clean
   registration state**, ruling out stale/conflicting prior registration as
   the cause.

4. **+ `DEVELOPMENT_TEAM=4LC533SNYD CODE_SIGN_STYLE=Automatic`** (the
   user's own real, already-installed local development team, applied only
   as a disposable command-line override) — `iMCP.app` is now signed with a
   genuine `Apple Development: Jeffrey Stutz` identity, real
   `TeamIdentifier`, **Hardened Runtime enabled**
   (`flags=0x10000(runtime)`), and a non-empty designated requirement. The
   specific `errSecCSUnsigned` / "Failed to register ... trusted" failure
   from experiment 3 **no longer occurs**. However, the overall test launch
   **still fails with the same generic `IDELaunchErrorDomain` Code 20**, and
   the same `SecStaticCodeIterateArchitectures(arm64e/x86_64, err=-67049)`
   pattern still appears during registration. In this same build, the
   nested `imcp-server` CLI target — which has its own explicit,
   target-level `CODE_SIGN_IDENTITY = -` setting independent of the project
   default — remained ad-hoc-signed ("Sign to Run Locally") and Hardened
   Runtime disabled ("note: Disabling hardened runtime with ad-hoc
   codesigning," logged only for the `imcp-server` target in this run),
   producing a bundle with mixed signing identities even under the most
   correctly signed configuration reachable via disposable overrides.
   A follow-up targeted log query for `amfid`/`taskgated`/library-validation
   activity at the exact failure timestamp found only one AMFI denial, and
   it was unrelated: XCTest's `LogArchiveCollector` was denied a task-port
   lookup against an unrelated, already-running production `imcp-server`
   process elsewhere on the machine (crash-log collection permission, not
   part of this test launch).

No further signing permutations were attempted, per the task's instruction
not to loop on the same failing command or spend unbounded time on
speculative settings.

## Demonstrated root cause and remaining uncertainty

**Demonstrated:** the launch failure is specific to the app-hosted
`RegisterWithLaunchServices ... -trusted` + `IDELaunchServicesLauncher` path
that Xcode only exercises when a test target's `TEST_HOST` points at an
app bundle — a path the untouched upstream standalone target never enters.
It is not caused by: incomplete/unsealed app-bundle signing alone (fixed in
experiment 2, no change in outcome); stale LaunchServices registration
state (cleared in experiment 3, no change in outcome); or a missing
development team/Hardened Runtime on the app itself (experiment 4 removed
the specific `errSecCSUnsigned` failure mode but the launch still fails).

**Narrowest remaining uncertainty:** whether the residual failure in
experiment 4 is (a) caused by the mixed ad-hoc/team-signed identities
between `iMCP.app` and its embedded `imcp-server` executable — which would
require a **persistent** Debug signing-identity change to both targets to
test conclusively — or (b) an Xcode 26.6 / macOS 26.5.2 LaunchServices
behavior change in the app-hosted test-launch path itself, independent of
signing identity, that has no safe repository-side correction. Both
candidate explanations land on an explicit stop condition from the task
prompt: a proven fix would either require changing the ordinary Debug app's
signing identity in a way that may affect persistent TCC/permission state,
or would point to an environment regression with no clearly safe
repository-side correction. Distinguishing between them requires a
persistent (not disposable) signing-configuration change, which this task's
authority does not cover.

## What was not changed

- No `.pbxproj`, scheme, entitlements, or CI file was modified.
- No product, tool-schema, sending-mode, or Messages behavior was touched.
- No sandbox, Hardened Runtime, or entitlement value was weakened anywhere
  in the repository (all Hardened Runtime/entitlement changes observed
  above were disposable command-line overrides for diagnosis only, never
  written to disk in the project).
- No real Messages data, recipient, or message content was read, logged, or
  committed.
- The only local machine-state change made was clearing 9 stale
  LaunchServices registrations for `co.dododo.iMCP` pointing at this
  repository's own prior local build products (via `lsregister -u`); this
  is reversible automatically on the next build and does not affect any
  other application.

## Verification performed

- Focused reproduction: `xcodebuild ... -scheme imcp-serverTests ...
  test` against fresh disposable `DerivedData`, multiple times, each with a
  distinct causal variable (default; ad hoc resealed; post-registration
  cleanup; real team + Hardened Runtime).
- Upstream control: same command against an unmodified `b84f266...`
  worktree — succeeded (3/3 tests passed).
- `git status`, `git diff --stat` confirmed a clean working tree throughout
  and after this task; no files were changed.
- Local `HEAD` verified equal to `origin/feat/messages-write-foundation`
  both before and after this investigation.
- No `swift format`, `plutil -lint`, or app-build verification was run
  against a modified project, because no project file was changed.

## Recommended next decision (for user/supervisor)

Three material options, none of which this task is authorized to choose
silently:

1. **Give the Debug `iMCP` and `imcp-server` targets a consistent,
   persistent real development-team signing identity** (matching what the
   Xcode GUI already does automatically today) and re-test. This is the
   only untried lever with any remaining chance of a small, upstream-hostile
   footprint, but it changes ordinary Debug signing/TCC behavior for every
   local build, not only test runs, and its outcome is not yet proven.
2. **Restructure the test targets**: restore `imcp-serverTests` to
   upstream's standalone, non-app-hosted semantics for CLI tests, and add a
   separate, dedicated app-hosted target (e.g. `iMCPTests`) for
   `@testable import iMCP` coverage. This avoids the app-hosted launch path
   entirely for the CLI suite and is the more upstream-credible long-term
   shape, but is an explicit architecture decision the task prompt reserves
   for the user.
3. **Accept local CLI-only `xcodebuild` testing as unreliable on this
   machine for now** and continue relying on hosted CI (which already
   passes) until option 1 or 2 is chosen, using Xcode's normal GUI Run/Test
   (which already works locally today, since it signs with the real team)
   as the interim local verification path for app-hosted tests.

No code was written for any of these; they are presented for the next
decision, per the task's explicit stop conditions.

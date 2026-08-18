# Local XCTest launch failure — root-cause diagnosis and demonstrated fix

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
- **Original outcome (this same day, earlier session): STOP.** Root cause was
  narrowed to a specific, reproducible LaunchServices/codesign registration
  failure unique to the fork's app-hosted `imcp-serverTests` conversion, but
  every disposable signing experiment tried — including real development-team
  identity with Hardened Runtime — still failed to launch the test host.
  **This conclusion has since been superseded** — see "Local-state isolation
  follow-up" below. The residual failure under real-team signing was not a
  signing-identity problem; it was the same running-copy collision documented
  below, which happened to be present throughout the earlier session's
  experiments (process state was not inventoried at the time).
- **Updated outcome (same day, follow-up session): root cause demonstrated
  and a safe, fully reversible local-state correction confirmed.** The
  unmodified project's `imcp-serverTests` now executes reliably (314/314
  tests, four separate fresh-`DerivedData` runs) whenever no other running
  copy of `co.dododo.iMCP` is active on the machine at launch time. No
  project, scheme, build-setting, signing, or entitlement file was modified
  at any point across either session. No production or test code was
  modified.

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
3. ~~Accept local CLI-only `xcodebuild` testing as unreliable on this
   machine for now ... using Xcode's normal GUI Run/Test (which already
   works locally today, since it signs with the real team) as the interim
   local verification path.~~ **Correction (same day, follow-up session):**
   this claim was false. The user independently reproduced the identical
   `IDELaunchErrorDomain` Code 20 failure through normal Xcode
   Product → Test (`param_testing_usingCLI = 0` in the error details), not
   only through `xcodebuild`. Real-team signing was never the differentiator
   between GUI and CLI, or between pass and fail generally — see "Local-state
   isolation follow-up" below for the actual cause and a demonstrated fix.

No code was written for any of these; they are presented for the next
decision, per the task's explicit stop conditions.

## Local-state isolation follow-up (same day, continued session)

### Hosted Xcode 26.6 control from the supervisor

Before this follow-up began, the supervisor ran an isolated hosted control:
a disposable branch (`ci/xctest-xcode-26-6-diagnostic`, based on exact
feature head `14b54e31dd319bd4c32ffac2c5035b3cc6ce634a`) changed only
`.github/workflows/ci.yml`'s Xcode version from `26.0` to `26.6`. GitHub
Actions run `32180188894`, job `95851129633` (`Build on macOS 26 with Xcode
26.6`, build 17F113 — matching the local Xcode build exactly) passed lint,
the normal Debug app build, the existing unmodified app-hosted
`imcp-serverTests` step, and the CLI elicitation-proxy test. The draft PR
(#5) was closed without merge; no repository file changed as a result. This
showed the repository's current app-hosted test configuration is not
generically incompatible with Xcode 26.6 and that persistent real-team
signing is not required merely for Xcode 26.6 to execute this suite on a
clean machine — redirecting the investigation toward local machine/user
state, per the current task prompt.

### Step 1 — process inventory and reproduction

Before any action, `ps aux` (filtered narrowly to `iMCP`/`imcp-server`
substrings only) showed two already-running iMCP-related processes: an
`imcp-server` process launched from this repository's own
`.build/experiments/messages-write/ProductionDevelopmentDerivedData/...`
build, and an `iMCP.app` process launched from this repository's own
`.build/ManualVerification/...` build — both pre-existing development
copies from earlier work in this repository, not unrelated software.

A fresh-`DerivedData` reproduction of the unmodified `imcp-serverTests`
scheme was then run. Unexpectedly, given the previous session's 100%
failure rate under superficially similar conditions, **it passed**: 314
tests executed, 0 failures. A second fresh-`DerivedData` run also passed
(314/314). After the first passing run, the two pre-existing processes
noted above were found to have exited on their own (most plausibly because
launching a new build under the same bundle identifier caused macOS to
treat it as replacing those long-running same-bundle-ID instances — they
had been running roughly 6–7 hours at that point). This by itself does not
prove a corrective mechanism; it motivated the controlled experiment below.

Current LaunchServices registrations for `co.dododo.iMCP` were inspected
narrowly (`lsregister -dump`, filtered to this bundle identifier only): 7
entries, all pointing at this repository's own past local build products
(disposable `/tmp` paths from this and the previous session, plus the
`.build/ManualVerification` path) — no unrelated application involved.

### Step 2 — running-copy collision control (the demonstrated root cause)

To test whether an *active* running copy — as opposed to mere LaunchServices
registration history — is the actual variable, one controlled A/B cycle was
run, exactly as the task authorized:

1. **A (collision present):** the repository's own already-installed
   `.build/ManualVerification/Build/Products/Debug/iMCP.app` copy was
   relaunched (`open -n`, a normal, safe, reversible launch of the user's own
   existing development build — no other application was touched). With it
   confirmed running, a fresh-`DerivedData` `imcp-serverTests` run was
   attempted: **it failed**, reproducing the exact original signature —
   `IDELaunchErrorDomain` Code 20, and, in a tightly time-scoped `log show`
   query against only `lsd`/`xcodebuild` for the ~18-second failure window,
   the identical underlying sequence from the earlier session:
   `SecStaticCodeIterateArchitectures(<private> arm64e/x86_64, err=-67049
   errSecCSReqInvalid)` followed by `Failed to register <private> trusted:
   NSOSStatusErrorDomain/-67062 errSecCSUnsigned`. The running collision
   process was unaffected by the failed attempt and remained running.
2. **B (collision removed):** the same running copy was quit through its own
   normal quit action (`osascript ... to quit`, targeting only bundle
   identifier `co.dododo.iMCP` — no other application). `ps` confirmed no
   iMCP-related process remained. A fresh-`DerivedData` `imcp-serverTests`
   run was then attempted: **it passed** (314/314). No processes were left
   running afterward.

This is a clean, fully reproducible A/B result, with the identical failure
signature from the earlier session reproduced on demand and cleared on
demand, using only a normal app launch and a normal app quit — no project,
signing, entitlement, or LaunchServices-database mutation of any kind was
needed in this follow-up.

**Demonstrated root cause:** a currently running copy of `co.dododo.iMCP`
(any development build, not the specific one under test) collides with
LaunchServices' `RegisterWithLaunchServices ... -trusted` step for a new
app-hosted `TEST_HOST` build under the same bundle identifier, causing the
static-code architecture-iteration/trust-registration failure and the
resulting `IDELaunchErrorDomain` Code 20. This also retroactively explains
the earlier session's results: process state was never inventoried during
that session, so a colliding running copy was very likely present
throughout, meaning **the earlier real-team-signing experiment's residual
failure was almost certainly this same collision, not a signing-identity
mismatch** between the `iMCP` and `imcp-server` targets as originally
hypothesized. That hypothesis is superseded.

### Verification standard met

- Unmodified feature-branch project (no change on either session).
- Actual test cases executed and passed: 314/314, three separate passing
  runs across three separate fresh `DerivedData` paths (before, and twice
  after, the collision was removed), one failing run reproducing the exact
  original signature while the collision was deliberately reintroduced.
- Reproducibility of the fix was shown by repeating from a distinct fresh
  `DerivedData` path after the corrective action (quitting the collision).
- Worktree remained clean throughout except for this report update.
- No project/signing/entitlement/CI change was made or persisted.

### Local machine state changed

- One already-installed, user-owned development copy of `iMCP.app` was
  launched and then quit through its own normal quit action, strictly as
  part of the authorized controlled A/B experiment. This is fully
  user-reversible (the user can relaunch iMCP normally at any time) and
  left no residual process or file-system change.
- No LaunchServices database mutation, TCC change, or other persistent
  local-state change was made or needed in this follow-up (unlike the
  previous session, which had unregistered 9 stale entries; that cleanup's
  effect could not be isolated from this session's collision-removal effect,
  since both point at the same class of state, but no further database
  mutation was necessary to reach the passing result documented here).

### Recommendation

For this development machine, and any other machine exhibiting the same
symptom: **quit any running copy of iMCP before running local
`imcp-serverTests`**, whether via `xcodebuild` or Xcode Product → Test. This
requires no repository change and is not specific to Xcode 26.6.

Whether an upstream-facing correction is worthwhile — for example, giving
the Debug test-host build a distinct bundle identifier from the one used by
an ordinary running/installed copy, so the two can coexist without
colliding — is a product/architecture choice left to the supervisor per the
task's instruction not to convert a demonstrated collision directly into a
project change. No such change was made in this task.

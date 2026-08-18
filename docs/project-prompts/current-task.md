# Current Claude Code Task

**Status:** root-cause investigation with bounded fix authority

**Recommended session:** fresh Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high

Use a fresh session because this task is a platform-sensitive Xcode/XCTest infrastructure investigation, not continuation of the SwiftUI feature work. Start with Sonnet/high effort; do not escalate models merely because the first hypothesis is false.

## Repository and exact current state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

Current remote branch head before this prompt-only trajectory commit:

`0f2fa87e5c2a07807858a5e51c9cc25404511d79` — report-only head for the visible automatic-send-state milestone.

The exact **fully human-accepted production baseline** remains:

`7bafd275217b731faaf9e3b678edfc33bbf4a3af` — accepted attachment ingress/test correction.

After that accepted baseline, the branch also contains the visible automatic-send implementation:

`59701440cd9d9b7b6945bc287c68464a4c026433` — `feat: surface automatic sending state and pause`

That implementation has passed supervising code review and hosted CI on exact report head `0f2fa87e...`, but its separate visual/manual interaction checkpoint has not yet been completed. The user explicitly chose to address the XCTest infrastructure blocker before returning to that manual gate. **Do not modify or redesign that product implementation in this task.**

Upstream baseline for comparison:

`mattt/iMCP` `main` at `b84f266a7649125a407feb3c303570f1798e04dc`.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow the Hexa coding-agent bootstrap required by `AGENTS.md`;
3. verify repository, branch, clean worktree, remotes, recent history, and local/origin equality;
4. verify this prompt-only commit is the only commit after `0f2fa87e5c2a07807858a5e51c9cc25404511d79`;
5. inspect the exact current Xcode project, shared schemes, test target settings, and CI workflow before running experiments;
6. confirm the local macOS and Xcode versions actually in use and record them in the report.

If repository reality materially contradicts this prompt, STOP and report the contradiction rather than silently redesigning.

Do not amend, rebase, reset, squash, force-push, or rewrite reviewed history.

## Problem to solve

The project’s tests build successfully, and the same test bundle executes successfully in hosted GitHub Actions using macOS 26 / Xcode 26.0. On the local development machine, however, both ordinary `xcodebuild ... test` and Xcode Product -> Test fail **before any test case executes** with a launch failure equivalent to:

- `Could not launch “imcp-serverTests”`
- `IDELaunchErrorDomain Code 20`
- underlying LaunchServices launcher failure.

This has reproduced across fresh DerivedData directories and through the normal Xcode GUI, so it is not merely a stale DerivedData or headless-Claude problem.

The goal is to make the project’s unit tests execute reliably in the ordinary local Xcode/xcodebuild development path **without weakening product security, signing, sandbox, entitlements, or runtime behavior merely to coerce the runner**.

A successful result should also be structurally reasonable for a future upstream contribution rather than relying on a fork-only test hack.

## Important repository facts already established

Verify these facts yourself before relying on them.

### Upstream test target

At upstream `b84f266...`, `imcp-serverTests` is a standalone macOS unit-test bundle whose only current source is `CLITests/ServiceGroupConfigurationTests.swift`.

Upstream test-target settings do **not** contain `TEST_HOST` or `BUNDLE_LOADER`, and the target has no dependency on `iMCP.app`.

The shared `imcp-serverTests.xcscheme` is the same scheme file in upstream and the current fork.

Upstream CI currently lints and builds but does not execute the test scheme.

### Fork test-target evolution

To add `AppTests` that use `@testable import iMCP`, this feature branch repurposed the existing `imcp-serverTests` target into an app-hosted test bundle. Relative to upstream it now:

- includes the `AppTests/*.swift` sources in the same target;
- depends on the `iMCP` app target;
- sets `BUNDLE_LOADER = "$(TEST_HOST)"`;
- sets `TEST_HOST = "$(BUILT_PRODUCTS_DIR)/iMCP.app/Contents/MacOS/iMCP"`.

The current app Debug configuration also contains the upstream-derived settings that disable ordinary code signing for the Debug app (`CODE_SIGNING_ALLOWED = NO`, `CODE_SIGNING_REQUIRED = NO`) while retaining sandbox/hardened-runtime/entitlement settings.

These facts make the app-host launch/signing boundary a strong **hypothesis**, not a proven diagnosis. Hosted Xcode 26.0 still launches and runs the same tests; local Xcode 26.6 has not.

There is also a potential upstream-architecture concern: an existing upstream standalone CLI-test target was changed into an app-hosted mixed CLI/app test target. Do not assume that is the final architecture simply because it exists today.

## Goal

Establish the root cause of the local XCTest launch failure with controlled evidence, then implement the **smallest proven infrastructure correction** only if it is clearly bounded and does not create a material product/development-security tradeoff.

The desired end state is:

- an ordinary local `xcodebuild ... test` actually executes the relevant XCTest suite on the current local Xcode rather than failing at LaunchServices;
- the app still builds normally;
- existing product/security behavior is unchanged;
- hosted CI remains compatible;
- the test structure has a credible path to upstream review.

## Investigation sequence

Follow this sequence rather than trying random Xcode settings.

### 1. Reproduce and capture the current failure once

From the exact current branch state, use a fresh disposable DerivedData directory and run the ordinary current test command, equivalent to:

```sh
xcodebuild \
  -project iMCP.xcodeproj \
  -scheme imcp-serverTests \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath <fresh-disposable-path> \
  test
```

Do not use `-quiet` for diagnosis. Record the meaningful error/domain/cause in the sanitized report. Do not loop on the same failing command.

### 2. Inspect the built test host and resolved build settings

For the failed build products, inspect at least:

- resolved `TEST_HOST` / `BUNDLE_LOADER` for `imcp-serverTests`;
- resolved app Debug code-signing settings, including command-line/sdk-specific precedence;
- `codesign -d` / `codesign --verify` results for the built `iMCP.app` and its executable as appropriate;
- architecture/file type if relevant;
- whether the built app can be launched normally by an ordinary public macOS mechanism (`open` or directly executing its binary) without introducing UI automation or private APIs.

Use privacy-safe, bounded diagnostics only. Do not dump unrelated system logs. If a targeted system log query is necessary to obtain the underlying LaunchServices cause, constrain it tightly to the test launch time/process and sanitize the report.

### 3. Establish the untouched upstream control

Create a **temporary detached worktree** (or equivalently isolated checkout) at exact upstream baseline `b84f266a7649125a407feb3c303570f1798e04dc`. Do not modify or commit from that control worktree.

Using the same local Xcode version and a fresh DerivedData directory, run upstream’s unchanged `imcp-serverTests` scheme.

Record whether its standalone test bundle actually executes. This is a key control:

- if upstream standalone tests run locally, the failure is specific to the fork’s app-host conversion or related build settings;
- if upstream standalone tests fail with the same LaunchServices error, the hypothesis is wrong and the issue is broader Xcode/environment behavior.

Remove the disposable control worktree when finished if safe to do so.

### 4. Test the signing/host hypothesis without persistent project mutation

If evidence still points to the app-host launch boundary, use **command-line build-setting overrides and fresh disposable DerivedData** to test whether making the Debug test host launchable through normal local/ad-hoc signing causes the same test scheme to execute.

First inspect `xcodebuild -showBuildSettings` so you understand actual precedence, especially the existing sdk-specific identity setting. Do not blindly guess at signing flags.

A valid experiment may override settings such as `CODE_SIGNING_ALLOWED`, `CODE_SIGNING_REQUIRED`, `CODE_SIGN_IDENTITY`, or related team/style values for that disposable invocation, but:

- do not modify project files for the experiment;
- do not alter Release signing;
- do not remove sandbox/hardened-runtime/entitlements merely to get a green result;
- do not grant Full Disk Access, change SIP, use private APIs, or use Accessibility automation;
- do not treat a build-only result as proof — the test cases must actually begin executing.

If the signing experiment makes tests execute, compare the resulting host signature/launchability with the failing host and record the causal evidence.

### 5. Use version comparison only if it materially narrows the cause

If both Xcode 26.0 and the current Xcode are already installed locally, a single matched comparison may be useful because hosted Xcode 26.0 succeeds while local Xcode 26.6 fails. Do not install/downgrade Xcode or spend substantial time on version archaeology for this task.

## Fix authority and stop conditions

You may implement and commit a fix **only after the root cause is demonstrated**.

A bounded fix is acceptable if it is limited to test/project/scheme/build configuration and all of the following are true:

- the causal experiment clearly predicts the fix;
- ordinary local XCTest execution succeeds afterward;
- normal Debug development behavior is not materially weakened;
- Release signing/entitlements are unchanged;
- app sandbox, Hardened Runtime, TCC/Automation behavior, and Messages runtime semantics are unchanged;
- the change is credible for upstream review rather than a machine-specific workaround.

Examples of potentially bounded outcomes include a correct test-host/build-configuration setting or another small scheme/project correction established by evidence.

**STOP and report evidence/options without implementing a broad redesign** if any of these are true:

- the only proven fix requires changing the ordinary Debug app’s signing identity in a way that may materially affect persistent TCC/permission behavior;
- the clean solution appears to require a new dedicated `iMCPTests` target, restoring `imcp-serverTests` to standalone semantics, or otherwise restructuring test targets;
- the clean solution appears to require extracting app/domain code into a library/framework/Swift package;
- evidence points to an Xcode 26.6 regression with no repository-side correction that is clearly safe;
- more than one materially different architecture is viable and the choice has meaningful upstream-maintenance tradeoffs;
- fixing launch would require weakening sandbox, entitlements, Hardened Runtime, privacy, or production security.

For a stop outcome, give the supervisor concrete options with exact project implications and a recommendation, but do not silently choose the larger architecture.

## Upstreamability requirement

Treat `mattt/iMCP` as the architectural baseline.

Do not delete or weaken the upstream CLI test coverage merely to accommodate app tests. Specifically, recognize that upstream’s `imcp-serverTests` target was originally standalone. If the evidence suggests separate CLI and app-test targets are cleaner, document that as an architecture option rather than performing the split under this bounded investigation unless it turns out to be a truly mechanical, consequence-free correction.

Do not edit upstream remotes or open an upstream PR.

## Product/security invariants

This task is test infrastructure only.

- No changes to Messages public tool schemas or behavior.
- No changes to global Sending mode semantics.
- No changes to connection approval / `trustedClients` behavior.
- No changes to destination resolution/revalidation, attachment grants, Automation/TCC ordering, AppleScript dispatch, privacy/redaction, or one-dispatch/no-retry behavior.
- No changes to app entitlements or sandbox permissions unless a contradiction proves the current project is malformed; if that occurs, STOP and report rather than changing them.
- No real Messages sends.
- No private Messages/Contacts reads.
- No test fixtures containing private user data.
- No Accessibility automation, private framework use, SIP changes, injection, or machine-specific launch hacks.

## Verification for an implemented bounded fix

If and only if you implement a proven correction, run:

1. the focused test(s) needed to prove the launch path works;
2. the ordinary full `imcp-serverTests` suite locally and report the actual executed test count/result;
3. `swift format lint --strict --recursive .`;
4. `git diff --check`;
5. `plutil -lint iMCP.xcodeproj/project.pbxproj` if the project file changed;
6. normal Debug `iMCP` app build;
7. `build-for-testing` as a secondary build check, not a substitute for executed tests;
8. inspect resolved signing/test-host settings after the fix and confirm Release configuration did not change.

Do not claim local XCTest success unless test cases actually executed.

Hosted CI will be re-run by the supervisor after the pushed review-ready result. Do not open a PR merely to trigger it.

If no safe bounded fix is implemented, still perform enough non-mutating verification to make the diagnosis/report useful, but do not manufacture a commit just to claim progress.

## Manual verification boundary

If a bounded fix is implemented and command-line XCTest executes locally, the supervisor may still ask the user to confirm normal Xcode Product -> Test behavior. Do not use GUI automation to simulate that checkpoint.

The separate visible automatic-send UI manual checkpoint remains pending and is **not part of this task**.

## Documentation/report handoff

Write a concise, sanitized, self-contained investigation report to:

`docs/project-reports/xctest-launch-diagnosis-2026-08-18.md`

Include:

- repository/branch and exact starting branch head;
- local macOS/Xcode version used;
- upstream control SHA and outcome;
- current target/scheme/test-host differences from upstream;
- initial failure evidence;
- resolved test-host/signing facts;
- each bounded experiment and outcome;
- demonstrated root cause, or the narrowest remaining uncertainty if not proven;
- any implemented project/scheme change and why the evidence supports it;
- actual local XCTest execution count/result if achieved;
- normal build/static verification;
- explicit confirmation of unchanged Release/security/product behavior;
- if stopped, the smallest viable architecture options, tradeoffs, and recommended next decision;
- recommended next action.

Do not include raw full logs, local private filesystem paths, secrets, Messages/Contacts data, or chain-of-thought.

## Git handoff

Use additive commits only.

If a safe bounded fix is proven, commit it with an outcome-oriented message such as:

`fix: make app-hosted tests launch locally`

Then add the report in a separate report-only commit if useful.

If the investigation concludes that a material architecture decision is required, **do not make speculative production/project changes**. Commit only the sanitized report, with a message such as:

`docs: diagnose XCTest launch failure`

Push normally to `origin/feat/messages-write-foundation`, verify local HEAD equals origin, and leave the worktree clean.

Do not merge, force-push, rewrite history, or open an upstream PR.

## Stopping point

STOP when either:

1. a root cause is proven, the smallest safe bounded correction is implemented, local XCTest actually executes, verification/report are complete, and commits are pushed; **or**
2. evidence shows the correct solution requires a material test-architecture/development-signing choice, in which case push the diagnosis report only and stop for supervising/user decision.

Do not resume circuit-breaker, Recent Send Activity, visible-state manual acceptance, or any other product milestone in this task.

When complete, the user should only need to say **done**.
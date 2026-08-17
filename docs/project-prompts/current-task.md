# Current Claude Code Task

**Status:** bounded test-only correction after real CI execution

**Recommended session:** current or fresh Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high

This is one narrow correction task. Do not redesign the attachment feature.

## Repository and exact current state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The attachment implementation's corrected production commit is:

`730df575140257e56d0e5a6207ab236d3acb7098` — `fix: close attachment ingress resource lifetime gaps`

No production change follows that commit. The branch head immediately before this prompt-only commit is:

`d878366ddf095e46e694d316e26330393ad9e41f` — report-only verification record.

The supervisor has code-reviewed the production correction and found no remaining production blocker. Local/headless XCTest launch was unavailable because of `IDELaunchErrorDomain` code 20, so a disposable draft CI diagnostic PR was used. That CI environment successfully launched XCTest and executed `MessageAttachmentSendTests`.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow the Hexa coding-agent bootstrap required by `AGENTS.md`;
3. verify repository, branch, clean worktree, and local/origin equality;
4. verify this prompt-only commit is the only commit after `d878366ddf095e46e694d316e26330393ad9e41f`;
5. inspect the exact failing test and the attachment source-revalidation implementation before changing anything.

Do not amend, rebase, reset, squash, force-push, or rewrite reviewed history.

## CI evidence and root cause already established

Diagnostic CI on macOS 26 / Xcode 26.0 successfully launched XCTest and executed **83 `MessageAttachmentSendTests`**. **82 passed and exactly one failed**:

`MessageAttachmentSendTests.testAutomaticModeDirectAttachmentSkipsConfirmationButPreservesEveryOtherStep`

The failing exact-event assertion expected:

```text
["match", "automation-status", "source-resolve", "match", "automation-request", "addressability", "attachment-submit"]
```

Actual execution was:

```text
["match", "automation-status", "source-resolve", "match", "source-resolve", "automation-request", "addressability", "attachment-submit"]
```

This is a stale **test expectation**, not a production defect.

The production attachment pipeline intentionally performs two filesystem source resolutions:

1. initial allowed-folder resolution and validation before authorization;
2. post-authorization source revalidation after destination revalidation and before Automation/dispatch.

The second resolution is required because allowed-folder authority may be revoked between initial validation and dispatch. `ResolvedAttachmentSourceHandle.revalidate()` deliberately calls `attachmentFolderGrantResolver.resolveAccess(forRequestedPath:)` again and releases that short-lived access afterward. The failing test itself already asserts `folderGrantResolver.resolveCount == 2` with the message `the source is resolved once and revalidated once`; only its exact `log.events` array omitted the second `source-resolve`.

Do not remove, reorder, or weaken the production revalidation to satisfy the test.

## Goal

Correct the stale event-order expectation so it accurately asserts the intended security-preserving automatic-mode pipeline.

## Required change

In `AppTests/MessageAttachmentSendTests.swift`, update only the affected automatic-mode test expectation/comment as necessary so the exact expected sequence includes the intentional second `source-resolve` after the second destination `match` and before `automation-request`.

Expected sequence:

```text
[
    "match",
    "automation-status",
    "source-resolve",
    "match",
    "source-resolve",
    "automation-request",
    "addressability",
    "attachment-submit",
]
```

Keep the existing `resolveCount == 2` assertion.

## Scope and exclusions

- **No production-code changes.**
- Do not change source-resolution, security-scoped-bookmark, revalidation, Automation/TCC, destination, sending-mode, or dispatch behavior.
- Do not weaken or delete the assertion merely to make CI green.
- Do not alter the disposable diagnostic CI branch or its workflow.
- Do not change connection approval / `trustedClients` behavior.
- No real message or attachment sends and no private Messages/Contacts access.

If inspection contradicts the root-cause statement above, STOP and report the concrete contradiction rather than implementing a different fix.

## Verification

Because local XCTest launch has repeatedly failed at LaunchServices before execution, do not spend time repeatedly retrying the same broken local runner.

Do the verification available in the coding environment:

1. strict Swift format lint for the touched test file/repository as appropriate;
2. `git diff --check`;
3. build/test-target compile verification if normally available without the known launch failure;
4. if an ordinary XCTest invocation unexpectedly works, run the focused test and full suite, but do not loop on `IDELaunchErrorDomain` code 20.

The authoritative executed-test gate will be the existing draft PR #2 CI run triggered automatically when this feature-branch correction is pushed. Do not edit CI to trigger it.

## Report and Git handoff

Update `docs/project-reports/programmatic-attachment-ingress-2026-08-17.md` only as needed to record:

- diagnostic CI executed 83 `MessageAttachmentSendTests`, 82 passing / 1 stale assertion failure;
- the exact stale expectation corrected here;
- full-suite acceptance remains pending the post-push normal CI result.

Commit additively. A suitable implementation commit message is:

`test: align automatic attachment revalidation ordering`

If the report update is separate, keep it report-only.

Push normally to `origin/feat/messages-write-foundation`, verify local HEAD equals origin, and leave the worktree clean.

Do not open or merge an upstream PR.

## Stopping point

STOP after the test-only correction and truthful report update are committed and pushed, with no production changes and a clean worktree. Do not wait for or attempt to merge PR #2; the supervisor will inspect its CI result after the push.

When complete, the user should only need to say **done**.
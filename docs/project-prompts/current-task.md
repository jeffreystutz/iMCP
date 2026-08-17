# Current Claude Code Task

**Status:** verification-only acceptance gate

**Recommended session:** fresh Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high — no product design or implementation is expected, but actual XCTest execution is the remaining acceptance gate for a security-sensitive attachment/filesystem milestone.

This file is the canonical supervising prompt for one bounded verification task.

## Repository and exact current state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The exact fully accepted production baseline before the attachment-ingress milestone remains:

`326dbaebb97e72960c2c7fea1f381a26690f3e4b` — `fix: ignore blank optional Messages destination fields`

The attachment-ingress implementation was reviewed, corrected, and currently has this production correction commit:

`730df575140257e56d0e5a6207ab236d3acb7098` — `fix: close attachment ingress resource lifetime gaps`

The current branch head before this prompt-only trajectory commit is:

`0a20c99e372096e5d777309e5acc282e36aeb824` — report-only update documenting the correction and the remaining XCTest execution gap.

The supervisor has reviewed the correction diff at `730df575...` and found the three prior code-review blockers resolved:

- initial filesystem security-scope cleanup on first-validator failure;
- initial serialized-temp cleanup on first-validator failure, with corrected tests matching blank-field semantics;
- cross-instance atomicity for persisted Allowed Folder grant mutations.

**The attachment milestone is still NOT accepted because the new/rewritten XCTest cases have compiled but have not actually executed.** In two prior Claude sessions, `xcodebuild ... test` failed at launch time with `IDELaunchErrorDomain` code 20 / LaunchServices before XCTest ran. The last known actual suite execution remains 282/282 from the earlier, pre-attachment milestone.

Before doing anything:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow the Hexa coding-agent bootstrap required by `AGENTS.md`;
3. verify repository, branch, remotes, clean worktree, and local/origin equality;
4. verify the only commit after `0a20c99e372096e5d777309e5acc282e36aeb824` is this prompt-only trajectory commit;
5. inspect the existing milestone report `docs/project-reports/programmatic-attachment-ingress-2026-08-17.md` and the project test entry points.

If unexpected production source/test changes are present, stop and report the exact state rather than absorbing them.

Do not amend, rebase, reset, squash, force-push, or rewrite reviewed history.

## Goal

Get the attachment milestone's XCTest suite to **actually execute** in this fresh session and record the exact result.

This is a verification task, not an implementation task. Do not change production code or tests merely because a previous session had a LaunchServices test-runner problem.

## Required verification sequence

### 1. Focused attachment tests

Run the focused test classes covering the changed milestone behavior:

- `MessageAttachmentSendTests`
- `AllowedFolderGrantStoreTests`

Use the repository's normal `imcp-serverTests` scheme and macOS destination. Prefer a **fresh ignored DerivedData directory** for this session rather than reusing the directory from the sessions that hit LaunchServices code 20.

The important requirement is that XCTest actually launches and reports executed tests. `build-for-testing` alone is not sufficient.

### 2. Full test suite

If the focused classes execute successfully, run the complete `imcp-serverTests` suite and record the actual executed/pass/fail count.

### 3. Bounded runner handling

If the focused run again fails before XCTest execution with the same `IDELaunchErrorDomain` code 20 / LaunchServices failure:

- confirm the failure is launch infrastructure rather than a compile/test assertion failure;
- make at most **one** safe, non-product retry using a different fresh ignored DerivedData directory or another ordinary repository-supported invocation;
- do not modify signing, entitlements, sandboxing, tests, product code, schemes, or project configuration just to coerce the runner;
- do not add GUI/Accessibility/AppleScript workarounds or repeatedly troubleshoot LaunchServices.

If that bounded retry still fails before XCTest executes, stop with the exact evidence. Do not claim test success.

## If an actually executed test fails

An XCTest assertion/exception failure is different from the known LaunchServices infrastructure failure.

If tests execute and expose a real defect in the attachment milestone:

1. root-cause it;
2. fix only the smallest milestone-owned defect necessary;
3. preserve all settled product behavior and security invariants below;
4. rerun the focused tests and full suite;
5. run the applicable build/format/diff/proxy/signing verification for any production/test change;
6. commit additively and push for supervising review.

If the failure implies a product/architecture decision rather than a clear implementation defect, stop and report instead of redesigning.

## Settled behavior that must not be reopened

Do not change unless an actually executed test proves an implementation bug:

- public tools exactly `message_send_text` and `message_send_attachment`;
- attachment source forms exactly absolute allowed-folder `file_path` OR `filename` + `content_base64`;
- no per-send attachment picker;
- no staging-root concept, relative staging path, delete-after-send option, grant ID, or caller-controlled filesystem grant;
- blank optional scalar source fields omission-equivalent only for source-form selection;
- malformed typed/nonblank source values fail closed;
- serialized decoded-content limit 5 MiB provisional;
- filesystem attachment limit 25 MiB;
- Allowed Folders inline Settings UX;
- user-approved security-scoped bookmarks and path containment/revalidation;
- caller-owned filesystem files are never deleted or modified;
- serialized temp artifacts are app-owned and cleaned on all safe exit paths;
- destination resolution/revalidation, exact-existing-group semantics, and verified-new-recipient attachment refusal;
- Ask Before Sending / global Send Automatically behavior;
- Automation/TCC ordering, fixed AppleScript descriptors, one dispatch/no retry, privacy redaction, submitted-not-delivered truthfulness;
- original upstream connection approval / `trustedClients` behavior untouched.

No verification may send a real message or attachment or access private Messages/Contacts contents.

## Report and Git handoff

Update the existing report:

`docs/project-reports/programmatic-attachment-ingress-2026-08-17.md`

Record the exact fresh-session commands and outcome.

### If XCTest executes successfully and no code/test change is needed

Replace the unresolved XCTest-execution gap with the actual focused/full execution evidence and exact counts. Commit **report only** with a message such as:

`docs: record attachment ingress XCTest verification`

Push normally to `origin/feat/messages-write-foundation`, verify local HEAD equals origin, and leave the worktree clean.

### If the same LaunchServices failure persists

Keep the gap explicit and update the report only if this fresh-session attempt adds useful evidence. Push a report-only commit if you changed the report. Do not mutate production merely to create a new head.

### If an executed test required a real code/test fix

Commit the correction and report additively, push normally, and stop for supervising review. Do not claim acceptance.

Do not open or merge an upstream PR.

## Manual verification

Do **not** perform the attachment manual checkpoint in this task. Human Settings/MCP Inspector verification comes only after automated XCTest execution passes and the exact resulting head has supervising code review.

## Stopping point

STOP when exactly one of these is true:

1. Focused and full `imcp-serverTests` actually executed and passed, the report contains truthful exact evidence, any report-only update is pushed, and the worktree is clean; or
2. XCTest again cannot launch after the bounded fresh-environment retry, the exact infrastructure failure is truthfully recorded with no false pass claim, no product/test workaround was introduced, and any report-only update is pushed; or
3. XCTest actually executed and exposed a real milestone defect, the smallest justified correction was implemented and fully verified, committed/pushed additively, and is ready for supervising review.

When complete, the user should only need to say **done**.
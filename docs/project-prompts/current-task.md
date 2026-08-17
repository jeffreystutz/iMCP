# Current Claude Code Task

**Status:** supervising-review correction required

**Recommended session:** continue the current Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high — the fixes are small but security-sensitive: resource lifetime, persisted filesystem authority, and tests that currently did not execute.

This file is the canonical supervising prompt for one bounded correction to the programmatic attachment-ingress milestone.

## Repository and exact review state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The exact fully accepted production baseline remains:

`326dbaebb97e72960c2c7fea1f381a26690f3e4b` — `fix: ignore blank optional Messages destination fields`

The attachment-ingress implementation currently under review ends at:

`a16be7721bf1287f1f933adc74157afa895f448c` — `docs: publish programmatic attachment ingress ADR and report`

Its implementation chain after the prompt-only commit `9ee212588fa8f9a5456ac3ce17ac13bfb69986b3` is:

- `d16b5a5cf5b86eb2225eb43ec331a3cab97c7562` — source parsing and allowed-folder grant storage;
- `cf3795e542806acbcd8de5af05cdf80c8b357a1c` — pipeline and Settings wiring;
- `78bd1ef33095d5d74c37b5663a4268c7f7524e49` — tests;
- `a16be7721bf1287f1f933adc74157afa895f448c` — ADR/docs/report.

The supervisor reviewed exact remote head `a16be772...` and **did not accept it**. Three concrete issues must be corrected below. Do not rewrite any reviewed history.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve/follow the Hexa coding-agent bootstrap required by `AGENTS.md`;
3. verify branch/remotes/local-origin equality and clean worktree;
4. verify `a16be7721bf1287f1f933adc74157afa895f448c` is the latest production/report head and only this correction-prompt trajectory commit follows it;
5. inspect `MessageService.resolveAttachmentSourceHandle`, `UserDefaultsAllowedFolderGrantStore`, the attachment source parser, `MessageAttachmentSendTests`, `AllowedFolderGrantStoreTests`, and the current implementation report.

If unexpected production changes follow `a16be772...`, stop and report rather than absorbing them.

Do not amend, rebase, reset, squash, force-push, or otherwise rewrite the existing milestone commits.

## Accepted product behavior that is NOT being reopened

The milestone product shape remains settled:

- public send tools remain exactly `message_send_text` and `message_send_attachment`;
- attachment destination semantics remain the accepted `recipients` / `chat_id` model;
- `message_send_attachment` has exactly two source forms:
  - absolute `file_path` beneath a persistent user-approved folder;
  - `filename` + `content_base64` serialized bytes;
- no per-send attachment picker;
- no staging-root concept, relative staging path, delete-after-send behavior, grant ID, or caller-controlled filesystem grant;
- serialized decoded-content cap remains provisionally 5 MiB;
- filesystem attachment cap remains 25 MiB;
- inline Attachments Settings with Serialized attachments availability, Allowed Folders, direct Add Folder, Show in Finder, remove, and broken-grant Reauthorize remains the intended UX;
- existing destination resolution/revalidation, confirmation, global Sending mode, Automation/TCC ordering, fixed AppleScript descriptors, privacy, one-dispatch/no-retry, and submitted-not-delivered behavior remain unchanged;
- original upstream connection approval / `trustedClients` behavior remains untouched.

This task is review correction only, not a redesign.

## Review finding 1 — initial validation leaks acquired resources

At `a16be772...`, `MessageService.resolveAttachmentSourceHandle(_:)` acquires a resource before initial validation, but the cleanup closure is only installed in the returned handle **after** validation succeeds.

### Filesystem source

Current shape:

1. `resolveAccess(forRequestedPath:)` acquires/holds the allowed root's security-scoped access;
2. `attachmentValidator.validate(access.fileURL)` runs;
3. only if validation succeeds is a handle returned whose `release` calls `access.release()`.

If step 2 throws, the acquired security scope is never released.

### Serialized source

Current shape:

1. decode input;
2. create unique app-owned temp directory/file;
3. `attachmentValidator.validate(staged.fileURL)` runs;
4. only if validation succeeds is a handle returned whose `release` removes the temp directory.

If step 3 throws, the staged temp directory survives.

### Required correction

Make initial validation failure clean up the just-acquired resource before rethrowing, for both source forms, while preserving exactly-once cleanup after a successful handle is returned.

A straightforward `do/catch` around initial validation is acceptable:

- filesystem validation throw -> release the acquired access, then rethrow;
- serialized validation throw -> remove the app-owned temp directory, then rethrow.

Do not introduce double-release/double-delete on the successful path. Keep the existing outer `defer { sourceHandle.release() }` behavior for all exits after successful resolution.

Add the smallest useful test seam needed to prove the filesystem initial-validation release if the existing concrete `AllowedFolderFileAccess` makes that unobservable. Do not build a generic resource-lifetime framework.

## Review finding 2 — the serialized validation-failure cleanup test cannot test what it claims

Current test `testSerializedTempCleanupOccursOnValidationFailure` supplies:

- meaningful `filename: "empty.txt"`;
- blank `content_base64: ""`;
- expects `.emptyFile` and then asserts no staged temp directory remains.

That contradicts the milestone's settled source-selection semantics. Blank optional scalar source fields are omission-equivalent for source-form selection. Therefore meaningful `filename` + blank `content_base64` is an **incomplete serialized source**, and it fails before decoding/staging. It cannot exercise temp cleanup after validation.

This test would fail if XCTest execution were currently available.

### Required correction

1. Preserve the settled parser semantics: meaningful `filename` + blank/whitespace `content_base64` must fail as incomplete serialized input before staging. Do not change the parser merely to satisfy the existing test.
2. Add/retain an explicit parser test proving that behavior and zero downstream side effect.
3. Rewrite the cleanup-on-initial-validation-failure test so the source is complete and nonempty, staging actually occurs, and the normal attachment validator then rejects it. For example, use synthetic nonempty base64 bytes with an unsupported safe filename/type, expect the normal categorical validation error, and assert the temp-directory count returns to its pre-call value.
4. Keep all private paths/filenames/bytes synthetic and out of production diagnostics.

The downstream validator may still reject empty **filesystem** files. For serialized input, an empty base64 string is not a meaningful serialized content field under the accepted form-compatibility rule, so it need not reach `.emptyFile`.

## Review finding 3 — compound persisted-grant mutations can race across store instances

Production currently creates separate `UserDefaultsAllowedFolderGrantStore` instances for Settings and the send resolver. The class is marked `@unchecked Sendable` and notes that `UserDefaults` is thread-safe, but its operations are compound read-modify-write sequences:

- add;
- remove;
- replace/reauthorize;
- stale-bookmark refresh.

`UserDefaults` thread safety does not make those compound sequences atomic. A send-side stale-bookmark refresh can race with a Settings-side remove and re-save an older array, potentially resurrecting a folder grant the user just removed. Other concurrent mutations can similarly lose updates.

### Required correction

Serialize persistence access across **all production instances that share this storage**, not merely within one instance. Use the smallest repository-appropriate mechanism, such as a process-wide/static lock around load/list and complete read-modify-write transactions, with unlocked private load/save helpers to avoid recursive locking.

Requirements:

- `listGrants` observes a coherent snapshot;
- add/remove/replace/refresh transactions cannot interleave and overwrite one another;
- a stale refresh cannot resurrect a grant removed by another store instance;
- no async actor redesign or broad persistence framework is needed;
- preserve the existing storage key, serialized format, dedup semantics, and separate Messages-database bookmark state.

Add focused coverage where practical. At minimum, inspect the implementation adversarially for nested-lock/deadlock mistakes and cross-instance behavior. If a deterministic regression test requires an invasive scheduling hook, prefer the narrow production fix plus existing persistence tests rather than overengineering the test harness.

## Verification requirement — XCTest execution remains an acceptance prerequisite

The previous implementation session reported that `xcodebuild ... test` could not launch `imcp-serverTests` because of an environment-wide LaunchServices `IDELaunchErrorDomain` code 20. `build-for-testing` succeeded, but **no test execution occurred**. The prior 282/282 result predates this milestone.

After the correction:

1. run the focused source/grant tests;
2. run the full `imcp-serverTests` suite;
3. run format lint and `git diff --check`;
4. rebuild Debug iMCP;
5. rerun the CLI elicitation-proxy test if applicable;
6. regenerate the signed ManualVerification build;
7. verify signature, effective entitlements, and Hardened Runtime remain unchanged.

Do not claim passing tests unless XCTest actually executes them.

If the exact same environment-wide LaunchServices test-launch failure persists after one normal retry, do **not** spend the session trying to redesign tests or repair unrelated runner infrastructure. Complete all other verification, report the exact remaining gap, and stop for supervisor handling. But the correction itself must compile cleanly through `build-for-testing` even if execution remains unavailable.

No automated verification may send a real message or attachment or access private Messages/Contacts data.

## Focused tests required by this correction

At minimum prove, with synthetic data:

- filesystem initial validator failure releases the just-acquired source access exactly once or through the strongest narrow observable seam available;
- serialized initial validator failure removes the staged temp directory;
- successful filesystem/serialized handles still clean up exactly once through the existing outer defer path;
- meaningful filename + blank/whitespace `content_base64` fails as incomplete serialized source before staging;
- valid filesystem and serialized source paths remain green;
- grant add/remove/replace/refresh persistence behavior remains green after synchronization;
- no caller-owned filesystem source is deleted or modified;
- existing attachment confirmation, automatic mode, revalidation, one-dispatch, privacy, and destination tests remain unchanged/green.

Do not weaken source blank-field compatibility, attachment validation policy, grant containment, symlink/traversal rejection, or any send authorization invariant.

## Documentation/report

No new ADR is required. ADR 0014's product decision remains unchanged.

Update `docs/project-reports/programmatic-attachment-ingress-2026-08-17.md` only as needed so its final verification claims and cleanup description are truthful after this correction. If XCTest executes successfully, replace the old unresolved-test-execution section with the actual focused/full results. If the launch limitation persists, keep the gap explicit.

Do not rewrite historical reports unrelated to this milestone.

## Scope exclusions

Do not implement or redesign:

- attachment API shape or Settings UX beyond what is necessary for these fixes;
- automatic-send indicator/Pause UI;
- circuit breaker;
- Recent Send Activity;
- text send;
- new-recipient attachment composition;
- connection auth / trusted clients;
- source deletion/staging-root semantics;
- Full Disk Access;
- RCS;
- idempotency;
- upstream PR decomposition;
- unrelated refactors.

## Git and handoff

Use additive correction commit(s) only. Do not rewrite `a16be772...` or any earlier reviewed commit.

A separate new report file is unnecessary; update the existing milestone report if verification facts change.

Suggested implementation commit message:

`fix: close attachment ingress resource lifetime gaps`

Push normally to `origin/feat/messages-write-foundation`, fetch, verify local HEAD exactly equals origin, and leave the worktree clean.

Do not open or merge a maintainer-facing PR.

## Stopping point

STOP after:

- both initial-validation resource leaks are fixed;
- serialized validation-failure cleanup is tested with a source that actually reaches staging/validation;
- blank serialized-content field semantics remain correct and explicitly tested;
- persisted grant mutations cannot race across production store instances and resurrect/lose authority;
- focused/full XCTest execution passes, **or** the same environment-wide launch failure is re-confirmed once and clearly reported without false pass claims;
- build/format/diff/proxy/signing checks pass as applicable;
- existing attachment product behavior and original connection auth remain unchanged;
- report is truthful;
- additive correction is pushed and local/origin heads match with clean worktree.

When complete, the user should only need to say **done**.
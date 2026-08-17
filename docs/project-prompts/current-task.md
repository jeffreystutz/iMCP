# Current Claude Code Task

**Status:** active review correction

**Recommended session:** continue the current Claude Code session  
**Recommended model:** Sonnet  
**Effort:** high — the code change is tiny, but it sits on a security-sensitive send boundary where malformed input must fail closed without changing already-reviewed downstream behavior.

This file is the canonical supervising prompt for one bounded correction task.

## Repository and exact current state

Repository: `jeffreystutz/iMCP`  
Branch: `feat/messages-write-foundation`

The exact implementation head under supervising review is:

`822e9c84e628fe8d36f231e6a27eba5580a6e353` — `refactor: simplify Messages send destination inputs`

That implementation is **not yet supervising-accepted**. Its intended product changes are otherwise correct and should be preserved:

- public send tools remain exactly `message_send_text` and `message_send_attachment`;
- singular public `recipient` is gone;
- public `recipients` accepts either one scalar exact handle or a non-empty array;
- scalar and one-item-array `recipients` mean identical direct-recipient intent;
- arrays with two or more entries mean exact-existing-group intent and normalization collisions fail closed rather than degenerating into a direct send;
- `chat_id` remains the mutually exclusive alternative destination selector;
- `message_send_text.body` is required and missing/malformed/empty body is a terminal error; missing-body elicitation is gone;
- `sendText` and `sendAttachment`, global Sending-mode authorization, destination/file revalidation, Automation/addressability, dispatch, privacy, and result semantics were intentionally unchanged.

Before editing:

1. `git pull --ff-only origin feat/messages-write-foundation`;
2. retrieve and follow the project coding-agent bootstrap required by `AGENTS.md`;
3. verify repository, branch, remotes, local/origin equality, and clean worktree;
4. verify `822e9c84e628fe8d36f231e6a27eba5580a6e353` is in history and that only this prompt-only trajectory commit follows it;
5. inspect `MessageService.resolveDestination`, `parseRecipients`, the two send-tool closures/schemas, `MessageSendTests`, and `MessageAttachmentSendTests` before changing anything.

If any unexpected production source/test commit follows `822e9c84...`, stop and report the exact state rather than absorbing it.

Do not amend, rebase, reset, squash, force-push, or rewrite reviewed history.

## Supervising review finding

The current shared destination parser does not fully enforce the settled rule that **exactly one destination selector may be supplied**.

At `822e9c84...`, `resolveDestination` effectively does this:

```swift
let recipientsValue = arguments["recipients"]
let chatID = arguments["chat_id"]?.stringValue
let suppliedDestinationCount = [recipientsValue != nil, chatID != nil]
    .filter { $0 }.count
guard suppliedDestinationCount == 1 else {
    throw MessageSendError.invalidDestination
}
```

This counts `chat_id` only after successfully parsing it as a string. Therefore a malformed request such as:

```text
recipients = valid scalar or array
chat_id = non-string value
```

silently treats the malformed `chat_id` as absent and can proceed using `recipients`.

That violates the public contract and the project's fail-closed input boundary. Selector exclusivity is about **which properties were supplied**, not which supplied properties happened to parse successfully.

The same shared helper serves both `message_send_text` and `message_send_attachment`, so the defect affects both tools.

## Concrete goal

Make destination-selector validation fail closed by counting raw key/property presence before parsing selector values.

The intended shape is conceptually:

```swift
let recipientsValue = arguments["recipients"]
let chatIDValue = arguments["chat_id"]
let suppliedDestinationCount = [recipientsValue != nil, chatIDValue != nil]
    .filter { $0 }.count
guard suppliedDestinationCount == 1 else {
    throw MessageSendError.invalidDestination
}
```

Only after that exclusivity check should the selected value be parsed/validated.

A malformed extra selector must never be ignored. A malformed sole selector must fail clearly with zero side effect.

Use the smallest implementation that satisfies this contract and fits existing error conventions. Do not invent a broader validation abstraction unless repository evidence requires it.

## Required behavior

Preserve these exact semantics:

- neither `recipients` nor `chat_id` supplied -> fail;
- both properties supplied -> fail `invalidDestination`, regardless of whether either value is malformed;
- valid `recipients` alone -> existing scalar/array parsing unchanged;
- malformed `recipients` alone -> existing appropriate recipients/input failure unchanged;
- valid non-empty string `chat_id` alone -> existing explicit-chat behavior unchanged;
- non-string `chat_id` alone -> fail closed before destination resolution, confirmation, composition, picker, Automation, or dispatch;
- blank/whitespace string `chat_id` alone -> existing `invalidChatIdentifier` behavior unchanged;
- no caller-controlled mode/bypass/path/file behavior is added.

Do not rely on MCP-client JSON Schema validation as the only defense. The server-side parser must reject malformed direct calls itself.

## Required focused tests

Add focused regression coverage on **both** public send tools. At minimum prove:

1. valid scalar `recipients` + non-string `chat_id` -> `invalidDestination`, with zero downstream side effects;
2. valid array `recipients` + non-string `chat_id` -> `invalidDestination`, with zero downstream side effects;
3. non-string `chat_id` as the sole selector -> fails closed with zero downstream side effects;
4. the same malformed-selector cases are covered for `message_send_attachment`, and no attachment picker is invoked;
5. existing valid scalar/one-item-array/group/chat_id behavior remains green;
6. existing missing/malformed/empty-body behavior remains green and never elicits a missing body;
7. existing Ask/Automatic authorization, destination revalidation, attachment file revalidation, Automation/addressability, one-dispatch/no-retry, privacy, and new-recipient behavior remain green.

Prefer extending the existing selector-validation tests rather than creating redundant fixture machinery.

## Scope and exclusions

This is a **parser correctness correction only**.

Do not implement or redesign:

- staging-directory attachment ingress;
- serialized/base64 attachment ingress;
- managed file-access Settings;
- persistent filesystem grants/bookmarks;
- staging cleanup/delete-after-send;
- the current temporary attachment picker behavior;
- send-tool names or schemas beyond what is necessary for this selector-presence defect;
- text/attachment downstream send pipelines;
- Sending-mode Settings or authorization behavior;
- new-recipient behavior;
- circuit breaker, activity history, idempotency, client identity hardening, RCS work, CLI fragility cleanup, or upstream PR decomposition;
- unrelated refactors or documentation churn.

The native attachment picker is known to be rejected as the final product ingress, but it is intentionally left untouched in this correction because the attachment-ingress redesign is a separate milestone.

## Security and privacy invariants

Do not weaken any existing invariant:

- exact destination validation and ambiguity failure;
- exact-existing-group semantics for arrays of two or more recipients;
- duplicate/normalization-collision group failure;
- verified-new direct-recipient text composition distinction;
- attachment verified-new-recipient refusal;
- final Ask-mode authorization / live global Automatic mode behavior;
- destination revalidation;
- attachment file validation and file revalidation;
- Automation/TCC and exact chat addressability checks;
- fixed AppleScript source and descriptor-only caller data;
- one Messages dispatch per operation, no retry/fallback;
- cancellation-before-dispatch;
- privacy-redacted logs/errors/results;
- submitted-not-delivered truthfulness.

Use only synthetic values in tests. Do not read, print, log, or commit private Messages/Contacts data or real attachment paths/content. Do not send any real message or attachment.

## Documentation

This defect does **not** change the accepted product decision in ADR 0013; it corrects implementation of its already-stated mutually exclusive selector contract.

Do not create another ADR.

Update ADR 0013 or the existing report only if a factual implementation statement there would otherwise remain false after this correction. Prefer no docs churn if the existing wording already describes the intended fail-closed contract accurately.

A separate project report is unnecessary for this tiny iterative correction if the commit message and diff are self-explanatory.

## Verification

Run focused selector-validation tests first, then full verification.

At minimum:

- focused `MessageSendTests` and `MessageAttachmentSendTests` covering the new malformed-selector cases;
- `swift format lint --strict --recursive App AppTests`;
- `git diff --check`;
- full `imcp-serverTests` suite;
- Debug iMCP build;
- regenerate/verify the signed `.build/ManualVerification` app using the established project procedure if that procedure remains applicable to this exact head;
- `codesign --verify --strict` and confirm the effective entitlement set/Hardened Runtime remain unchanged if the signed build is regenerated.

Do not spend time on the known unrelated `CLITests/test_elicitation_proxy.py` `DYLD_FRAMEWORK_PATH` fragility unless this change unexpectedly touches that path.

Perform adversarial self-review specifically for:

- selector presence still being inferred from successful type conversion anywhere;
- malformed extra selector being silently ignored;
- one public tool behaving differently from the other at the shared selector boundary;
- malformed input reaching database resolution, confirmation, composition, picker, Automation, or dispatch;
- accidental changes to `sendText` or `sendAttachment`;
- weakening of scalar/one-item-array equivalence or group collision defenses.

## Git and handoff

Use one additive implementation/test commit. Do not rewrite `822e9c84...` or this prompt-only commit.

A suitable commit message is:

`fix: fail closed on malformed Messages destination selectors`

Push normally to `origin/feat/messages-write-foundation`, then:

- `git fetch origin`;
- verify local HEAD exactly equals `origin/feat/messages-write-foundation`;
- verify worktree clean.

Do not open or merge an upstream PR.

## Manual verification

Do **not** perform a real/manual Messages send in this task.

This correction does not add a new human interaction surface. After supervising code review, the existing compact manual checkpoint for the final destination/body API remains sufficient:

- refresh the MCP client and confirm singular `recipient` is absent and `recipients` is scalar-or-array;
- missing `body` fails immediately with no missing-body form;
- scalar `recipients` reaches the normal Ask-mode final confirmation, then cancel;
- one-item-array `recipients` reaches the same final confirmation, then cancel.

Do not use the temporary attachment picker as final product-acceptance evidence; attachment ingress will be redesigned separately.

## Stopping point

STOP after:

- selector exclusivity is based on raw property presence, not successful parsing;
- malformed extra/sole `chat_id` cases fail closed for both send tools;
- focused and full tests pass;
- formatting/diff/build/signing verification applicable to this project passes;
- no unrelated production behavior changes;
- branch is pushed normally, local HEAD equals origin, and worktree is clean.

When complete, the user should only need to say **done**.
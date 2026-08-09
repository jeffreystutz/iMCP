# ADR 0006: New-recipient system Messages composition

- Status: Proposed
- Date: 2026-08-09
- Deciders: iMCP maintainers
- Supersedes: the plain-text iMessage recipient path in ADR 0002
- Superseded by:

## Context

ADR 0002 sent to a recipient with no existing conversation by resolving
`participant <handle> of <account>` in a fixed AppleScript handler, after
selecting `first service whose service type = iMessage`.

Measurement showed that specifier is not a routing decision at all. It resolved
every tested handle on every account — including a reserved fictional number
with no conversation, accounts whose `service type` cannot even be read, and a
disabled RCS account — and simply echoed back whatever handle and account it was
given. `exists participant` therefore carries no reachability, capability, or
route information. Email behaves identically at the scripting layer.

The consequence was that iMCP bound an unmatched phone number to an
iMessage-scoped participant with no evidence iMessage was the right route, and
the caller could not be told which route was actually used.

Messages exposes no transport-neutral scripted destination, and nothing public
predicts the route of a new recipient. Adding a caller-facing service selector
would only move the guess to the client.

## Decision drivers

- Never guess a transport, and never expose a transport selector.
- Never construct a destination that the platform cannot validate.
- Keep App Sandbox, public APIs, and no Accessibility or private frameworks.
- Keep authorization truthful: the user must authorize what is actually sent.
- Keep the existing-conversation guarantees in ADR 0002 intact.

## Options considered

### Keep the raw participant path

Rejected. It cannot establish that its chosen route is correct, and its
confirmation would assert an exact destination that Messages may not honor.

### Add a caller-selected service parameter

Rejected. It relocates an unanswerable question to the client and invites the
retry and fallback behavior this architecture forbids.

### `NSSharingService.Name.composeMessage`

Selected. Measured on macOS 26.5.2 against the installed SDK, where the name is
public and not deprecated: it works in a process whose only entitlement is
`com.apple.security.app-sandbox`; it requires no Automation, Accessibility,
Contacts, or file consent and creates no TCC entries; it prefills recipient and
body; it presents a system-owned compose panel with a visible Send control and
both values editable; and it exposes no transport field, so Messages owns route
selection. One explicitly authorized send confirmed that: with no transport
supplied, Messages chose SMS for a recipient that had both SMS and iMessage
handles, produced exactly one outgoing message, and reused the existing
conversation without creating a duplicate.

## Decision

Route by destination resolution, before any authorization:

- a resolved existing conversation — from `chat_id`, an exactly matching group,
  or a uniquely matching direct recipient — uses the ADR 0002 programmatic path;
- a direct recipient with a *verified* absence of any existing conversation uses
  system-owned composition;
- ambiguous or unresolvable resolution fails closed;
- an existing conversation that Messages does not currently expose to automation
  fails closed as an addressability problem.

There is no automatic fallback in either direction. An existing-chat failure
never becomes a composition, a composition failure never becomes a send, and no
path branches on iMessage, SMS, or RCS.

The two modes are deliberately different authorization models.

For an existing conversation, authorization is iMCP's immutable final
confirmation of the exact destination and exact body, presented through the
configured Automatic / MCP form / iMCP app mode.

For a new recipient, authorization is the human's own review and Send action in
the system-owned panel. iMCP presents **no** final confirmation first, because
recipient and body stay editable there and an earlier immutable confirmation
could not honestly authorize whatever is ultimately sent. Missing-input
elicitation may still precede routing; gathering an input is not authorizing a
send. The confirmation-mode setting therefore governs only the programmatic
path, and its explanatory text says so.

Composition is implemented behind a small protocol so the AppKit edge stays
testable. Its lifecycle rules: create and use the sharing service on the main
actor; set `recipients`; pass the body through `perform(withItems:)` because
`messageBody` is read-only; check capability only against the real item array,
never the `nil` form, which was measured to report false even when the service
works; retain the service and coordinator until a terminal delegate callback,
since `delegate` is weak.

At most one composition may be active per process. A second request fails closed
with a distinct busy error rather than queueing a human interaction that would
surface later without context, and it never falls back to AppleScript. This does
not block unrelated read-only tools, and it is separate from the AppleScript
actor's serialization.

Outcomes map from the documented delegate callbacks. `didFailToShareItems` with
`NSCocoaErrorDomain` / `NSUserCancelledError` is user cancellation, which
experiment confirmed sends nothing. `didShareItems` means the sharing
interaction completed.

Any other `didFailToShareItems` error is an **ambiguous** outcome, not a safe
one. That callback documents only that an error occurred while sharing; it does
not establish that no message was submitted before the error, and by then the
panel has already been presented and the human may have acted. iMCP therefore
reports that the composition failed and that whether a message was sent is
unknown. It must not say nothing was sent, and it must not retry or switch
routes — an unknown outcome is precisely the case where a retry could duplicate
a real message. The underlying error is still collapsed to one sanitized value
that carries no items, recipient, body, route, or filesystem detail.

`compositionUnavailable` and `compositionBusy` are different: both occur before
this request presents a panel, so they keep their definite "nothing was sent"
semantics.

A cancelled task must not present the panel. After presentation, caller
cancellation starts no other route, performs no retry, synthesizes no Send or
Cancel, and never uses Accessibility to dismiss anything: once system UI is
visible, cancellation is not evidence that the human did not go on to complete
the composition. The coordinator therefore stays alive until a terminal
callback, and resumes exactly once.

The result is `status: user_completed_composition` with
`mode: system_messages_compose`. It carries no recipient, body, chat identifier,
transport, account, database identifier, or attachment path. It asserts neither
that the seeded values were the ones sent nor that anything was delivered.

Attachments are not implemented in this decision. The item array is the natural
extension point if approved item URLs are added later.

## Consequences

### Positive

- No production path can bind an unmatched handle to a guessed account.
- Route selection belongs to Messages, which can actually make it.
- The new path needs no additional entitlement and no new TCC grant.
- The user sees and controls exactly what is sent to a new recipient.
- Existing-conversation guarantees are unchanged.

### Negative

- Sending to a new recipient is no longer fully programmatic; it requires a
  person at the machine.
- iMCP cannot report the final recipient, body, or route for that mode.
- `didShareItems` confirms only that the interaction completed, so the tool
  result is weaker than the existing-chat submission result.
- One composition at a time; a concurrent request fails rather than waiting.

### Risks and mitigations

- Overclaiming: the result names a completed composition, never a submission or
  a delivery, and tests assert the seeded values never appear in it.
- Silent rerouting: no automatic fallback exists in either direction, and tests
  cover ambiguous, incomplete, stale, unaddressable, and no-match group cases
  reaching zero compositions.
- Double presentation: a single-active gate fails closed, and the gate is
  released on every terminal outcome including early unavailability.
- Leaked detail: non-cancellation failures are collapsed to one sanitized error.
- Duplicate sends after an unclear failure: the ambiguous outcome is terminal,
  says the send status is unknown rather than claiming safety, and triggers no
  retry or route change. Tests assert the wording and the absence of any further
  dispatch, composition, or permission request.

## Validation

Two signed, sandboxed, ignored investigations on macOS 26.5.2 produced the
platform evidence above; sample counts stay in the trajectory records rather
than becoming product constants. Automated tests cover route selection for
unmatched phone and email, ambiguous and incomplete resolution, explicit chat
IDs, exact groups, no-match groups, unaddressable existing chats, the
confirmation-count split between the two models, seeding, item-array capability
checking, cancellation and failure mapping, single-resume, the single-active
gate, cancellation before and after presentation, retention until a terminal
callback, and result redaction. Source-level regression tests assert the raw
participant path and its iMessage account selection are absent from production.

No entitlement was added. No real message was sent for this decision.

## References

- ADR 0002, for the existing-conversation path this record leaves intact
- AppKit `NSSharingService`, `NSSharingServiceDelegate`, and
  `NSSharingServiceNameComposeMessage`
- `NSUserCancelledError` in `NSCocoaErrorDomain`

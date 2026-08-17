# ADR 0010: Global Messages automatic-send authorization policy

- Status: Accepted
- Date: 2026-08-16
- Deciders: iMCP maintainers
- Supersedes:
- Superseded by:

Accepted on 2026-08-16 after the user's manual Settings UX acceptance of the
binary `MessagesSendingMode` model (Ask Before Sending / Send Automatically)
described below. Runtime wiring for existing-conversation plain-text sends
honored this policy first, then picker-based attachment sends. Those two
pipelines briefly lived behind one consolidated public `messages_send` tool
(ADR 0011), which was implemented and code-reviewed but never manually
accepted before the user reversed that consolidation; they now live behind
the two public tools `message_send_text` and `message_send_attachment` (ADR
0012), each routing to the same pipeline described here — see the "Runtime
wiring" section near the end of this record and ADR 0009's own "Runtime
wiring" section for the pipeline-level history predating both the
consolidation and its reversal. The native picker remains mandatory for
attachments in both modes, so attachment sending is not fully unattended
even under Send Automatically. Verified-new-recipient sending, for both text
and attachments, remains human-completed regardless of the selected mode.

## Context

Every programmatic Messages send currently requires one immutable final
confirmation before dispatch (ADR 0002). That default must stay, but the product
also needs a deliberate, user-controlled way to let eligible sends skip
confirmation for unattended workflows, without ever letting an MCP caller enable
that for itself.

Per-client automation authorization — separate approval state for each connected
MCP client — was considered. The user explicitly rejected it: for this project,
the additional UX, configuration, and (if it were to be made trustworthy) pairing
or authentication complexity is not worth it. The product decision is one global
policy for the whole application, applying equally to every connected MCP client,
chosen for product simplicity.

A companion investigation (recorded in Hexa, not duplicated here) separately
considered whether authorization *could* be scoped per connected MCP client if
the project wanted to. It found that the current connection stack — a bundled CLI
proxying stdio to a loopback-only `NWListener`/`NWConnection` TCP socket in the
signed app — exposes no OS-derived, unspoofable client identity. The only signal
available, `clientInfo.name`, is a plaintext value the connecting process
supplies in its own `initialize` request, already used for the existing
`trustedClients` connection-approval feature with no secondary verification, and
already provably spoofable there. That finding is not why the global model was
chosen — it did not drive the product decision — but it is a reason the project
should not describe `clientInfo.name` as an authenticated client identity, and a
reason not to build a fake per-client security boundary on top of it later
without first establishing real client identity.

This ADR covers only the policy's shape and Settings surface. No send path
consults it yet; that is a deliberate later slice, so that the Settings behavior
itself is a manually verifiable checkpoint before any confirmation can be
bypassed.

A first implementation represented the policy as four independent categories —
existing direct/group conversation crossed with text/attachment — each with its
own toggle, plus "Allow Everything Automatically" and "Require Confirmation for
Everything" actions. That implementation was code-reviewed and passed automated
verification, but failed the human manual Settings acceptance checkpoint: the
user found the four-category control surface itself more complex than the
product needs and explicitly approved a simpler binary replacement — one global
**Sending mode**, either Ask Before Sending or Send Automatically, with no
per-operation-class granularity. This ADR is revised in place to describe that
settled binary model rather than the rejected four-category one.

## Decision drivers

- Product simplicity: the user explicitly chose not to take on per-client
  approval UX, configuration, and pairing/authentication complexity for this
  project.
- Confirmation-required must remain the factory default; nothing here may weaken
  it by itself.
- Automation authorization must be app-owned, persistent policy. No MCP argument,
  prompt, or elicitation response may enable it.
- Separately, the policy must not pretend to be more precise than the identity
  model supports. A per-client policy keyed on a spoofable, self-declared string
  would be a false boundary, not a real one, so this project should not build one
  even if per-client scoping were later reconsidered.
- The control surface itself must stay minimal: a single global on/off choice
  the user can understand at a glance, not per-conversation-kind or
  per-payload-kind granularity, established by the manual UX checkpoint
  rejecting the more granular alternative.
- The mode never applies to a new recipient, which remains the human-completed
  `NSSharingService` compose flow regardless of the selected mode.
- Existing confirmation-presentation settings (`MessagesSendConfirmationMode`)
  answer a different question — how confirmation is presented when it is
  required, not whether it is required — and must stay independent, though the
  Settings layout may nest one beneath the other.
- The slice must be safe to ship and verify entirely within Settings, with zero
  effect on current send behavior.

## Options considered

### Per-client automation authorization

Considered and explicitly rejected by the user as unnecessary product
complexity: separate approval state per connected MCP client would add UX,
configuration, and — to be trustworthy — pairing or authentication work this
project does not need. That is the primary reason it was not selected.

Separately, even setting complexity aside, keying such a policy on
`clientInfo.name` specifically would not have produced a real security boundary.
That value is unauthenticated and caller-supplied; nothing distinguishes a
legitimately reconnecting trusted client from another local process that opens
the Bonjour-advertised port and echoes a previously-seen name. `clientInfo.name`
may continue to support display and the existing connection-approval feature,
but it is not an authorization boundary.

### Four-category granular control (existing direct/group × text/attachment)

Implemented first, code-reviewed, and passed automated verification, but
**rejected at the human manual Settings acceptance checkpoint**. The control
surface — four independent toggles plus "Allow Everything Automatically" and
"Require Confirmation for Everything" — was more than the user wanted to
understand or manage for a product whose actual need is a single yes/no
decision. The user explicitly approved replacing it rather than iterating on its
copy or layout.

### One binary global Sending mode

Selected. `MessagesSendingMode` has exactly two cases, `.askBeforeSending`
(factory default) and `.sendAutomatically`, with no operation-class dimension.
This is the simplest model that still satisfies every decision driver above,
and it is the model the user explicitly approved after rejecting the granular
alternative.

## Decision

Add `MessagesSendingMode`, a `String`-backed enum with exactly two cases —
`askBeforeSending` (factory default) and `sendAutomatically` — persisted as a
raw string under its own `UserDefaults` key
(`me.mattt.iMCP.messagesSendingMode`), following the same
`decode(_:)`/`load(from:)` pattern already used by `MessagesSendConfirmationMode`.

There is deliberately no operation-class dimension: no direct/group distinction,
no text/attachment distinction, and no per-client variant. `sendAutomatically`
applies equally to every connected MCP client, for every eligible
existing-conversation programmatic send. It never applies to a new recipient,
which remains human-completed `NSSharingService` composition (ADR 0006)
regardless of the selected mode.

This type replaces the earlier four-category `MessagesAutomaticSendPolicy` /
`MessagesAutomaticSendCategory`, which is deleted rather than deprecated. That
earlier type persisted under a different key
(`me.mattt.iMCP.messagesAutomaticSendPolicy`); `MessagesSendingMode` never reads
that key, so any category a developer enabled while manually testing the
rejected design cannot resolve into `sendAutomatically` now — the safe default
holds regardless of what that orphaned key contains.

Settings replaces the prior two-section split ("Message Sending" +
"Automatic Sending") with one section containing a single **Sending** choice.
When Ask Before Sending is active, a subordinate **Confirmation method** choice
(the existing `MessagesSendConfirmationMode`, its `automatic` case now labeled
"Best available" in the UI while its stored raw value stays `"automatic"`) is
shown beneath it; when Send Automatically is active, that control is hidden
rather than shown disabled. Selecting Send Automatically from Ask Before Sending
shows one native `.alert` warning that all connected MCP clients will be able to
submit eligible sends without asking each time; canceling leaves the mode
unchanged. Switching back to Ask Before Sending never warns, since that can only
make behavior safer.

This slice reads and writes the mode but does not wire it into `messages_send`
or `messages_send_attachment`. Every existing send behaves exactly as it did
before this change.

## Rationale

One global policy is simpler to build, explain, and verify than a per-client
model, and the user explicitly decided that simplicity is the right tradeoff for
this project rather than a compromise forced by any technical constraint.
Separately, the connection-identity finding reinforces the choice rather than
driving it: even if per-client scoping were reconsidered later, it should not be
built on `clientInfo.name` without first establishing a real client-identity
mechanism, since doing so today would present a false security boundary.

The same simplicity principle turned out to apply one level down, inside the
global model itself: the first attempt encoded that "global" scope as four
independent operation-class toggles, which is a defensible design on paper but
was, in practice, more control surface than the user wanted to reason about at
the point of use. Rather than iterate on that shape's copy or layout, the user
approved collapsing it to the binary choice the product actually needs today.
If a genuine need for operation-class or per-client granularity emerges later,
it is a new product decision and a new (or superseding) ADR, not a default this
one should pre-build speculatively.

Separating the mode's existence from its consumption still gives the project a
manual Settings checkpoint — the user can see and change the mode, confirm
persistence and its required behaviors, all before any code path can act on it.
That sequencing turns "did we build the right control surface" into a
reviewable step independent of "did we wire it in correctly," which is a
materially riskier change touching `messages_send`/`messages_send_attachment`
directly — a lesson reinforced, not undermined, by this correction: the control
surface itself needed its own iteration before that riskier step should begin.

## Consequences

### Positive

- No caller can ever enable automatic sending for itself; the storage key has no
  MCP-reachable writer.
- A stale, corrupt, or unrecognized persisted value always resolves to Ask
  Before Sending, never to Send Automatically.
- The rejected four-category model's persisted data, under its own separate
  storage key, is simply never read by `MessagesSendingMode` — no migration
  code was needed to make that safe, and a test pins the behavior explicitly.
- Existing `MessagesSendConfirmationMode` runtime presentation semantics are
  unchanged; only its `automatic` case's UI label changed, and only while Ask
  Before Sending is active is the control shown at all.

### Negative

- A user who wants finer-grained trust per MCP client, or per conversation/
  payload kind, cannot get it from this mode. That is now a twice-explicit,
  considered tradeoff (once for per-client scope, once for operation-class
  granularity), not an oversight.
- The Settings section currently has no effect on behavior, which is correct for
  this slice but means "I turned this on and nothing changed" is expected,
  temporary behavior until the next slice wires it in.

### Risks and mitigations

- **A future slice could wire in automatic sending incorrectly and bypass more
  than intended.** Out of scope here; mitigated procedurally by keeping this
  slice's diff free of any change to `MessagesSender.swift`, `Messages.swift`, or
  `MessagesAttachment.swift`, verified by running the full existing send-path test
  suite unchanged and confirming zero regressions.
- **A user could misread "global" as "per client" from the UI wording.** The
  Settings copy explicitly states the mode applies to every connected MCP
  client.
- **The orphaned four-category storage key could be misread as still relevant.**
  It is never referenced by name in Settings or in `MessagesSendingMode`, and a
  test asserts loading the new mode is unaffected by its contents regardless of
  what they are.

## Validation

Automated tests cover: Ask Before Sending as the factory default; persistence
round-trip for both modes; safe fallback to Ask Before Sending for absent,
empty, and unrecognized stored values (including a plausible-looking but wrong
string); the rejected four-category model's persisted data being unable to
enable Send Automatically; independence between `MessagesSendingMode` and
`MessagesSendConfirmationMode` in both directions; and the former `automatic`
case's title now reading "Best available" while its stored raw value stays
`"automatic"`. The full existing `imcp-serverTests` suite passes unchanged
alongside the new tests, evidencing no send-path regression.

Manual verification is a Settings-only checkpoint: open Settings, confirm one
Sending choice defaulting to Ask Before Sending, confirm Confirmation method
(Best available / MCP form / iMCP app) is visible beneath it only while Ask
Before Sending is active, choosing Send Automatically shows exactly one warning
that canceling reverts and accepting applies, the mode and confirmation choice
persist across Settings reopen and app relaunch, and switching back to Ask
Before Sending requires no warning and restores the Confirmation method control.
No message is sent during this checkpoint.

## Runtime wiring

Manual acceptance of the Settings-only slice above unblocked the next slice:
existing-conversation plain-text `messages_send` now reads `MessagesSendingMode`
for each call. `MessageService` gained an injected
`sendingMode: @Sendable () -> MessagesSendingMode` closure, defaulting to
`MessagesSendingMode.load()` evaluated fresh at call time (not snapshotted at
service construction), so a Settings change takes effect on the next call
without restarting the service.

The authorization branch sits immediately around the existing final-confirmation
request and nowhere else: in `.askBeforeSending`, the unchanged confirmation
flow runs; in `.sendAutomatically`, that one step is skipped. Every step before
it (destination preparation, non-prompting addressability preflight) and every
step after it (cancellation checks, destination revalidation, Automation
authorization and addressability reverification, the single `sender.submit`
dispatch, categorical logging, and the redacted result) is identical, shared
code for both modes — there is no second dispatch path. Verified-new-recipient
composition is unaffected: composition returns before the mode is ever
consulted, for both text and attachments.

A second, later slice extended this same pattern to picker-based
`messages_send_attachment`, reusing the identical `sendingMode` provider and
placing the authorization branch immediately around that tool's own final
attachment confirmation. The native file picker and bounded file validation
still run unconditionally in both modes — the picker is never itself treated
as authorization — and destination/file revalidation, Automation/addressability
verification, and the single dispatch remain shared, unconditional code after
the branch, exactly as for text. See ADR 0009's "Runtime wiring" section for
the full record of that slice.

A third, later slice (ADR 0011) briefly consolidated the two public tools
those paragraphs describe into one public `messages_send` tool routing
internally to `sendText`/`sendAttachment`. Neither pipeline's Sending-mode
behavior changed while that design stood: `sendingMode` was still read live
per call and the authorization branch still sat in exactly the same place in
each pipeline. That consolidation was implemented and code-reviewed but
never manually accepted; the user reversed it before the runtime checkpoint.

A fourth, later slice (ADR 0012) restored two public tools,
`message_send_text` and `message_send_attachment`, each again calling
exactly one of `sendText`/`sendAttachment` directly. This restoration did not
touch Sending-mode behavior either: `sendingMode` remains read live per call,
the authorization branch remains in the same place in each pipeline, and
both tools remain gated by the same app-owned setting, now reached through
two tool names instead of one shared payload selection.

`message_send_text`'s public description and its destination parameter
description state that whether confirmation happens follows the user's
Sending mode setting, which no caller can choose or override, and that the
new-recipient compose route is unaffected by that setting.
`message_send_attachment`'s public description states the same for the
attachment path, and additionally that the native picker always runs
regardless of mode.

A fifth, later slice (ADR 0013) unified the singular `recipient` and plural
`recipients` destination properties into one scalar-or-array `recipients`
property on both tools, and removed `message_send_text`'s missing-body
elicitation in favor of a hard non-empty-`body` requirement. Neither change
touched this Sending-mode wiring: `sendingMode` remains read live per call,
the authorization branch remains in the same place in each pipeline, and the
removed elicitation was strictly upstream of it — a missing body now fails
before destination resolution is ever reached, exactly as an invalid
destination already did.

## References

- ADR 0002, for the confirmation-required default this mode is now accepted to
  bypass for eligible existing-conversation sends, reconciled there to reflect
  this acceptance
- ADR 0006, for the human-completed new-recipient path this mode does not cover
- ADR 0009, for the existing-conversation attachment path and its still-binding
  security/validation contract, which this mode's authorization branch sits
  inside without altering
- `App/Services/MessagesSendConfirmation.swift`, for the independent
  presentation-mode setting this mode does not replace, and for the `automatic`
  case whose UI label this correction changed to "Best available" without
  changing its stored raw value
- `App/Controllers/ServerController.swift`, for the `trustedClients` pattern this
  mode's storage follows and the spoofable-identity finding this mode avoids
  relying on

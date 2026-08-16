# ADR 0010: Global Messages automatic-send authorization policy

- Status: Proposed
- Date: 2026-08-16
- Deciders: iMCP maintainers
- Supersedes:
- Superseded by:

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
- The shape must be forward-compatible enough to add a future automatic
  new-recipient category without redesigning the Settings architecture.
- Existing confirmation-presentation settings (`MessagesSendConfirmationMode`)
  answer a different question and must stay independent.
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

### A loose collection of independent `UserDefaults` booleans

Rejected. Four (or more, later) unrelated boolean keys make "allow everything" /
"require confirmation for everything" awkward to implement consistently, make a
future new-recipient category an ad hoc addition rather than a natural extension,
and give up the one place to enforce "an unknown persisted value must resolve to
confirmation-required" uniformly.

### One coherent value-type policy, keyed by category, JSON-encoded into one `UserDefaults` entry

Selected.

## Decision

Add `MessagesAutomaticSendPolicy`, a small value type wrapping
`Set<MessagesAutomaticSendCategory>` — the categories currently exempt from
confirmation — JSON-encoded into one `UserDefaults` entry
(`me.mattt.iMCP.messagesAutomaticSendPolicy`), following the same
encode-a-`Codable`-value-into-`Data` pattern already used for `trustedClients`.

`MessagesAutomaticSendCategory` currently has four cases, each a conversation
shape crossed with a payload shape:

- `existingDirectConversationText`
- `existingGroupConversationText`
- `existingDirectConversationAttachment`
- `existingGroupConversationAttachment`

There is deliberately no automatic-new-recipient category yet. The current
new-recipient path is human-completed `NSSharingService` composition (ADR 0006);
this policy does not apply to it, and adding a category for a mechanism that does
not exist would be speculative. Because the storage format is "the set of
categories currently automatic," adding a category later — including a future
new-recipient one — is an additive enum case, not a schema change, and any
category absent from a previously saved value decodes safely to
confirmation-required.

The policy is global. It applies equally to every connected MCP client; there is
no per-client variant, and nothing about the value type or its storage key
depends on any client-supplied information. Only Settings-owned code in
`GeneralSettingsView` reads and writes it; no MCP tool touches this storage key,
so no tool argument, prompt, or elicitation response can change it.

Settings adds one "Automatic Sending" section: a toggle per category, an "Allow
Everything Automatically" action, and a "Require Confirmation for Everything"
action. Turning on the first automatic category — whichever control causes the
transition from zero automatic categories to at least one — shows one native
`.alert` warning that connected MCP clients will be able to send eligible
operations without asking each time; subsequent categories enabled while at
least one is already automatic do not repeat it. Returning to
confirmation-required never warns, since it can only make behavior safer.

This slice reads and writes the policy but does not wire it into
`messages_send` or `messages_send_attachment`. Every existing send behaves
exactly as it did before this change.

## Rationale

One global policy is simpler to build, explain, and verify than a per-client
model, and the user explicitly decided that simplicity is the right tradeoff for
this project rather than a compromise forced by any technical constraint.
Separately, the connection-identity finding reinforces the choice rather than
driving it: even if per-client scoping were reconsidered later, it should not be
built on `clientInfo.name` without first establishing a real client-identity
mechanism, since doing so today would present a false security boundary. If a
durable client-identity mechanism is added later, a per-client override can be
layered on top of this same category model without changing its shape; nothing
here forecloses that.

Separating the policy's existence from its consumption gives the project a
manual Settings checkpoint — the user can see and change the policy, confirm
persistence and the four required behaviors (initial confirmation-required,
persistence across relaunch, "allow everything," "require confirmation for
everything"), all before any code path can act on it. That sequencing turns "did
we build the right control surface" into a reviewable step independent of "did we
wire it in correctly," which is a materially riskier change touching
`messages_send`/`messages_send_attachment` directly.

## Consequences

### Positive

- No caller can ever enable automatic sending for itself; the storage key has no
  MCP-reachable writer.
- A stale, corrupt, or partially-recognized persisted value always resolves to
  confirmation-required, never to an unintended automatic category.
- The four-category shape and the enum-case extension pattern absorb a future
  new-recipient category without a storage migration.
- Existing `MessagesSendConfirmationMode` behavior and Settings layout are
  untouched.

### Negative

- A user who wants finer-grained trust per MCP client cannot get it from this
  policy. That was an explicit, considered tradeoff, not an oversight; revisiting
  it later would also require a durable client-identity mechanism this ADR does
  not attempt to fabricate, since `clientInfo.name` alone cannot support it.
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
  Settings copy explicitly states a category applies to every connected MCP
  client.
- **Silent policy widening from a future category rename.** Tests pin the exact
  four persisted rawValue strings, so a rename is a visible, deliberate change
  rather than an accidental storage-format break.

## Validation

Automated tests cover: every category confirmation-required by factory default;
persistence round-trip through `UserDefaults`; independence between categories
under individual updates; "Allow Everything" enabling every current category;
"Require Confirmation for Everything" clearing every category; safe
confirmation-required fallback for absent, empty, corrupt, and
unknown-category-containing persisted values; and independence from
`MessagesSendConfirmationMode`. The full existing `imcp-serverTests` suite passes
unchanged alongside the new tests, evidencing no send-path regression.

Manual verification is a Settings-only checkpoint: open Settings, confirm the new
section is visible and every category starts confirmation-required, enable one
category and confirm the warning appears exactly once, confirm the change
persists across closing/reopening Settings and an app relaunch, confirm "Allow
Everything Automatically" enables all four categories, and confirm "Require
Confirmation for Everything" resets them. No message is sent during this
checkpoint.

## References

- ADR 0002, for the confirmation-required default this policy will eventually be
  permitted to bypass for eligible categories
- ADR 0006, for the human-completed new-recipient path this policy does not cover
- ADR 0009, for the existing-conversation attachment path this policy's
  attachment categories describe
- `App/Services/MessagesSendConfirmation.swift`, for the independent
  presentation-mode setting this policy does not replace
- `App/Controllers/ServerController.swift`, for the `trustedClients` pattern this
  policy's storage follows and the spoofable-identity finding this policy avoids
  relying on

# ADR 0013: Unified `recipients` destination field and strict `message_send_text.body`

- Status: Accepted
- Date: 2026-08-17
- Deciders: iMCP maintainers (user)
- Supersedes: ADR 0012 (its destination-field shape and missing-body elicitation only; see "What this does not change")
- Superseded by:

## Context

ADR 0012 restored two public tools, `message_send_text` and
`message_send_attachment`, each exposing separate `recipient` (scalar) and
`recipients` (two-or-more array) destination properties, and restored
`message_send_text`'s pre-consolidation missing-body MCP form elicitation.
That head passed supervising code review, automated verification, and
signed-build verification, but was **not fully manually accepted**: the
2026-08-17 human checkpoint explicitly rejected two pieces of that public
behavior.

1. `message_send_text` eliciting a missing `body` through an MCP form. The
   user found this UX undesirable during manual testing.
2. The two separate `recipient`/`recipients` destination fields. The user
   wants one destination field that accepts either a single handle or a list.

Both corrections are input/parser-level: neither the destination-resolution,
revalidation, Automation/addressability, dispatch, or Sending-mode logic in
`sendText`/`sendAttachment` needed to change to satisfy them.

The user also rejected the current native picker as the final ordinary
attachment ingress, in favor of a persistent user-approved filesystem
root/staging area and bounded serialized content, with the picker retained
only for Settings/onboarding grants. That redesign is **explicitly out of
scope for this record** — see "What this does not change" — and remains
future work gated on its own UX/security/entitlement acceptance.

## Decision drivers

- Material product choices belong to the user: two pieces of ADR 0012's
  shipped-but-not-fully-accepted behavior were explicitly rejected during
  manual testing, and that rejection is determinative.
- A single `recipients` field that accepts a scalar handle or a list is
  simpler for a caller to reason about than two differently-shaped
  properties for what is conceptually one selector.
- Once destination input is unambiguous again through a single field,
  keeping a separate strict-body requirement is straightforward: a caller
  that wants to send text must simply supply the text, with no elicitation
  standing in for it.
- Preserve every already-reviewed downstream invariant in `sendText`/
  `sendAttachment` — this is a parser correction, not a re-opening of the
  send engines.

## Options considered

### Keep separate `recipient`/`recipients` properties (ADR 0012)

Rejected. The user explicitly asked for one destination field during manual
review of ADR 0012's shipped behavior.

### Two public properties for scalar vs. array, mutually exclusive

Considered: e.g. `recipient: string` and `recipients: array`, exactly one
supplied. Rejected as the same shape ADR 0012 already had under different
names — it does not address the user's request for one field, and it
duplicates the "exactly one of two similarly-named things" pattern this
project already avoids elsewhere (see ADR 0011's schema-construct
discussion).

### One `recipients` property, JSON Schema `oneOf` for scalar-or-array

Selected. This project already has precedent for a single property accepting
either a scalar or an array shape via `oneOf` — `showPointsOfInterest` in
`App/Services/Maps.swift` accepts either a boolean or an array of strings the
same way. Reusing that idiom here, rather than inventing a new schema
abstraction, keeps the tool definition in the same style as the rest of the
codebase.

### Restore missing-body elicitation, unchanged from ADR 0012

Rejected. The user explicitly rejected this UX during the same manual
checkpoint that rejected the two-property destination shape. `body` becomes
a hard requirement: missing, non-string, or empty all fail immediately.

## Decision

Both public tools, `message_send_text` and `message_send_attachment`, accept
exactly one of:

- `recipients` — either a scalar exact handle (string) or a non-empty array
  of exact handles, expressed in the schema via `oneOf`, matching the
  project's existing `showPointsOfInterest` precedent;
- `chat_id` — unchanged from ADR 0012.

The singular `recipient` property is removed entirely from both schemas and
from all parsing paths, with no alias: this feature-completion branch has no
released compatibility requirement for it.

`recipients` parsing normalizes only at the boundary:

- a scalar string, or a one-item array, both express identical
  direct-recipient intent and reach the same existing `SendDestination.recipient`
  case, validated the same way (`isExactMessageHandle`) that the pre-ADR-0013
  scalar `recipient` property was;
- an array with two or more supplied elements expresses exact-existing-group
  intent, validated and normalized exactly as ADR 0009's/ADR 0012's
  `recipients` array always was: every element must be a valid exact handle,
  and after normalization there must be at least two distinct handles, or
  the call fails with `insufficientGroupParticipants` — this is what makes
  duplicate or normalization-colliding group input fail closed rather than
  silently degenerate into a direct send;
- an empty array is a new, explicit failure mode (`emptyRecipients`), since
  the schema no longer enforces a minimum array length the way ADR 0012's
  `minItems: 2` did for its `recipients` property.

`SendDestination`'s internal `.recipient`/`.recipients`/`.chat` cases are
unchanged: only the public property shape and the parsing that feeds them
changed. `message_send_text`'s and `message_send_attachment`'s previously
duplicated destination-selector parsing is merged into one shared
`resolveDestination`/`parseRecipients` pair, since both tools now have
byte-identical destination-selector logic once `recipient` is gone.

`message_send_text.body` is required and must be a non-empty string.
Missing-body elicitation is removed completely:

- a missing `body` fails immediately with `missingInput`, before any
  destination lookup, confirmation request, composition, or dispatch;
- a non-string `body` fails immediately with `inputMalformed`;
- an empty-string `body` fails with the existing `emptyBody`, exactly as
  before — this check already ran as the first statement in `sendText`,
  before any destination resolution, so it required no relocation;
- a valid non-empty `body` proceeds through the unchanged `sendText`
  pipeline exactly as before.

Final send confirmation is completely unaffected: in Ask Before Sending, the
existing confirmation mechanism (MCP form or native, per the independent
presentation-mode setting) still runs after destination resolution for every
eligible existing-conversation submission; in Send Automatically, only that
confirmation is skipped, exactly as ADR 0010 established.

## Rationale

A single `recipients` field matches how a caller actually thinks about the
destination — "who is this going to" — without asking them to first decide
whether that is one person or several before picking a property name. The
`oneOf` scalar-or-array shape is not a new schema idiom for this project; it
is the same construct `showPointsOfInterest` already uses, so this decision
extends an existing pattern rather than introducing one.

Making a missing body a hard failure rather than an elicitation opportunity
is a return to the platform's simplest contract: this tool sends text, so a
caller invoking it must supply the text. Removing the elicitation also
removes an entire code path (`context.elicitation.requestForm` for input
gathering) that existed only to soften a caller's incomplete request, at the
cost of an extra round trip the user did not want.

Merging `resolveSendInput`'s and `resolveAttachmentDestination`'s
destination-selector logic into one shared parser is a direct consequence of
removing `recipient`: with that property gone, the two tools' destination
parsing became identical, and keeping two copies would only be duplication
for its own sake.

## Consequences

### Positive

- One destination field, matching the user's explicit request.
- No missing-body elicitation round trip; text sends succeed or fail
  immediately based on what the caller actually supplied.
- Destination-selector parsing is shared between both tools instead of
  duplicated.
- The `oneOf` scalar-or-array idiom is now used in two places in the
  codebase (`Maps.swift`, `Messages.swift`), reinforcing it as the
  project's established pattern for this shape rather than a one-off.

### Negative

- Callers that supplied the singular `recipient` property must migrate to
  `recipients` with a scalar value; no alias is provided.
- A caller that relied on missing-body elicitation to be prompted for text
  must now supply `body` itself; iMCP will not ask.
- Reintroduces one new failure mode (`emptyRecipients`) that the schema
  previously prevented structurally via `minItems: 2`; callers must now
  handle an empty-array response explicitly rather than never being able to
  construct it.

### Risks and mitigations

- **A one-item array could be silently treated as a group of one, or a
  scalar and a one-item array could diverge in behavior.** Mitigated:
  `parseRecipients` routes both to the identical `.recipient` case through
  the identical validation (`isExactMessageHandle`), and dedicated tests
  assert scalar and one-item-array inputs dispatch identically for both
  tools.
- **Two or more raw entries that normalize-collide could degenerate into a
  direct send instead of failing.** Mitigated: the existing
  `distinct.count >= 2` guard, unchanged from ADR 0009/ADR 0012, still runs
  for every array with two or more raw elements, and a dedicated test
  supplies two normalization-colliding entries and asserts
  `insufficientGroupParticipants` rather than success.
- **Merging the two tools' destination parsers could let one tool reach the
  other's pipeline.** Mitigated: the shared `resolveDestination` returns
  only a `SendDestination`; each tool's closure still calls exactly one of
  `sendText`/`sendAttachment` directly, unchanged from ADR 0012.
- **Removing missing-body elicitation could be mistaken for removing final
  send authorization.** These are different steps: `resolveSendInput`
  (destination + body parsing) now runs synchronously and throws before
  `sendText` is ever called; `sendText`'s own final-confirmation branch
  (Ask Before Sending vs. Send Automatically) is untouched and still runs
  after destination resolution, for every eligible existing-conversation
  submission.
- **`inputDeclined`/`inputCancelled` becoming dead code.** Both were only
  reachable from the removed missing-body elicitation branch; confirmed via
  repository search that no other production path referenced either before
  removing them.

## Validation

Automated tests cover: both tools' schemas contain `recipients` (`oneOf`
scalar-or-array) and `chat_id`, and contain no `recipient` property in any
spelling; `message_send_text` additionally requires `body`, and
`message_send_attachment` exposes no body/caption/file/path/bytes/source
field; scalar and one-item-array `recipients` produce identical
direct-recipient and verified-new-recipient behavior for both tools;
two-or-more-item arrays preserve exact-group behavior unchanged; duplicate or
normalization-colliding two-or-more-item arrays fail with
`insufficientGroupParticipants` rather than degenerating into a direct send;
an empty array fails with `emptyRecipients`; a non-string array element or
malformed scalar fails with `invalidRecipient`; `recipients` and `chat_id`
together, or neither, fail with `invalidDestination`; a missing, non-string,
or empty `body` fails immediately with zero elicitation, confirmation,
composition, Automation request, or dispatch; a valid body still reaches
exactly one final confirmation in Ask Before Sending and skips only that
confirmation in Send Automatically, with destination revalidation,
Automation/addressability, and exactly one dispatch unchanged; and the full
existing attachment Ask/Automatic, picker-cancellation, revalidation, and
one-dispatch coverage remains green after the destination-parser change. The
full `imcp-serverTests` suite passes with a net-small increase in test count
over the ADR 0012 head, reflecting new scalar/array-equivalence and
degenerate-group coverage rather than any removed safety assertion.

## What this does not change

This ADR supersedes only ADR 0012's `recipient`/`recipients` destination-field
shape and its restored missing-body elicitation. It does not reopen, and
explicitly reaffirms unchanged:

- ADR 0009's full attachment security/validation contract — mandatory native
  picker (for this record; see below), bounded file validation,
  security-scoped access lifetime, destination and file revalidation
  immediately before dispatch, fixed-script typed-descriptor dispatch,
  one-dispatch/no-retry semantics, privacy redaction, and
  submitted-not-delivered truthfulness;
- ADR 0010's global Sending mode and its accepted exception to ADR 0002's
  per-submission confirmation default, wired identically into both tools
  exactly as before;
- ADR 0002's/ADR 0006's text and verified-new-recipient composition
  invariants;
- ADR 0012's two-tool public-API split (`message_send_text`/
  `message_send_attachment`) and its ADR 0009/ADR 0010 carry-forward
  language, which this record does not touch.

This ADR also does **not** implement the user's separately-decided future
attachment-ingress redesign (a persistent user-approved filesystem root with
staging, bounded serialized content, and picker use confined to Settings/
onboarding). The current native picker remains, deliberately, the reviewed
downstream-execution scaffold for `message_send_attachment` until that
redesign's own UX/security/entitlement acceptance boundary is settled in a
later ADR. Nothing about that future direction is decided or implied by this
record beyond noting that it is already the user's settled intent and is out
of scope here.

## References

- ADR 0002, for the confirmation-required default, unaffected by this record
- ADR 0006, for the human-completed new-recipient path, unaffected
- ADR 0009, for the attachment security/validation contract, carried forward
  unchanged
- ADR 0010, for the global Sending mode both tools honor identically before
  and after this correction
- ADR 0012, superseded for its destination-field shape and missing-body
  elicitation only; its two-tool split and ADR 0009/ADR 0010 carry-forward
  language are unaffected
- `App/Services/Maps.swift`, `showPointsOfInterest`, the existing
  scalar-or-array `oneOf` precedent this record reuses
- `App/Services/Messages.swift`, `resolveDestination`, `parseRecipients`,
  `resolveSendInput`, `sendText`, `sendAttachment`

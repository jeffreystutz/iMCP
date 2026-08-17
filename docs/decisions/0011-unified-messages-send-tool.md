# ADR 0011: Unified `messages_send` tool for text and picker attachments

- Status: Accepted
- Date: 2026-08-16
- Deciders: iMCP maintainers
- Supersedes: ADR 0009 (its public-API decision only; see "What this does not change")
- Superseded by:

## Context

The public Messages send surface grew incrementally: `messages_send` for
existing-conversation plain text and verified-new-recipient composition, then
a separate `messages_send_attachment` for existing-conversation picker-based
attachments (ADR 0009). That separation was a useful implementation
boundary — it let attachment support ship and be reviewed independently — but
it is not the desired final public API. Two permanent, near-identical send
tools differing only in payload type is more public surface than the product
needs, and it does not extend cleanly: a future third attachment source
(handoff directory, serialized content) would either need a third tool or
force the two existing tools apart further.

The global `MessagesSendingMode` (ADR 0010) is already wired into both the
text and the picker-attachment pipeline as of this decision, so both payload
types already share the same authorization model. That made this the right
moment to also unify the public entry point, rather than growing two
authorization-identical tools in parallel indefinitely.

## Decision drivers

- One public Messages send operation is simpler for a caller to discover and
  reason about than two.
- Future attachment ingress sources (handoff directory, serialized content)
  should extend one namespace (`attachment.source`) rather than multiply
  top-level tools.
- Messages AppleScript `send` accepts exactly one direct parameter, `file` or
  `text`, so one dispatch can never carry both — the one-dispatch/no-retry
  invariant requires payload exclusivity regardless of how many public tools
  exist.
- The already-reviewed internal pipelines (destination resolution, picker,
  file validation/revalidation, confirmation/automatic authorization,
  Automation/addressability, dispatch) must not be rewritten merely because
  the public router changes; only the entry point and payload-selection logic
  are new.
- No caller-facing argument may select Sending mode, confirmation bypass,
  file path, filename, or raw bytes.

## Options considered

### Keep two permanent public tools

Rejected. This is what shipped through ADR 0009 and the attachment
Sending-mode slice, and it worked as an implementation boundary, but the user
explicitly decided it is not the desired final API: it doubles the public
surface for something that is really one operation with two payload shapes,
and it does not extend cleanly to future attachment sources.

### One tool, JSON Schema `oneOf` to express exactly-one-payload

Considered. The vendored `JSONSchema` package supports `oneOf`/`anyOf`/`allOf`/`not`,
and they are already used elsewhere in this project (`Calendar.swift`,
`Maps.swift`) for individual property value unions. Expressing "exactly one of
two top-level properties, each with its own required sub-shape, and the other
absent" as `oneOf` is possible but requires two full nested object-schema
branches with `not: { required: [...] }` guards — a materially more complex
schema shape than anything currently in this codebase's tool definitions, and
untested against how the intended MCP clients (Claude Desktop, ChatGPT, MCP
Inspector) render or validate `oneOf` at the top level of a tool's arguments
for UI/form generation. Rejected for this task per the explicit guidance to
prefer a simpler construct unless the SDK cleanly supports the exact rule
"without harming client compatibility" — this project's own existing
destination-selector precedent (`recipient`/`recipients`/`chat_id`, exactly
one required, enforced entirely in code rather than schema) already answers
that preference.

### One tool, flat optional properties, exactly-one-payload enforced in code

Selected. Matches the existing, already-shipped, already-client-tested
convention this project uses for destination selectors. `body` and
`attachment` are both plain optional top-level properties; `resolveSendPayload`
enforces exactly one is present before anything else runs, mirroring how
destination-selector counting already works.

## Decision

`messages_send` is the one public Messages send operation. It keeps the
existing mutually exclusive destination selectors (`recipient`, `recipients`,
`chat_id`) and adds exactly one of two top-level payload alternatives:

- `body: string` — plain text, unchanged from the prior standalone
  `messages_send` contract;
- `attachment: object` — currently only `{"source": "picker"}`, rejecting any
  other source value, a missing `source`, a non-object value, or any extra
  field.

`body` and `attachment` are both optional at the schema level (top-level
`additionalProperties: false` remains); exactly-one-of is enforced in code by
`resolveSendPayload`, which throws before any destination lookup, picker,
confirmation, Automation request, or dispatch:

- neither present → `missingSendPayload`;
- both present → `conflictingSendPayload`;
- `attachment` present but malformed (wrong type, missing/unsupported
  `source`, or an extra field) → `invalidAttachmentPayload`.

This deliberately does not attempt to elicit a missing payload. The prior
standalone text tool elicited a missing `body` because text was the only
possible interpretation; with two payload shapes now available, a missing
payload is genuinely ambiguous between "forgot body" and "forgot attachment,"
and guessing which one the caller meant would be exactly the invented
payload-type elicitation this design explicitly avoids. The three
now-dead `MessageSendError` cases this superseded (`inputDeclined`,
`inputCancelled`) were removed; `inputMalformed` is kept, since it remains a
meaningful signal for a `body` key present with a non-string value, and
remains a harmless generic fallback in test infrastructure elsewhere.

`messages_send_attachment` is removed from the public tool list. Its
internal pipeline is not rewritten: `MessageService` gained private
`sendText`/`sendAttachment` methods that are, line for line, the same
reviewed bodies the two former closures contained, with only their
destination- and payload-parsing extracted to shared call sites
(`resolveDestination`, now merged from the two previously duplicated
`resolveSendInput`/`resolveAttachmentDestination` implementations, and
`resolveSendPayload`). The unified tool closure does nothing but resolve the
payload, resolve the destination, and call exactly one of the two private
methods — there is no shared dispatch code between them beyond the
destination-resolution helpers both already used.

## Rationale

Enforcing exactly-one-payload in code rather than schema keeps the tool
definition in the same shape as everything else in this file, avoids
introducing a schema construct with unverified client-rendering behavior for
this specific "one of two sibling properties" shape, and keeps the actual
validation logic — which must run regardless of what the schema says, since
schema `required`/`oneOf` is advisory for many MCP clients rather than
strictly enforced before a tool call reaches the server — the single source
of truth. This matches the project's own precedent for destination selectors,
which use the identical pattern today.

Not eliding a genuinely missing payload into an elicitation prompt is a
product decision, not an oversight: filling in a missing `body` used to be
safe because there was only one thing a text tool could want. A missing
payload today could mean two different things, and this design chooses to
fail closed and informatively rather than guess.

## Consequences

### Positive

- One public tool to discover, call, and reason about, instead of two.
- Future attachment sources extend `attachment.source` without a new
  top-level tool.
- No behavior change to the already-reviewed pipelines: `sendText` and
  `sendAttachment` are the same code that was already accepted, just no
  longer duplicating destination-parsing.
- The exactly-one-payload invariant is enforced once, in one place, before
  any side effect, rather than being implicit in "which tool did you call."

### Negative

- Callers that relied on the standalone `messages_send_attachment` tool name
  must migrate to `messages_send` with an `attachment` payload. This feature
  branch has no established released compatibility requirement for that
  name, so no alias or deprecation layer was introduced.
- A caller that omits both `body` and `attachment` now receives an immediate
  categorical failure rather than an elicitation prompt to supply a missing
  body, a behavior change from the prior standalone text tool.

### Risks and mitigations

- **A regression could let one call reach both pipelines, or one pipeline
  silently fall back to the other.** Mitigated structurally: `resolveSendPayload`
  returns a two-case, non-optional `SendPayload` enum, and the tool closure's
  `switch` over it has exactly two cases, each returning immediately from
  exactly one of `sendText`/`sendAttachment`. Neither method calls the other.
  Verified by dedicated tests for both/neither/malformed payloads and by a
  routing-differentiation test showing the same verified-new-recipient
  destination is handled differently by payload.
- **The schema could accidentally accept a file path/bytes/mode argument.**
  Verified by a schema test asserting the exact property set and asserting a
  broad list of forbidden substrings is absent from the encoded schema.
- **Consolidating could quietly weaken destination/file revalidation, the
  picker requirement, or Automation/addressability checks.** Mitigated by
  moving the previously-reviewed bodies verbatim rather than rewriting them,
  and by re-running the full existing revalidation/authorization test matrix
  for both payload types unchanged.

## Validation

Automated tests cover: the public tool list contains `messages_send` and not
`messages_send_attachment`; the unified schema's exact property set and the
`attachment` object's own nested schema; missing/conflicting/malformed
payload failures with zero picker, confirmation, Automation request,
composition, or dispatch; text and attachment payloads routing to their
correct pipeline, including divergent verified-new-recipient handling; Ask
Before Sending and Send Automatically behavior preserved for both payload
types, including live mode changes on one service instance without
reinitializing; picker cancellation, destination staleness, file
change/replacement, and Automation denial/unavailability remaining
fail-closed with zero dispatch for the attachment payload; and unchanged
result truthfulness (submitted, never delivered). The full existing
`imcp-serverTests` suite passes with a net-zero test-count change (tests
removed for now-obsolete standalone-tool/elicitation behavior are replaced
one-for-one, and in most cases more than one-for-one, by consolidation-specific
coverage).

## What this does not change

This ADR supersedes only ADR 0009's decision to expose a separate public
`messages_send_attachment` tool. It does not supersede, and explicitly
reaffirms unchanged, every security/validation boundary ADR 0009 established:
the mandatory native picker, bounded file validation, security-scoped access
lifetime, destination and file revalidation immediately before dispatch,
fixed-script typed-descriptor dispatch, one-dispatch/no-retry semantics,
privacy redaction, and submitted-not-delivered truthfulness. ADR 0010's
global Sending mode and its accepted exception to ADR 0002's per-submission
confirmation default are also unchanged; this ADR only changes how a caller
reaches the same two already-accepted pipelines.

## References

- ADR 0002, for the confirmation-required default and its accepted Sending-mode
  exception, unaffected by this record
- ADR 0006, for the human-completed new-recipient text path, unaffected
- ADR 0009, superseded for its public-tool-surface decision only; its
  security/validation contract is carried forward unchanged and referenced
  above
- ADR 0010, for the global Sending mode both payload types honor identically
  before and after this consolidation
- `.build/SourcePackages/checkouts/JSONSchema/Sources/JSONSchema/JSONSchema.swift`,
  for the `oneOf`/`anyOf`/`allOf`/`not` constructs considered and not used here
- `App/Services/Messages.swift`, `resolveSendPayload`, `resolveDestination`,
  `sendText`, `sendAttachment`

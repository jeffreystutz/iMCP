# ADR 0012: Split Messages send tools — `message_send_text` and `message_send_attachment`

- Status: Accepted
- Date: 2026-08-16
- Deciders: iMCP maintainers (user)
- Supersedes: ADR 0011 (its public-API decision only; see "What this does not change")
- Superseded by:

## Context

ADR 0011 consolidated the two public tools `messages_send` (text) and
`messages_send_attachment` (picker attachment) into one public `messages_send`
tool accepting exactly one of a `body` or `attachment` payload. That
consolidation was implemented, passed supervising structural/code review, and
passed full automated verification (275/275 tests) — but it was **never
manually accepted**. Before the human runtime checkpoint for that design, the
user explicitly reversed the decision.

The reversal restores the pre-ADR-0011 architecture — two public tools, one
per Messages submission class — under new, final names: `message_send_text`
and `message_send_attachment`. Neither the old plural `messages_send`/
`messages_send_attachment` names nor a unified/legacy alias are retained; no
released compatibility requirement for either is known on this
feature-completion branch.

### Why the split is now intentional

Messages' installed scripting interface (`Messages.sdef`) submits one direct
`send` parameter as either text or file. A body plus attachment therefore
requires two sequential Messages submissions for one approved call, which
introduces partial-success semantics and violates this project's
one-dispatch-per-operation/no-retry invariant — the same platform constraint
ADR 0009 originally identified when it first separated attachment submission
from `messages_send`. ADR 0011's code-level `resolveSendPayload` prevented a
single call from ever expressing both payloads, so it never actually violated
that invariant, but it did embed a payload-selection abstraction — "exactly
one of `body` or `attachment`" — around a platform primitive that only ever
accepts one type per dispatch. The user judged two purpose-named tools, each
mapping directly to one Messages submission class, as the clearer and more
discoverable final public API, and explicitly chose to reverse ADR 0011
before it reached manual acceptance rather than let it stand as shipped
design.

`message_send_text` -> one text submission, or, for a verified-new direct
recipient, the existing human-controlled Messages composition flow.
`message_send_attachment` -> one picker-selected file submission to one
existing conversation. Atomic body + attachment/caption in either tool
remains unsupported; a caption is a separate `message_send_text` call with
its own authorization/submission semantics, exactly as ADR 0009 originally
established.

## Decision drivers

- Material product choices belong to the user: the user explicitly reversed
  ADR 0011's design before it was manually accepted, and that reversal is
  determinative regardless of ADR 0011's passing automated verification.
- One MCP tool per Messages submission class matches the platform's actual
  one-parameter-per-`send` constraint more directly than one tool with an
  internal payload switch.
- The pre-consolidation text tool's missing-body elicitation was safe because
  a missing payload was unambiguous (text was the only payload). Splitting
  the tools removes the two-payload ambiguity ADR 0011 introduced, so that
  elicitation can be restored without reinventing a payload-type-guessing
  mechanism.
- Preserve the already-reviewed internal pipelines (destination resolution/
  revalidation, picker, file validation, Automation/addressability,
  dispatch) and the global Sending-mode wiring exactly, rather than
  rewriting security-sensitive code merely because the public router
  changed again.

## Options considered

### Keep the unified `messages_send` tool (ADR 0011)

Rejected. The user explicitly reversed this decision before manual
acceptance. Passing code review and automated verification established code
completion, not product acceptance (see `engineering/review-and-validation`
in this project's Hexa organization) — a moving branch is not retroactively
accepted merely because later work builds on it.

### Two tools, reusing the prior plural names (`messages_send` / `messages_send_attachment`)

Rejected. The user specified exact new names, `message_send_text` and
`message_send_attachment`; reverting to the old plural names would not match
the settled decision and would blur the boundary between the ADR 0011
experiment and this final architecture in tool-call logs and client caches.

### Two tools, new singular-verb names (`message_send_text` / `message_send_attachment`)

Selected. Matches the user's exact specification. Each name states the one
Messages submission class it maps to.

## Decision

The public Messages send surface is exactly two tools:

- `message_send_text` — exactly one text submission to one destination, or
  human-controlled composition for a verified-new direct recipient. Restores
  the pre-ADR-0011 schema (`recipient`/`recipients`/`chat_id` plus required
  `body`) and the pre-ADR-0011 missing-body MCP form elicitation: a caller
  that supplies a valid destination but omits `body` is asked for it via the
  existing elicitation mechanism; accepting supplies the body but is not
  itself final send authorization, which remains the separate step described
  in ADR 0002/ADR 0010.
- `message_send_attachment` — exactly one picker-selected file submission to
  one existing conversation, unchanged from ADR 0009: destination selectors
  only (`recipient`/`recipients`/`chat_id`), no body/caption/path/source
  argument of any kind, native picker mandatory in both Sending modes.

`messages_send`, `messages_send_attachment`, and any unified/legacy alias are
removed from the public tool list. Both tools continue to read the same
app-owned, live-evaluated `MessagesSendingMode` (ADR 0010): Ask Before
Sending requires the existing final confirmation for an eligible
existing-conversation submission; Send Automatically skips only that
confirmation, never the missing-body elicitation, the picker, or any
revalidation/Automation/addressability step. No caller argument,
elicitation response, client name, build flag, debug path, or environment
variable may enable or override automatic mode.

Internally, `message_send_text` and `message_send_attachment` each parse only
their own schema and call exactly one of the already-reviewed private
pipelines, `sendText`/`sendAttachment`, restored unmodified from the ADR
0011 implementation (which had itself preserved them unmodified from before
consolidation). There is one dispatch call site per tool and no fallback
between them.

## Rationale

Restoring two tools rather than refining the unified design follows directly
from the user's explicit choice; this ADR does not re-litigate whether the
unified design was defensible; on manual review, before acceptance, the user
decided against it. Given that reversal, mapping one tool to one Messages
submission class is the more legible design: `message_send_attachment`'s
schema alone tells a caller it can never carry text, and
`message_send_text`'s schema alone tells a caller it can never carry a file
— neither requires reading a payload-selection rule to understand what a
call can express, and the platform-level one-`send`-parameter constraint no
longer needs to be re-derived from a code comment.

Restoring the missing-body elicitation is not a step backward from ADR
0011's deliberate omission — it is a direct consequence of removing the
ambiguity that omission existed to avoid. With only one payload shape per
tool again, a missing `body` on `message_send_text` has exactly one
reasonable interpretation, exactly as it did before ADR 0011.

## Consequences

### Positive

- Restores the exact previously-reviewed and tested pipelines and the
  pre-consolidation missing-body elicitation UX, none of which needed to be
  redesigned.
- Each tool's schema alone documents what it can and cannot carry.
- Future attachment ingress sources (handoff directory, serialized content)
  extend `message_send_attachment` directly rather than needing a nested
  `attachment.source` namespace inside a shared payload object.

### Negative

- Reintroduces two public tool names instead of one, undoing ADR 0011's
  stated positive of a single discoverable entry point.
- Any caller code written against the brief, never-manually-accepted unified
  `messages_send` window must migrate to the final split names; no alias is
  provided.

### Risks and mitigations

- **Restoring two tools could subtly diverge from the previously accepted
  pipelines instead of reusing them.** Mitigated by restoring `sendText`,
  `sendAttachment`, destination resolution, and revalidation as the same
  code already reviewed for ADR 0011 and, before it, for the original
  standalone tools — only the public tool declarations, the destination/body
  parsing that feeds them, and the removed payload router changed.
- **Restored elicitation could be mistaken for final send authorization.**
  Mitigated identically to the pre-consolidation design: accepting the
  elicitation only supplies `body`; the existing final-confirmation step (or
  Send Automatically's authorized skip of it) still runs afterward for every
  existing-conversation submission, and is covered by dedicated tests.
- **A regression could let one tool reach the other's internal pipeline, or
  reintroduce a payload switch.** Mitigated structurally: each tool's
  closure calls exactly one of `sendText`/`sendAttachment` directly: there is
  no shared payload-resolution function or enum to regress.

## Validation

Automated tests cover: the public tool list contains exactly
`message_send_text` and `message_send_attachment`, and does not contain
`messages_send`, `messages_send_attachment`, or any unified alias; each
tool's exact schema (`message_send_text` exposes destination selectors plus
required `body` and nothing attachment-shaped; `message_send_attachment`
exposes only destination selectors and nothing body/file/mode/bypass-shaped);
missing-body elicitation restored, including decline/cancel/malformed-content
fail-closed with zero submission; Ask Before Sending and Send Automatically
behavior preserved for both tools, including live Sending-mode changes
observed without reinitializing `MessageService`; text and attachment
verified-new-recipient behavior unchanged; picker cancellation, destination
staleness, file change/replacement, and Automation denial/unavailability
remaining fail-closed with zero dispatch for the attachment tool; and
unchanged submitted-not-delivered result semantics. The full existing
`imcp-serverTests` suite passes with the same test count as the last
reviewed pre-consolidation head, since this correction restores rather than
extends that coverage.

## What this does not change

This ADR supersedes only ADR 0011's decision to expose one unified public
`messages_send` tool. It does not revisit, and explicitly reaffirms
unchanged, every security/validation boundary ADR 0009 established for
attachment submission — the mandatory native picker, bounded file
validation, security-scoped access lifetime, destination and file
revalidation immediately before dispatch, fixed-script typed-descriptor
dispatch, one-dispatch/no-retry semantics, privacy redaction, and
submitted-not-delivered truthfulness — nor ADR 0010's global Sending mode and
its accepted exception to ADR 0002's per-submission confirmation default, nor
ADR 0002/ADR 0006's text and verified-new-recipient composition invariants.

ADR 0009's own historical record continues to say "Superseded by ADR 0011";
that supersession chain is left intact rather than rewritten, because it
accurately records what happened. This ADR is a further, later decision: it
restores a separate attachment tool under a new name, `message_send_attachment`,
and independently carries forward ADR 0009's full security/validation
contract, rather than un-superseding ADR 0009 or pretending ADR 0011 never
existed.

## References

- ADR 0002, for the confirmation-required default and its accepted Sending-mode
  exception, unaffected by this record
- ADR 0006, for the human-completed new-recipient text path, unaffected
- ADR 0009, whose public-tool-surface decision this record's predecessor
  (ADR 0011) superseded and this record now effectively restores under a new
  name; its security/validation contract is carried forward unchanged and
  referenced above
- ADR 0010, for the global Sending mode both tools honor identically before
  and after this correction
- ADR 0011, superseded by this record: implemented and code-reviewed, but
  reversed by the user before manual acceptance
- `App/Services/Messages.swift`, `resolveSendInput`, `resolveAttachmentDestination`,
  `sendText`, `sendAttachment`

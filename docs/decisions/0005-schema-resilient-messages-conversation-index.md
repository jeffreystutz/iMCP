# ADR 0005: Schema-resilient Messages conversation index

- Status: Proposed
- Date: 2026-07-21

## Context

Apple's Messages database is private and changes across macOS versions. A
single fixed query makes optional metadata a failure dependency and encourages
misleading approximations when fields are absent. Full conversation aggregates
can also become expensive or leak private content if implemented as an
unbounded join.

## Decision

The conversation index discovers code-selected table, column, and index
capabilities once per read-only connection. It requires only `chat.guid` for
safe identity and represents optional support in `metadataAvailability`.

Queries are staged within one read transaction: a bounded conversation page,
one membership batch, then—only for `detail: full`—one message-metadata batch
and one attachment-metadata batch restricted to the selected chats. SQL
structure uses only code-defined fragments. No content-bearing message or
attachment columns are selected.

Zero, absent, and unsupported values remain distinct. Optional failures disable
their capability group without discarding safe core results. Unknown semantics
remain unavailable; notably, an unseen-mention flag is not treated as a total
mention count. Reaction additions and removals are event counts rather than a
claim about current reaction state.

## Consequences

The API can return useful results from reduced schemas and add verified aliases
without rewriting the service boundary. Full detail is bounded by selected
chats but still scales with their histories, so it has cancellation and a
five-second query deadline. Schema discovery adds small per-call overhead and
is intentionally not cached globally, avoiding stale capabilities and private
content caches.

The result now intentionally contains participant handles and raw Messages
GUID metadata. Logging therefore remains strictly operational and future
side-effecting tools must treat every returned identifier as data requiring
fresh validation, not as authorization or executable input.

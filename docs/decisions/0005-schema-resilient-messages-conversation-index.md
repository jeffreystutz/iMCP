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

Participant identity has exactly one definition, `MessagesHandleIdentity`,
shared by participant counts, direct/group classification, the participant list,
and chat resolution. A trimmed handle is its own identity; a valid E.164 number
keeps its exact form; a syntactically valid email is lowercased; no country code
is inferred and no value is reinterpreted. Several `handle` rows describing one
identity therefore collapse into one participant, so duplicate relationship
rows, letter-case differences, and differing service or country metadata can
neither inflate `participantCount` nor turn a direct conversation into a group.
Multiple metadata observations merge deterministically, exposing the
lexicographically first value plus plural fields when observations differ.

No SQL expression derives participant identity, participant count, or `kind`.
SQLite text folding cannot be made identical to the Swift definition — it folds
case-distinct non-email handles together and does not strip tabs or newlines —
and a lossy SQL predicate can exclude a conversation from one filtered view
while Swift excludes it from the other, so a valid conversation disappears
entirely. Identity is therefore populated only after readable handle text is
fetched and normalized.

Filtered requests scan ordered chat headers in bounded internal pages,
classifying each page authoritatively and keeping only matches, until the
caller's limit is filled or the source is exhausted. There is no total-row cap;
the query deadline and cancellation are the global bound, and either one fails
the request rather than returning a short page that would imply exhaustion.
Source ordering is preserved and full-detail aggregates run only for the finally
selected conversations.

`messages_list_chats` participant filtering uses the same scan and the same
`MessagesHandleIdentity` values. Its predicate is contains-all: every distinct
normalized requested identity must be present, while a conversation may contain
additional participants. It composes with `kind`, applies the caller limit only
after both predicates, and never reads message content. Empty or unusable filter
identities are invalid input. If readable participant identity is unavailable,
participant-filtered requests fail with a stable unavailable stage rather than
returning an incomplete empty result.

Where readable participant handles are unavailable, participant identity,
participant count, and `kind` are reported unavailable and a filtered request
fails with the stable `kind-unavailable` stage. Nothing is inferred from
`handle_id` or any other relationship row ID, which identifies a database row
rather than a remote person.

Send matching keeps a stricter rule that accepts only valid E.164 or a
syntactically valid email, because a destination must be comparable exactly. A
stored participant that fails it makes matching incomplete when it could still
denote the request, rather than being silently ignored.

The result now intentionally contains participant handles and raw Messages
GUID metadata. Logging therefore remains strictly operational and future
side-effecting tools must treat every returned identifier as data requiring
fresh validation, not as authorization or executable input.

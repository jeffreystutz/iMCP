# ADR 0007: Reusable search operations behind thin MCP adapters

- Status: Proposed
- Date: 2026-08-09
- Updated: 2026-08-10 with the delivered composite and its service gating

## Context

Answering "text Carolyn" needs contact candidates, the conversations those
candidates already have, a semantic judgment about who was meant, and finally an
exact send. Contacts search and conversation lookup both lived inside MCP tool
closures, so a cross-service reader could only reach them by re-implementing
their predicates or by recursively invoking MCP tools.

An earlier proposal, `messages_match_recipients`, would have exposed the send
matcher's internal `unique` / `none` / `ambiguous` / `incomplete` states as the
public model for finding people. Those states are good send-safety semantics and
a misleading discovery model: `unique` means one handle mapped to one direct
conversation, but reads as "this is unambiguously the right person".

## Decision

Four responsibilities stay separate. Contacts finds people, Messages finds
conversations, the LLM interprets identity and destination, and `messages_send`
acts on one exact destination.

Business logic moves behind reusable domain operations, with MCP tools as thin
adapters over them:

- `ContactSearching` / `CNContactStoreSearch` under `contacts_search`;
- `MessagesConversationSearching` / `SQLiteMessagesChatRepository` under the new
  `messages_find_conversations`.

`messages_find_conversations` takes exact E.164 or email handles and returns, per
handle, the conversations containing it plus a `lookupCompleteness` of `complete`
or `incomplete`. It returns no rank, confidence, recommended recipient, or send
routing state, and it never rewrites a supplied handle.

A reusable operation may expose only the facts its own public tool returns.

### The composite

One read-only convenience tool, `contacts_find_conversations`, composes those two
operations literally. It calls contact search once, reads only the exact phone
and email identities the returned contacts already publish, calls the
conversation lookup once across the distinct identities, and joins the answers
back to every contact that carried each one.

Its invariant is that it adds packaging, not interpretation: the same primitive
facts can be reproduced through the public tools and joined outside the server.
Because `messages_find_conversations` accepts at most 20 handles per call, a
client may need to batch identities across multiple calls to reproduce a wide
composite result.

It adds no rank, confidence, recommended person, contact-method selection,
conversation selection, destination, or send behavior; it forwards the three
contact criteria unchanged; and it skips a stored value that is not already an
exact Messages input rather than inferring a country code or rewriting digits.

A contact with no exact identity means no lookup runs at all: the contact comes
back with an empty identity list and `metadataAvailability` is `null`. A Messages
source failure, or a lookup that does not return a per-handle result for every
requested identity, fails the call. A returned identity with
`lookupCompleteness: incomplete` is valid and preserved unchanged. Unavailable
evidence is never rendered as `conversations: []`, which would read as verified
absence.

The Messages seam the composite depends on, `MessagesConversationLookup`, is the
service's complete lookup including its directory-scoped database access, not the
path-taking search. A cross-service reader therefore cannot open the Messages
database its own way or obtain access the Messages service would not obtain
itself.

### Tool-level service dependencies

A tool is gated by the service that owns it. A tool that also reads a second
service's data names that service in `requiredServiceIDs`, and the server
advertises and runs it only while every named service is enabled.

`contacts_find_conversations` belongs to Contacts and names Messages. Attaching
it to one service alone would have made enabling that service a way around the
user's disabled setting for the other.

## Rationale

Conversation objects are the honest answer to "what conversation context exists
for this identity", and they let the model reason about direct and group context
itself rather than trusting a collapsed verdict. Keeping completeness separate
from the conversation list preserves the one guarantee that matters: an empty
list means verified absence only when the comparison was exact.

Protocol-backed seams let the production implementations be shared by the
composite while tests inject fakes, without a second Contacts predicate set or a
second Messages database reader. Restricting an operation to its tool's facts
keeps the composite reproducible from the primitives plus a mechanical join; a
composite that reasoned from richer hidden data would be a new source of truth
wearing a convenience label.

The composite exists because the alternative is expensive rather than because it
knows anything extra: a client that wants a person's conversations otherwise
issues one contact search and then one conversation search per candidate. Keeping
it literal means it can never quietly become the place where the server decides
who the user meant.

Dependency metadata rather than a name-based special case keeps the gate general.
The server keeps one rule — a tool runs only while every service it reads is
enabled — instead of learning about this particular tool, and a tool that
declares no dependency is gated exactly as it was before.

## Consequences

### Positive

- A cross-service reader calls both operations directly, in order, without MCP
  recursion or duplicated logic.
- Contact search, conversation search, and the composite are all testable
  without a real `CNContactStore` or a real Messages database.
- Send-safety semantics stay private to sending.
- A tool that reads two services can no longer bypass either service's setting.

### Negative

- Three protocols and two more public tools to maintain.
- Conversation discovery scans the conversation index rather than a targeted
  query, because completeness cannot be established from a partial scan.
- The composite's identity list is bounded by the matching contacts rather than
  by an explicit cap, so a very broad contact query fans out further than a
  hand-written `messages_find_conversations` call, which accepts at most 20
  handles. The query count still follows index size rather than handle count.

### Risks and mitigations

- A reader could mistake `incomplete` with no conversations for absence. The
  tool description, the schema, and the documentation all state that it is not.
- A reader could mistake an empty identity list or a `null`
  `metadataAvailability` for "this contact has no conversations". Both mean no
  exact identity was available to look up, and the tool description says so.
- Group evidence could be mistaken for a group destination. Groups are returned
  with their participants and no destination is selected; sending still requires
  an exact destination supplied to `messages_send`.

## Validation

Tests cover input validation before any query, direct and group evidence,
per-handle independent limits and truncation, ordering against the conversation
index's own order, completeness for a stored non-E.164 phone format, failure
rather than false completeness on an unsupported schema, absence of raw database
identifiers in the result, delegation from both adapters to their operations,
and a query count that does not grow with the number of requested handles.

For the composite they additionally cover raw criterion forwarding, limit
rejection before either source is touched, the preserved criterion-free contact
error, unchanged contact order, phone-before-email identity order, normalization
and first-occurrence deduplication, unusable values skipped rather than inferred,
exactly one conversation lookup regardless of contact and identity count, a
shared identity looked up once and reported under every contact, unchanged
completeness, truncation, conversation, and availability facts, no lookup when no
exact identity exists, propagation of both a Contacts failure and a Messages
failure, an unanswered identity failing rather than becoming empty evidence, the
public schema and annotations, an end-to-end read through the real Messages
access path with sending and elicitation wired to fail, both gating surfaces,
unchanged primitive tool contracts, and count-only telemetry and value-free
errors.

## References

- [`docs/messages-conversation-search.md`](../messages-conversation-search.md)
- [ADR 0003](0003-opaque-messages-chat-identifiers.md)
- [ADR 0005](0005-schema-resilient-messages-conversation-index.md)

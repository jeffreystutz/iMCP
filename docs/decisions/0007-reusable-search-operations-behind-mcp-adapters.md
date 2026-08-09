# ADR 0007: Reusable search operations behind thin MCP adapters

- Status: Proposed
- Date: 2026-08-09

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

## Rationale

Conversation objects are the honest answer to "what conversation context exists
for this identity", and they let the model reason about direct and group context
itself rather than trusting a collapsed verdict. Keeping completeness separate
from the conversation list preserves the one guarantee that matters: an empty
list means verified absence only when the comparison was exact.

Protocol-backed seams let the production implementations be shared by a future
composite while tests inject fakes, without a second Contacts predicate set or a
second Messages database reader. Restricting an operation to its tool's facts
keeps a composite reproducible from the primitives plus a mechanical join; a
composite that reasoned from richer hidden data would be a new source of truth
wearing a convenience label.

## Consequences

### Positive

- A cross-service reader can call both operations directly, in order, without
  MCP recursion or duplicated logic.
- Contact search and conversation search are testable without a real
  `CNContactStore` or a real Messages database.
- Send-safety semantics stay private to sending.

### Negative

- Two protocols and one more public tool to maintain.
- Conversation discovery scans the conversation index rather than a targeted
  query, because completeness cannot be established from a partial scan.

### Risks and mitigations

- A reader could mistake `incomplete` with no conversations for absence. The
  tool description, the schema, and the documentation all state that it is not.
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

## References

- [`docs/messages-conversation-search.md`](../messages-conversation-search.md)
- [ADR 0003](0003-opaque-messages-chat-identifiers.md)
- [ADR 0005](0005-schema-resilient-messages-conversation-index.md)

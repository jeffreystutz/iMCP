# Messages conversation search

`messages_find_conversations` is a read-only lookup that answers one question:

> Given exact phone or email handles, which existing Messages conversations is
> each of them part of?

It never reads message bodies or attachment names, never invokes Apple Events,
never requests Contacts or Automation authority, and never sends anything.

## Where it sits

Four responsibilities stay separate:

1. **Contacts finds people.** `contacts_search` returns contact records and the
   communication identities stored for them.
2. **Messages finds conversations.** `messages_find_conversations` turns exact
   identities into the conversations that contain them.
3. **The LLM interprets.** It combines contact candidates, conversation
   evidence, and conversational context to decide who was meant and which
   contact method to use, and asks the user when that stays ambiguous.
4. **`messages_send` acts** on one exact destination.

Conversation evidence is not proof of identity. The only same-name contact with
an open thread is not automatically the intended person, and this tool
deliberately returns no rank, confidence, score, or recommended recipient.

`messages_list_chats` remains the broad conversation-index listing surface and
its participant filter is unchanged. `messages_find_conversations` is the
handle-oriented view over the same index: several identities in one request,
each with its own result.

## Reusable operations behind thin adapters

The MCP tools are adapters. The logic lives in reusable domain operations so a
later cross-service reader can call the same code without invoking MCP tools,
duplicating Contacts predicates, or opening the Messages database a second way:

| Operation | Production implementation | MCP adapter |
| --- | --- | --- |
| `ContactSearching` | `CNContactStoreSearch` | `contacts_search` |
| `MessagesConversationSearching` | `SQLiteMessagesChatRepository` | `messages_find_conversations` |

Each operation exposes exactly the facts its public tool returns, so a composite
built on them can never reason from richer hidden data than a client could
obtain by calling the two tools itself. Both seams accept fakes, so tests
exercise them without a real `CNContactStore` or a real Messages database.

## Input

- `handles`: required array of 1 to 20 exact communication handles. Each must be
  strict E.164 (`+` followed by 1–15 digits, no leading zero) or a
  syntactically valid email address. Emails normalize to lowercase; nothing
  else is rewritten. No country code is inferred, no local phone format is
  converted to E.164, and no digit-suffix rewriting occurs.
- `limit`: optional integer from 1 through 25, default 10. It bounds the
  conversations returned **per handle**, so one very active identity cannot
  consume another identity's budget.

Every input is validated before the database is opened. One invalid element
fails the whole request, no query runs, and the rejected value never appears in
the error. Duplicate handles are one unit of work internally and keep every
supplied position in the result.

The handle bound is sized for the fan-out of a single contact search — a few
candidate people, each with a few numbers and addresses — not for bulk export.

## Result

- `metadataAvailability`: booleans for the fields a conversation summary can
  carry, using the same semantics as the conversation index. `false` means the
  opened schema cannot support that field reliably, which is different from a
  supported field being absent.
- `results`: one entry per supplied handle, in the supplied order. The tool
  never reorders, ranks, or deduplicates the requested handles.

Each result carries:

- `handle`: the normalized exact handle that was looked up.
- `lookupCompleteness`: `complete` or `incomplete` (below).
- `truncated`: `true` when more safely matched conversations existed than the
  per-handle limit returned.
- `conversations`: matching conversations, newest first.

### Lookup completeness

`lookupCompleteness` is a read-data-quality concept. It is unrelated to the
internal unique/none/ambiguous/incomplete states `messages_send` uses to decide
whether a send is safe, and it must not be read as a send decision.

- `complete`: every stored participant identity relevant to this handle was
  exactly comparable. `complete` with `conversations: []` means no conversation
  matched.
- `incomplete`: at least one stored participant identity could plausibly denote
  this handle but cannot be interpreted exactly — a phone number kept in a local
  format, for instance, which no country code may be inferred to resolve. Such a
  row is never rewritten and never claimed as a match. Conversations that did
  match exactly are still returned, but others may be missing, so `incomplete`
  with `conversations: []` is **never** verified absence.

Completeness is tracked per handle: one handle's uncertainty does not
contaminate another's.

If the opened schema cannot supply readable participant handle text at all, the
whole call fails rather than reporting every handle as `complete` with no
conversations.

`truncated` is independent of completeness. `complete` with `truncated: true`
means the interpretation was exact and the result count was intentionally
bounded; `incomplete` with `truncated: false` means everything safely identified
was returned while uncertain matches may remain.

### Conversation summary

Deliberately smaller than a `messages_list_chats` record:

- `chatId`: the opaque public chat identifier, the same value `messages_send`
  accepts. No raw chat GUID, `chat_identifier`, room name, group ID, or SQLite
  ROWID is exposed.
- `kind`: `direct` or `group`, from the same normalized-identity rule the
  conversation index uses.
- `displayName`: the conversation's stored name, or the index's synthesized
  name for a direct conversation.
- `participants`: the remote participants, one per remote identity, in the
  index's deterministic order and representation.
- `service`: the service recorded on the conversation, when supported.
- `latestActivity`: ISO-8601 latest activity, when supported.

Message bodies, attachment names and paths, account credentials, and history
aggregates are never included.

### Groups are evidence, not a destination

If a handle appears in one direct thread and three groups, all four are returned
within the per-handle limit, and group participants come back so the context is
legible. That a candidate shares a group with someone does **not** mean a later
request to message that candidate should target the group. The tool selects no
destination; a caller that wants to send still supplies one exact destination to
`messages_send`.

## Ordering

Within each handle's `conversations`, ordering is the conversation index's own:
descending latest activity, conversations without activity last, with the
internal database ordering key as the deterministic tie-breaker. That key is
never returned. This is conversation recency, not a ranking of people.

## Query shape

One read transaction performs schema discovery, then walks the conversation
index in bounded pages — one header query and one batched membership query per
page — classifying every conversation once for all requested handles. Matching,
completeness, per-handle sorting, truncation, and duplicate re-expansion all
happen in memory afterwards.

The number of database queries follows the size of the conversation index, never
the number of requested handles: searching for eight handles issues exactly the
same queries as searching for one. There is no per-handle query and no N+1 scan.

The pass runs to exhaustion rather than stopping once every handle's limit is
filled, because stopping early could miss a stored identity that makes a
handle's lookup `incomplete`. The five-second query deadline and cancellation
remain the global bound, and a timeout fails the call rather than returning a
partial answer.

## Privacy

The tool uses the existing read-only, directory-scoped Messages database access
and adds no permission, entitlement, or TCC authority.

Production logging records only the number of requested handles, the number of
returned conversations, elapsed time, stable stage names, and numeric SQLite
codes. Handles, participants, chat identifiers, conversation names, and result
objects are never logged, and no error message carries a private value.

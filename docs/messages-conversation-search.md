# Messages conversation search

`messages_find_conversations` is a read-only lookup that answers one question:

> Given exact phone or email handles, which existing Messages conversations is
> each of them part of?

It never reads message bodies or attachment names, never invokes Apple Events,
never requests Contacts or Automation authority, and never sends anything.

`contacts_find_conversations` is the read-only convenience tool over it and
`contacts_search`, described in [Contact conversation
composition](#contact-conversation-composition) below.

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
| `MessagesConversationLookup` | `MessageService` | — |
| `ContactConversationSearch` | `ContactSearching` + `MessagesConversationLookup` | `contacts_find_conversations` |

Each operation exposes exactly the facts its public tool returns, so a composite
built on them can never reason from richer hidden data than a client could
obtain by calling the two tools itself. Every seam accepts fakes, so tests
exercise them without a real `CNContactStore` or a real Messages database.

`MessagesConversationSearching` searches a database path its caller already
resolved. `MessagesConversationLookup` is the complete lookup — resolve the
directory-scoped bookmark, then run that same search — and it is what the
composite depends on, so no second reader opens the Messages database its own
way or acquires access the Messages service would not have acquired itself.

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

## Contact conversation composition

`contacts_find_conversations` is the one read-only convenience tool over the two
primitives. It is literal by construction:

> The composite returns the same facts you would get by calling
> `contacts_search`, taking the exact identities those contacts already publish,
> calling `messages_find_conversations` once over them, and joining the two
> results yourself.

It calls the reusable operations directly. It never invokes an MCP tool, never
keeps a second set of Contacts predicates or Messages matching rules, and never
reads richer contact data than `contacts_search` returns.

### Input

- `name`, `phone`, `email`: the same optional raw criteria as `contacts_search`,
  forwarded unchanged. None is required by the schema; the contact-search
  operation still rejects a query with no usable criterion, with the same
  message it has always used.
- `limit`: optional integer from 1 through 25, default 10, applied **per exact
  identity** — it is the per-handle limit of the conversation search.

The limit is the one input this adapter owns, and it is validated before either
source is touched, so a malformed request never becomes a contact query or a
database read.

### Composition

1. Call the contact-search operation once.
2. Keep every returned contact unchanged and in the order the operation returned
   it. The composite selects no person.
3. For each contact, read only the public `telephone` values followed by the
   public `email` values, in their stored order, and normalize each with the same
   rule `messages_find_conversations` applies. Values that are not already exact
   Messages inputs are skipped, never repaired: no country code is inferred, no
   local number is rewritten, no Contacts label is consulted. Repeats collapse to
   their first occurrence.
4. Build one distinct handle list in contact order, then identity order.
5. If that list is non-empty, call the conversation lookup exactly **once**, and
   join each per-handle answer back to every contact that carried the identity.
   An identity two contacts share is looked up once and reported under both;
   contacts are never collapsed and one is never chosen over another.

### Result

- `metadataAvailability`: the conversation search's own dictionary, or `null`
  when no contact published an exact identity, so Messages was never consulted.
  `null` means no lookup ran; it never means a lookup came back empty.
- `results`: one entry per returned contact, in contact order, each carrying the
  unchanged `contact` record and its `identities`.
- Each identity entry is the unchanged per-handle fact set described above:
  `handle`, `lookupCompleteness`, `truncated`, and `conversations`.

There is no rank, score, confidence, recommended person, chosen contact method,
chosen conversation, destination, transport, send state, or authorization state.
A contact whose stored values are all unusable comes back with an empty
`identities` list, which says the contact publishes no exact identity — not that
it has no conversations.

If the conversation lookup fails, or answers for fewer identities than it was
given, the whole call fails. Unavailable conversation evidence is never rendered
as `conversations: []`, because that reads as verified absence.

The lookup is bounded only by the number of exact identities the matching
contacts publish. `messages_find_conversations` caps a client-supplied request at
20 handles; the composite's list comes from the user's own contacts rather than
from the client, and the underlying query count follows the size of the
conversation index rather than the number of handles.

## Service enablement

The composite reads two independently enabled services, so it is advertised and
callable only while **both** Contacts and Messages are enabled.

The server gates each tool by its owning service. A tool may additionally name
services it depends on through `requiredServiceIDs`, and the server requires
every one of them before advertising or running it. `contacts_find_conversations`
belongs to Contacts and names Messages, so enabling Contacts never becomes a way
around a disabled Messages setting, and disabling Messages hides and disables the
composite without affecting any other Contacts tool. Every other tool declares no
dependency and is gated exactly as before.

Disabling a dependency also stops a client that still holds an earlier tool
listing: the call returns the same "tool not found or service not enabled"
answer it would get for a tool whose own service is off, and nothing runs.

## Privacy

Both tools use the existing read-only, directory-scoped Messages database access
and add no permission, entitlement, or TCC authority.

Production logging records only counts, elapsed time, stable stage names, and
numeric SQLite codes: the number of requested handles and returned conversations
for `messages_find_conversations`, and the number of contacts, identities, and
conversations plus whether Messages was consulted for
`contacts_find_conversations`. Names, stored contact values, handles,
participants, chat identifiers, conversation names, and result objects are never
logged, and no error message carries a private value.

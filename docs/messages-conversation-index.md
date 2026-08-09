# Messages conversation index

`messages_list_chats` is a read-only index of existing Apple Messages
conversations. It never reads message bodies or attachment names and never
invokes Apple Events.

## Input

- `limit`: optional integer, default `30`, range `1...100`.
- `kind`: optional `direct` or `group` membership-count filter.
- `detail`: optional `summary` (default) or `full`.

`summary` performs schema discovery, one bounded chat-page query, and one
batched membership query. `full` adds one batched message-metadata query and
one batched attachment-metadata query, each restricted to the returned chats.
There are no per-chat queries. Pagination is not currently exposed; adding a
cursor requires a stability design for concurrent Messages updates.

## Top-level result

- `detail`: the requested detail level.
- `metadataAvailability`: booleans describing whether the opened schema can
  support each field or aggregate with the documented semantics.
- `chats`: conversation records in descending latest-activity order, with
  chats lacking activity last and an internal database ordering key as the
  deterministic tie-breaker. That internal key is never returned.

The value conventions are:

- `0` or `false`: the schema supports the metric and no matching records exist.
- `null`: a supported value is absent, or a full metric is unavailable; consult
  `metadataAvailability` to distinguish those cases.
- `metadataAvailability[field] == false`: iMCP cannot derive that field
  reliably from the opened schema.

Every returned timestamp is an ISO-8601 string. Message-family and chat-join
timestamps are decoded from nanoseconds since Apple's 2001 reference date;
`attachment.created_date` is decoded from seconds since that reference date.
The repository uses these verified column-specific units and does not infer a
unit from a value's magnitude.

## Summary conversation fields

- `id`: preserved compatibility name for the opaque public chat ID.
- `chatId`: the same opaque public ID, explicitly named for future tool input.
- `chatGuid`: Messages' database chat GUID. This is returned metadata, not SQL,
  AppleScript, or authorization.
- `chatIdentifier`, `groupId`, `originalGroupId`, `roomName`, `displayName`:
  nullable database metadata when the corresponding column exists.
- `kind`: `group` when more than one distinct remote *identity* is present,
  otherwise `direct`; unavailable if membership joins are unavailable.
- `participants`: deterministically sorted remote participants, one per remote
  identity. It is `[]` for a supported empty relationship and `null` when the
  membership relationship is unavailable.
- `participantCount`: the number of returned remote participants; it excludes
  the current user. Phone and email handles remain separate identities.
- `service`: nullable service recorded on the chat.
- `isArchived`, `isFiltered`: nullable booleans when supported. Screened state
  is reported unavailable because the inspected schema's pending-review and
  blackhole columns have not been verified as equivalent user-visible state.
- `lastReadTimestamp`: nullable Apple-reference timestamp when supported.
- `latestActivity`: newest chat/message-join activity timestamp when supported.

### Participant identity

One definition of remote-handle identity governs participant counts,
direct/group classification, the participant list, and chat resolution, so
these can never disagree:

1. The stored handle is trimmed of surrounding whitespace.
2. A valid E.164 number is its own identity, exactly as stored.
3. A syntactically valid email is lowercased.
4. Any other nonempty handle is its own identity, exactly as trimmed. No
   country code is inferred and no value is reinterpreted.
5. A missing or empty value creates no participant.

Several `handle` rows can therefore describe one identity — duplicate
relationship rows, an email stored with different letter case, or the same
handle observed on more than one service. They collapse into a single
participant, so they cannot inflate `participantCount` or turn a direct
conversation into a group.

Each participant contains `handle` (the identity), nullable `originalHandle`,
`canonicalE164`, `email`, `service`, and `country`. `canonicalE164` is populated
only when the identity strictly matches `+` followed by 2–15 digits with a
nonzero country-code digit; `email` only for an unmistakable email-shaped
identity.

When one identity was observed with differing metadata, `originalHandle`,
`service`, and `country` carry the lexicographically first observed value so
output is deterministic, and the optional `originalHandles`, `services`, and
`countries` arrays list every distinct observed value sorted. Those arrays are
omitted when only one value was observed.

A direct chat whose supported membership is empty may use `chatIdentifier` only
when it independently passes the E.164 or email validator. Message senders are
never scanned for ordinary membership.

No SQL expression derives participant identity, participant count, or `kind`.
SQLite's `LOWER` and `TRIM` cannot reproduce the rules above — they fold
case-distinct non-email handles together and do not strip tabs or newlines — so
any SQL predicate would silently drop conversations before Swift could classify
them.

A `kind`-filtered request therefore scans ordered chat headers in bounded
internal pages. Each page has its participants fetched and normalized, is
classified authoritatively, and contributes only its matching conversations.
Scanning continues until the caller's `limit` is filled or the source is
exhausted; there is no total-row cap. The five-second query deadline and
cancellation are the only global bound, and hitting either fails the request
rather than returning a short page that would falsely imply no further matches
exist. Matching conversations keep their unfiltered source order, and expensive
full-detail aggregates run only for the finally selected conversations, never
for scanned-and-rejected pages.

A reduced schema without readable `handle.id` text cannot provide participant
identity at all: `participants`, `participantCount`, and `kind` are reported
unavailable, an unfiltered listing still returns the remaining chat metadata,
and a `kind`-filtered request fails with the stable `kind-unavailable` stage.
Participant identity is never inferred from `handle_id` or any other
relationship row ID, because a relationship row identifies a database row, not a
remote person.

## Full metadata

`full` is nested under each chat's `full` key:

- `latestActivity`: latest joined activity with a stable message GUID,
  timestamp, direction, service, attachment presence, and reliable delivery
  state when available.
- `latestIncomingMessage` / `latestOutgoingMessage`: latest user-visible base
  message in each direction with the same compact fields.
- `messageCount`: distinct user-visible base messages. Base messages require
  non-system, non-service, non-empty rows with `item_type == 0` and no
  associated-message event type.
- `incomingMessageCount` / `outgoingMessageCount`: base messages partitioned by
  `is_from_me`.
- `unreadIncomingCount`: incoming base messages with `is_read == 0`; outgoing
  messages never count as unread.
- `failedOutgoingCount`: outgoing base messages with nonzero `error` and
  `is_finished == 1`. Pending or ambiguous rows do not count as failed.
- `hasAttachments`, `attachmentCount`, `messagesWithAttachmentsCount`: distinct
  attachment joins and distinct parent messages. Duplicate joins do not inflate
  counts.
- `latestAttachmentTimestamp`: newest supported attachment creation timestamp,
  decoded from the attachment column's Apple-reference seconds.
- `attachmentCountByMediaCategory`: MIME-prefix categories `image`, `video`,
  `audio`, `text`, `application`, and `other`. Filenames are never consulted.
- `stickerAttachmentCount`: distinct attachments explicitly marked as stickers
  by the installed schema.
- `replyCount` / `latestReplyTimestamp`: base messages with a nonempty
  `reply_to_guid`.
- `reactionEventCount`, `reactionAddCount`, `reactionRemoveCount`, and
  `latestReactionEventTimestamp`: event rows using verified Messages
  standard-and-custom associated reaction ranges 2000–2006 (add) and
  3000–3006 (remove). These are event counts, not current reaction state.
- `editedMessageCount` / `latestEditTimestamp`: distinct base-message GUIDs
  with `date_edited`; duplicate joins or history rows do not inflate the count.
- `retractionCount` / `latestRetractionTimestamp`: base messages with
  `date_retracted`.
- `mentionCount`: currently unavailable. The inspected schema exposes only an
  unseen-mention flag, not a reliable total mention count.
- `expressiveEffectMessageCount`: base messages with a nonempty
  `expressive_send_style_id`.
- `pluginMessageCount`: base messages with a nonempty `balloon_bundle_id`.

Compact message records expose `messageGuid`, never a message row ID. Delivery
state is `received` for incoming records; outgoing records are `failed` only
for a finished nonzero error, then `delivered`, `sent`, `pending`, or `unknown`
according to the available status columns. This reports database state, not a
new delivery claim.

## Schema resilience

`MessagesSchemaCapabilities` inspects only code-selected tables with
`PRAGMA table_info` and `PRAGMA index_list` once per opened read-only
connection. Query fragments are selected exclusively from code-defined column
names; caller input is never interpolated into SQL structure. The connection
uses `SQLITE_OPEN_READONLY`, `PRAGMA query_only = ON`, a consistent deferred
read transaction, a one-second busy timeout, and a five-second progress-handler
deadline/cancellation check.

The schema opened during development verified the modern columns documented
above. Synthetic fixtures verify a modern schema, a reduced schema, a schema
without membership, and a variant without `chat_message_join.message_date`.
That variant uses the verified `message.date` fallback. No other similarly
named aliases are treated as equivalent without evidence. Optional query
failures degrade the affected capability group and emit only a stable stage
code; missing `chat.guid` fails the tool because no safe identity remains.

## Identifier stability and privacy

`chatId`/`id` is `imcp-chat-v1_` plus a base64url HMAC-SHA256 of `chat.guid`
under a random app-local key. It resolves only by validation and exact
re-derivation against current chat GUIDs. It is deterministic across MCP
reconnects and iMCP restarts while the key and GUID remain. Clearing defaults
or reinstalling rotates the key. Stability across Messages.app restarts,
macOS reboots, and database migrations remains unverified and is not promised.
Raw row IDs are internal batching keys and are never returned.

Chat IDs identify conversations. `messageGuid` identifies a message record;
neither is authorization for a side effect. `messages_send` validates and
resolves a chat ID before confirmation and again immediately before its
separately authorized existing-chat submission. It may also resolve one raw
handle to an exact direct membership or an unordered complete handle set to an
exact group membership. These comparisons use a stricter rule than listing identity: only a
verified E.164 value or a syntactically valid lowercased email may be matched,
because a destination must be comparable exactly. They never infer country
codes, merge phone and email identities, scan message senders, or accept subset
or superset group matches.

A stored participant that fails that stricter rule makes matching *incomplete*
rather than being ignored, whenever it could still denote a requested
participant — a phone number kept in a local or formatted style, for example.
An incomplete result dispatches nothing and reports a dedicated error asking for
an explicit `chat_id`; for a single recipient it must never be reinterpreted as
a verified no-match, which would abandon an existing SMS or RCS conversation and
start a new one on a different route. A stored handle that could not denote any
requested participant, such as a short code, stays a plain no-match. Future reply, reaction, edit,
or retraction tools must apply the same fresh-validation rule to the relevant
identifier.

The result intentionally returns handles and conversation identifiers: they are
what the caller asked for, and the permission alert shown before access says so
explicitly. That intent does not extend to incidental exposure. Logs contain
only detail level, count, elapsed time, and stable diagnostic stages or numeric
SQLite codes. They never contain result objects, handles, names, GUIDs,
attachment metadata, SQL, or database rows.

The opaque chat ID provides versioning, validation, and concealment of the
underlying GUID representation. It is not an access control and does not make
the other intentionally returned conversation metadata confidential.

## Handle-oriented discovery

`messages_find_conversations` is the sibling read tool for the question "which
conversations is each of these exact identities part of?". It reuses this
index's paging, participant identity, ordering, opaque identifiers, and
metadata-availability semantics rather than defining a competing identity model,
and returns a smaller conversation summary plus a per-handle lookup-completeness
signal. See [`messages-conversation-search.md`](messages-conversation-search.md).

This tool's participant filter is unchanged by that addition: it still returns
conversations containing *every* supplied identity, and gained no OR semantics.

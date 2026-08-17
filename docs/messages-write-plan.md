# Messages write support plan

## Status

This document records the approved architecture and delivery sequence for safe
Apple Messages write support. Generic form elicitation and the narrow direct
send implementation are combined on the working branch. Track B succeeded
locally. Verified repository facts remain separate from unresolved upstream
distribution questions.

The conversation index supports optional participant discovery with contains-all
semantics over `MessagesHandleIdentity`: every requested identity must be present,
additional conversation participants are allowed, and `kind` composes with the
same complete bounded-page scan.

Attachment submission to an existing conversation is implemented as its own
public tool, `message_send_attachment` (ADR 0009, carried forward by ADR
0012 and ADR 0013), with a native file picker instead of any path-bearing
argument. That picker remains a deliberately temporary ordinary-attachment
ingress mechanism: the user has already decided that ordinary attachment
submission should eventually be programmatic (a persistent user-approved
filesystem root with staging, plus bounded serialized content), with the
picker retained only for Settings/onboarding grants. That redesign is future
work with its own UX/security/entitlement acceptance boundary; see Hexa
project knowledge `imessage-mcp/attachment-sending-design` for the settled
direction.

Contact search and conversation search now sit behind reusable domain operations
with thin MCP adapters, and `messages_find_conversations` returns per-handle
conversation evidence. The literal cross-service composite over those operations,
`contacts_find_conversations`, is implemented and is advertised and callable only
while both the Contacts and Messages services are enabled.

A global, binary Messages sending mode (Ask Before Sending / Send Automatically)
and its Settings UI are implemented and manually accepted (ADR 0010, now
Accepted), replacing an earlier four-category design that failed manual UX
acceptance. Existing-conversation plain-text sending honors this mode and
passed its own real-runtime manual checkpoint; picker-based attachment
sending now honors it too, pending its own manual checkpoint.
Verified-new-recipient composition remains unaffected by the mode for either
tool.

The public Messages send surface briefly became one unified `messages_send`
tool (ADR 0011), implemented and code-reviewed but never manually accepted;
the user reversed that design before the runtime checkpoint. The public send
surface is now, and is intended to remain, exactly two tools:
`message_send_text` and `message_send_attachment` (ADR 0012). ADR 0012's own
shipped-but-not-fully-accepted destination-field shape (separate `recipient`/
`recipients` properties) and its restored missing-body elicitation were in
turn rejected at the 2026-08-17 manual checkpoint and corrected by ADR 0013:
both tools now accept one `recipients` property (scalar or array), and
`message_send_text.body` is required with no elicitation. The deferred
picker-attachment manual checkpoint carries forward against
`message_send_attachment` in its current schema shape. See "Automatic-send
authorization policy" and "Attachment submission" below.

## Verified baseline

- The app and CLI target macOS 15.1 and build in Swift 5 language mode.
- The shared schemes are `iMCP` and `imcp-serverTests`; the project targets are
  `iMCP`, `imcp-server`, and `imcp-serverTests`.
- A Debug app build, the three CLI tests, and strict Swift format lint pass with
  DerivedData and packages under `.build/`.
- Debug builds are ad-hoc/linker signed and do not exercise the app's effective
  sandbox or TCC entitlements.
- A Release build requires maintainer signing assets that are not available
  locally.
- MCP Swift SDK 0.12.0 is pinned. It supports form and URL elicitation, but iMCP
  currently has no per-tool access to the active MCP connection.

Reproduce the baseline with:

```sh
xcodebuild -project iMCP.xcodeproj \
  -scheme imcp-serverTests \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  test

xcodebuild -project iMCP.xcodeproj \
  -scheme iMCP \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution \
  build

swift format lint --strict --recursive .
```

## Existing request flow

```text
MCP client
  <-> stdin/stdout
bundled imcp-server StdioProxy
  <-> local Bonjour NWConnection
per-connection MCP.Server in iMCP
  -> tools/list or tools/call
  -> enabled ServiceRegistry service
  -> Service.call
  -> Tool closure
  -> Value
  -> CallTool.Result
```

Tools are declared by services, registered through `ServiceRegistry`, and
listed or called by handlers in `ServerNetworkManager`. The CLI is a
bidirectional byte proxy and writes logs to stderr. A server-originated
`elicitation/create` request therefore has a viable transport path, but PR 1
must cover the complete round trip through the production proxy.

## Parallel tracks

### Track A: generic form elicitation

PR 1 adds an explicit per-call context. The context owns a requester bound to
the MCP server and capabilities for the connection that invoked the tool.
Existing argument-only tools remain source compatible. The first PR implements
form mode only, treats an empty elicitation capability as form support, and
fails before emitting a request when form mode is unsupported.

URL mode is intentionally deferred. No requester is stored globally, in a
service singleton, or in task-local state.

### Track B: local Messages automation experiment

All experiment assets remain under `.build/experiments/messages-write/`.
Using an Apple Development identity and a stable local bundle identifier, the
experiment must verify:

1. A sandboxed app can be signed with the automation entitlement, a temporary
   Apple Events exception for `com.apple.MobileSMS`, and an Apple Events usage
   description.
2. The app and nested CLI signatures and effective entitlements are correct;
   the CLI must not receive Messages automation authority.
3. `AEDeterminePermissionToAutomateTarget` can preflight a harmless core
   `get data` event without sending an Apple Event.
4. A fixed in-process `NSAppleScript` handler invoked with Apple Event
   descriptors can perform a harmless operation such as obtaining the
   Messages application name while sandboxed.

A successful local experiment gates PR 2, not PR 1. Developer ID and
notarization uncertainty is documented for the maintainer and may gate an
upstream release, but it does not gate local implementation. No external
notarization is attempted without explicit authorization and appropriate
credentials.

The ignored probe compiles as a sandboxed app bundle with stable local
bundle identifier `com.loopwork.imcp.messages-automation-probe`. Its fixed
script only obtains the Messages application name, and its arguments are inert
probe strings passed as Apple Event descriptors. On 2026-07-20, an Apple
Development-signed probe and clean app copy both passed strict signature
verification with Hardened Runtime enabled. The effective app entitlements
contained App Sandbox, Apple Events automation, and an exception limited to
`com.apple.MobileSMS`. The nested CLI contained only App Sandbox inheritance
in the experiment and no automation entitlement or Messages exception.

No-prompt TCC preflight returned consent-required. After the user approved the
macOS Automation prompt, prompted preflight returned success and the harmless
fixed handler obtained only the Messages application name. No message was sent
and no account, chat, participant, contact, or history enumeration occurred.

## Hybrid routing

`message_send_text` has two deliberately different routes, chosen by
destination resolution before any authorization, with **no automatic
fallback in either direction**.

**Existing conversation — semantic programmatic send.** Resolve the destination
in the Messages database, present the immutable iMCP confirmation of the exact
destination and exact body, obtain Automation authority, revalidate the database
destination, verify the exact chat is still addressable, then dispatch exactly
one fixed-script chat-target send. Existing iMessage, SMS, and RCS conversations
all use this one path; nothing branches on service.

**New direct recipient — user-controlled composition.** Once the database has
proved that no existing direct conversation matches the exact recipient, seed
`NSSharingService.Name.composeMessage` with that recipient and body and present
the system-owned Messages panel. The human reviews, may edit either value, and
personally presses Send.

The authorization models differ, and the difference is the point. The
programmatic path is authorized by an iMCP confirmation of values that cannot
then change. The composition path is authorized by the human's own action in the
system panel, so iMCP presents no confirmation in front of it: an earlier
immutable confirmation could not truthfully authorize values that remain
editable. The confirmation-mode setting therefore governs the programmatic
path only. `body` is required input on every call, supplied by the caller
directly; iMCP does not elicit a missing body for either route (ADR 0013).

Route selection for a new recipient is delegated to Messages. There is no
caller-facing service selector, and an authorized experiment confirmed Messages
will choose SMS with no transport supplied. `didShareItems` reports that the
sharing interaction completed — not delivery, and not evidence that the seeded
values were the ones sent. App Sandbox is retained, no Accessibility or private
framework is involved, and the path needs no additional entitlement. See ADR
0006.

Composition failures divide by what they actually establish. User cancellation
(`NSUserCancelledError`) and the pre-presentation unavailable and busy cases sent
nothing, and say so. Any other delegate failure arrives after the panel was
presented and establishes only that an error occurred while sharing, so it is
reported as ambiguous: the composition failed and whether a message was sent is
unknown. That outcome is terminal — no retry, no fallback, no second route —
because an unknown result is exactly where a retry could duplicate a message.
The underlying error is sanitized in every case.

## First send behavior

`message_send_text` initially accepts plain text and one exact canonical
E.164-style phone handle or syntactically valid email handle.

The tool:

- requires a non-empty `body` supplied directly by the caller; a missing,
  non-string, or empty `body` fails immediately, before any destination
  lookup, confirmation request, composition, or dispatch, and is never
  elicited (ADR 0013);
- always performs a separate final confirmation, for every destination form,
  with no opt-out of any kind;
- shows the exact destination and exact body in that confirmation, because it is
  the surface on which the user authorizes an externally visible side effect;
- fails closed for unsupported, declined, cancelled, dismissed, malformed,
  timed-out, errored, or task-cancelled confirmation;
- requests TCC only after a successful confirmation;
- passes recipient and body as Apple Event descriptors to a fixed in-process
  handler;
- dispatches at most one send event and never retries after dispatch or an
  ambiguous outcome;
- reports only that Messages accepted a submission, never delivery; and
- never logs or returns recipients or message bodies.

Final send confirmation presentation is persisted as Automatic, MCP form, or
iMCP app. Missing or invalid preferences resolve to Automatic; there is no off
state. Automatic selects MCP form before authorization begins when the current
connection advertises form support, otherwise it selects the native iMCP AppKit
dialog. Explicit MCP form mode never falls back, and explicit iMCP app mode never
issues an MCP final-confirmation request. Once an MCP confirmation request has
begun, every negative or failed outcome is terminal for that send and can never
open the native dialog as a second authorization opportunity.

Both presenters consume one immutable title/message value built by the existing
destination-specific formatter. The native dialog is final-send authorization
only, not a generic native JSON-schema or missing-input elicitation renderer. It
runs on the main actor, activates iMCP, presents frontmost Send and Cancel
actions, and treats dismissal or any unexpected result as cancellation.

There is no contact lookup, attachment support, transport selection, fallback,
or delivery tracking. Existing `messages_fetch` behavior is preserved.

The existing-conversation resolver accepts exactly one effective destination:
`recipients` or `chat_id` (ADR 0013; the resolver previously also accepted a
separate singular `recipient` property, removed with no alias). A chat ID
must be the opaque value returned by `messages_list_chats`; raw GUIDs, group
IDs, chat identifiers, service names, and scripting expressions are not
accepted from callers.

`recipients` accepts either a scalar exact handle (string) or a non-empty
array of exact handles, expressed in the schema as a `oneOf` union — the same
scalar-or-array idiom already used by `showPointsOfInterest` in
`App/Services/Maps.swift`. A scalar handle and a one-item array are
identical direct-recipient intent; both are normalized only for matching:
verified E.164 numbers remain byte-for-byte unchanged, and syntactically
valid email addresses are trimmed and lowercased. No country code is
inferred, and phone and email identities are never merged. One unique direct
membership match uses the existing-chat path. A verified no-match uses
system-owned composition; multiple direct matches fail and require
`chat_id`. Group chats are never considered for this single-recipient
lookup.

An array of two or more elements is the complete set of remote participants
in an existing group. Input order and exact duplicate membership rows do not
matter, but there must be at least two distinct normalized handles after
duplicates/normalization collisions are folded — an array that collapses to
fewer than two distinct handles fails closed rather than silently becoming a
direct send. Only exact set equality matches: subsets and supersets never
match. iMCP cannot create a new group. No match, unavailable membership, or
incomplete membership fails without dispatch; multiple matching groups
require `chat_id`, which is preferred whenever the caller already knows the
intended group. An empty array fails outright. Contacts and message-history
senders are not consulted.

Chat sends resolve the opaque ID to current display/room, direct/group,
participant, service, and database GUID metadata before confirmation. Their
confirmation shows the selected conversation plus the exact body. The same
opaque ID is resolved again after
acceptance, and all confirmed metadata must still match before dispatch.
Recipient- and participant-matched conversations follow the same mandatory
confirmation path and repeat the exact membership match before dispatch. A
changed or stale match fails rather than selecting another chat or switching
to new-recipient composition.

Messages' public scripting dictionary defines `chat.id` as the chat GUID and
allows `send` to a chat. A signed, sandboxed, ignored no-send probe compared up
to ten recent database chats in each known service/kind category. Only
`chat.guid` mapped to scripting `chat.id`; chat identifiers and group IDs did
not. Tested recent direct iMessage, SMS, and RCS chats and iMessage groups
resolved uniquely. Some older SMS/RCS group database rows were not present in
the scripting chat collection, so production fails those targets without
recipient fallback.

The fixed handler receives GUID and body only as Apple Event descriptors,
requires exactly one scripting chat before its single `send`, and never
retries or falls back. Chat success returns only `status: submitted` and
`service: Messages`; it does not claim delivery or expose routing metadata.
Actual route preservation and post-dispatch behavior remain manual-verification
items because the experiment deliberately sent nothing.

### Existing-chat automation addressability

Those unexposed rows are an addressability limit, not a service-type limit.
Messages publishes only a bounded, recency-biased subset of its conversations to
scripting, and recent direct iMessage, SMS, and RCS chats all resolve through
the same public `chat` class. No send path branches on service, and the observed
window size is never encoded in production.

The zero-match condition is reported as `chatUnavailableInAutomation`. Its text
says the conversation is not currently available through Messages automation,
adds a non-promissory hint to open or use it in Messages and retry, and exposes
no GUID, handle, participant, display name, body, or internal service or account
identifier.

A read-only fixed handler evaluates `exists chat id <guid>` with the GUID passed
as a descriptor. It performs no enumeration, no history read, no mutation, and
no `send`, and it reuses the same actor-serialized script infrastructure as the
existing chat send.

Because that probe is still an Apple Event, its placement is governed by a
non-prompting `AEDeterminePermissionToAutomateTarget` status check:

- **already authorized** — probe before confirmation; an unavailable chat fails
  with zero confirmation and zero dispatch, and an available one proceeds to the
  immutable confirmation;
- **denied** — fail closed immediately, with no confirmation and no second
  permission attempt;
- **consent required or unrecognized** — no early Apple Event at all, so the
  conservative sequence is preserved and no permission prompt can precede the
  confirmation.

After an accepted confirmation the flow revalidates the database destination,
requests Automation authority, reconfirms addressability for the exact chat, and
only then dispatches once. The early probe reserves nothing, so this final guard
is mandatory; the handler's own zero-match check remains the last race defense
and maps to the same addressability error.

Tool annotations are `readOnlyHint: false`, `destructiveHint: false`,
`idempotentHint: false`, and `openWorldHint: true`.

## Read-only conversation listing

The conversation listing has been expanded into a schema-resilient summary and
full index. See [Messages conversation index](messages-conversation-index.md)
and Proposed ADR 0005 for the current schema, field, aggregate, performance,
availability, privacy, and identifier semantics.

The selected tool name is `messages_list_chats`, following the existing
`messages_fetch` read-side service prefix (the send-side tools instead use
the singular `message_send_*` naming settled by ADR 0012). It performs only
a read-only SQLite query and does not invoke Apple Events, launch Messages,
or change any send behavior.

Input schema:

- `limit`: optional integer, default `30`, minimum `1`, maximum `100`;
- `kind`: optional string enum, `direct` or `group`;
- `detail`: optional string enum, `summary` (default) or `full`; and
- no additional properties.

Output contains `detail`, a field-level `metadataAvailability` map, and a
`chats` array. Summary records preserve the opaque `id`, display name, kind,
participant count, service, and latest activity fields, and compatibly add
`chatId`, database chat identity metadata, archive/filter/read state, and
deterministically sorted remote membership records. Full detail adds bounded
message-state, count, attachment, reply, reaction-event, edit, retraction,
effect, and plugin aggregates without selecting message bodies or private file
metadata. The exact field and zero/null/unavailable semantics are maintained in
the dedicated conversation-index documentation rather than duplicated here.

The query returns most recently active chats first, places chats without
activity last, and counts duplicate participant joins once. A participant
count greater than one is classified as group; zero or one is classified as
direct. The count and returned membership exclude the current user. That
classification reflects the observed Messages schema and remains a documented
limitation for unusual database states.

Chat listing uses a separate, read-only security-scoped bookmark for the
user-selected Messages directory. This scope is required because a live SQLite
read may need `chat.db-wal` and `chat.db-shm` beside `chat.db`; the older
single-file bookmark remains unchanged for `messages_fetch`. The repository
opens the database read-only, enables SQLite `query_only`, and does not use
`immutable=1`, which could omit recent WAL-backed activity. Failures record
only a fixed operation stage and numeric SQLite result code, never paths, SQL,
or returned metadata. See Proposed ADR 0004.

The identifier is `imcp-chat-v1_` followed by an unpadded base64url HMAC-SHA256
of the unique Messages `chat.guid`, keyed by a random app-local value persisted
in iMCP defaults. It is opaque API data and does not reveal a GUID that may
embed a participant handle; it is not an authorization token. It avoids
exposing a SQLite `ROWID`, is deterministic across calls, MCP reconnects, and
iMCP restarts while both the key and underlying GUID are unchanged, and
resolves direct and group chats by deriving identifiers for current GUIDs and
requiring exactly one match. Invalid versions/encoding and stale identifiers
fail closed.

Deterministic construction with the same persisted key verifies reconnect and
iMCP-restart behavior without a mutable identifier registry. Clearing iMCP
defaults or reinstalling the app rotates the key and invalidates prior IDs.
Persistence across Messages.app restarts, macOS reboots, and Messages database
migrations has not been experimentally verified and is not guaranteed. A
future chat-targeted send feature must validate and resolve the opaque
identifier against the current database immediately before its separately
confirmed dispatch; it must not treat the identifier as executable input or
reuse it without a current existence check. See Proposed ADR 0003.

Known limitations: no fuzzy search, contact resolution, message previews,
pagination cursor, chat creation, or routing behavior is included. Mention and
screened-state aggregates remain explicitly unavailable because the inspected
columns do not establish the requested semantics. Unnamed groups may omit
`displayName`. Existing installations must
grant the directory-scoped permission once; granting only the legacy `chat.db`
permission is insufficient for the live database family. When Messages is
already enabled, a versioned startup migration explains that conversation
listing needs the additional folder scope and offers the folder picker once.
Fresh Messages activation presents the same explanation. Choosing “Not Now”
preserves existing fetch and send configuration; chat listing remains
unavailable and requests the permission when invoked.

## Recipient and conversation discovery

Discovery keeps four responsibilities apart: Contacts finds people, Messages
finds conversations, the LLM interprets identity and destination, and
`message_send_text`/`message_send_attachment` act on one exact destination
each. An earlier
`messages_match_recipients` proposal, which would have published the send
matcher's `unique` / `none` / `ambiguous` / `incomplete` states as the discovery
model, was superseded before implementation; those remain private send-safety
semantics.

Business logic sits in reusable domain operations with MCP tools as thin
adapters over them — `ContactSearching` under `contacts_search`, and
`MessagesConversationSearching` under the new `messages_find_conversations`.
Each operation exposes exactly the facts its own tool returns. See
[Messages conversation search](messages-conversation-search.md) and Proposed
ADR 0007 for the input, output, completeness, ordering, truncation, query-shape,
and privacy semantics.

`contacts_search` behavior is unchanged by that extraction for its inputs,
normalization, AND combination, empty-input rejection, and authorization
model. Its result shape gained one additive fact (ADR 0008): each returned
record remains a flat `Person` object with `phoneNumbers` added as a sibling.
The existing `telephone` field stays exactly the stored values, for backward
compatibility, while `phoneNumbers` pairs each raw value with its Contacts label
and, when it parses and validates under one effective region (an explicit
Settings override, otherwise the live system region), its E.164 identity. A
value that does not normalize contributes no `e164`. This stays a Contacts-side
concern: Messages gains no country inference from it, and
`MessagesHandleNormalization` and every Messages send/discovery path remain
exact-only.

`contacts_find_conversations` is the read-only convenience interface that
literally composes the two reusable operations: contact search, extract the
returned exact communication identities from each contact's public
`phoneNumbers[].e164` and `email` facts, one underlying Messages conversation
lookup across them, and a mechanical join. A client reproducing the same
primitive facts through public `messages_find_conversations` may need to batch
more than 20 exact identities across multiple calls. The composite calls the
operations directly rather than invoking MCP tools, and adds no person selection,
contact-method selection, ranking, confidence, or send behavior. A contact with
no exact identity means no lookup runs. A Messages source failure, or a lookup
that omits a requested identity result, fails the call;
`lookupCompleteness: incomplete` is valid and returned unchanged.

Because it reads two independently enabled services, a tool may now name extra
services it depends on. The server advertises and runs a tool only while every
service it reads is enabled, so enabling Contacts is not a way around a disabled
Messages setting. Every other tool declares no dependency and is gated exactly as
before.

The remaining discovery question is the separate Contacts-side one below.

## Attachment submission

`message_send_attachment` submits exactly one file to one exact **existing**
conversation. It is a separate public tool from `message_send_text`, not an
option on it. It shipped first as `messages_send_attachment` (ADR 0009); ADR
0011 briefly folded it into a unified `messages_send` tool as an `attachment`
payload, and ADR 0012 restored it as its own tool under its current name,
`message_send_attachment`, without changing the pipeline described in this
section at any point in that history. See Proposed ADR 0009 for the original
attachment-handling decision and Accepted ADR 0012 for the current
two-tool public API.

A single dispatch carries only a file or only text, never both. The
installed `/System/Applications/Messages.app/Contents/Resources/Messages.sdef`
documents `send` with a single direct parameter typed as either `file` or
`text`, so a file plus a caption would be two dispatches for one approval and
would break the one-dispatch invariant. A caption is therefore its own
`message_send_text` call with its own confirmation.

Scope of this slice:

- exactly one attachment, no caption or body, no multiple files;
- existing conversations only, addressed by `recipients` (scalar or array) or
  `chat_id` — the same mutually exclusive selectors, resolution, ambiguity,
  staleness, and addressability semantics as `message_send_text`, sharing the
  same code rather than a parallel implementation;
- a recipient *verified* to have no existing conversation fails categorically; it
  does not fall through to `NSSharingService`, which cannot address a chosen
  existing chat. Verified-new-recipient attachment composition stays deferred.

The tool accepts **no path, URL, filename, bytes, body, or attachment
identifier**. After the destination resolves, iMCP presents a native single-file
open panel; the human's selection there is what grants sandbox read access, so
the private path never enters the MCP request, logs, errors, or results. The
picker and validator sit behind `MessagesAttachmentSelecting` and
`MessagesAttachmentValidating` and are injected into `MessageService`, so tests
present no UI.

File policy: exactly one ordinary, nonempty regular file of at most 25 MiB
(26,214,400 bytes, inclusive), classified by public Uniform Type Identifier as
image, audiovisual content, PDF, or plain text. Directories, packages, bundles,
symbolic links, aliases, executables, unknown generic data, archives, disk
images, and applications are rejected. Only in-memory facts are kept — URL,
display name, byte size, content type, resource identifier, modification date —
and **no attachment bookmark is persisted**. Security-scoped access is held from
validation through the synchronous Apple Event and then released.

Ordering is destination resolution, non-prompting addressability preflight only
when Automation is already authorized, picker, validation, one immutable final
confirmation, destination re-resolution requiring exact equality, file re-read
requiring the same identity and unchanged bounded properties, Automation request
and addressability recheck, then exactly one dispatch. A removed, replaced,
modified, enlarged, or newly unsupported file fails with zero dispatch. Because
`URL` caches resource values, the validator drops that cache before every read;
otherwise the second read would replay the first one's answers and miss a swapped
file entirely.

The fixed script gains `submitChatAttachment(chatGUID, attachmentFile)`, which
repeats the same zero/one/many exact-chat checks and issues one
`send attachmentFile to item 1 of targetChats`. The chat GUID stays a string
descriptor and the file is a typed `NSAppleEventDescriptor(fileURL:)`, never a
path string; Apple Event arguments are now typed descriptors throughout.

The confirmation shows the exact conversation plus the attachment's display name,
public type description, and formatted size, and says that no message text is
sent. It never shows the path or the contents. The result reuses the redacted
submission status with `mode: attachment` and carries no file facts. Success means
Messages accepted one attachment submission, never that it was delivered.

## Automatic-send authorization policy

Feature completion was reopened by a product expansion: confirmation-required
stays the factory default, but a user may explicitly opt into automatic sending
in iMCP Settings, for unattended workflows. The architecture investigation
behind this milestone is recorded in Hexa (project knowledge
`imessage-mcp/automation-product-design`, `imessage-mcp/current-status`), not
duplicated here.

Per-client automation authorization was considered and explicitly rejected by
the user as unnecessary product complexity — the additional UX, configuration,
and (to be trustworthy) pairing or authentication work is not worth it for this
project. The settled product decision is **one global Messages sending mode
for the whole application**, applying equally to every connected MCP client,
never a per-client model.

Separately, that same investigation found the current MCP connection stack — a
bundled CLI proxying stdio to a loopback-only `NWListener`/`NWConnection` TCP
socket in the signed app — exposes no OS-derived, unspoofable per-client
identity. `clientInfo.name` is the only available signal, is caller-supplied,
and is already the (unauthenticated) key behind the existing `trustedClients`
connection-approval feature. This finding did not drive the global-policy
decision, but it is a reason the project should not describe `clientInfo.name`
as an authenticated identity or build a per-client authorization boundary on top
of it without first establishing real client identity. See Proposed ADR 0010 for
the full decision record.

A first implementation represented the policy as four independent categories
(existing direct/group conversation × text/attachment). It was code-reviewed
and passed automated verification but **failed the human manual Settings
acceptance checkpoint**: the user found that control surface more complex than
the product needs and explicitly approved a simpler binary replacement. ADR
0010 was revised in place to describe the settled model below rather than the
rejected one.

The implementation persists `MessagesSendingMode`, a two-case enum —
`askBeforeSending` (factory default) and `sendAutomatically` — under its own
`UserDefaults` key, distinct from the earlier four-category type's key. The
earlier type's persisted data is simply never read by `MessagesSendingMode`, so
any category a developer enabled while testing the rejected design cannot
resolve into `sendAutomatically` now; a test pins this behavior explicitly.
There is no operation-class dimension (no direct/group or text/attachment
distinction) and no automatic-new-recipient state, because the new-recipient
path stays human-completed `NSSharingService` composition (ADR 0006) regardless
of the selected mode.

Settings replaces the prior two-section split ("Message Sending" +
"Automatic Sending") with one section containing a single **Sending** choice.
When Ask Before Sending is active, a subordinate **Confirmation method** choice
(the existing `MessagesSendConfirmationMode`, whose `automatic` case is now
labeled "Best available" in the UI while its stored raw value stays
`"automatic"`) is shown beneath it; when Send Automatically is active, that
control is hidden. Selecting Send Automatically shows one native warning that
all connected MCP clients will be able to submit eligible sends without asking
each time; canceling leaves the mode unchanged. Switching back to Ask Before
Sending never warns, since that can only make behavior safer. No MCP tool reads
or writes this mode's storage key, so no tool argument, prompt, or elicitation
response can change it — only Settings-owned code can.

This Settings-only slice was manually accepted by the user on 2026-08-16.
ADR 0010 is now `Accepted`.

### Runtime wiring for existing-conversation text sends

Following manual acceptance, existing-conversation plain-text sending now
honors `MessagesSendingMode`. `MessageService` gained an injected
`sendingMode: @Sendable () -> MessagesSendingMode` closure defaulting to
`MessagesSendingMode.load()`, evaluated fresh on every call rather than
snapshotted at service construction, so a Settings change takes effect on the
very next call without restarting the app.

The authorization branch sits immediately around the existing final-confirmation
request: in Ask Before Sending, the unchanged confirmation flow runs; in Send
Automatically, that one step is skipped and execution rejoins the same shared
code — cancellation checks, destination revalidation, Automation/addressability
verification, the single dispatch, categorical logging, and the redacted
result — unconditionally, for both modes. There is no second dispatch path.
Verified-new-recipient composition returns before the mode is ever consulted,
so it is unaffected.

The text tool's public description and its destination parameter description
were updated to stop promising confirmation for every existing-chat send; they
now explain that whether confirmation happens follows the user's Sending mode
setting, which no caller can choose or override. The tool's input schema is
unchanged — no mode/automatic/confirmation-bypass argument was added. (This
tool was named `messages_send` and exposed a separate singular `recipient`
property at the time of this wiring slice; ADR 0012 later renamed it
`message_send_text`, and ADR 0013 later still folded `recipient` into
`recipients`, neither changing this behavior.)

ADR 0002's "confirmation for every submission, no opt-out" language is
reconciled in place (not superseded wholesale) to describe this accepted
exception; every other invariant it establishes remains in force in both
modes. See ADR 0002 and ADR 0010 for the full record.

### Runtime wiring for existing-conversation picker-based attachments

The 2026-08-16 real-runtime checkpoint accepted the text-send wiring above.
Following that acceptance, picker-based attachment sends — at the time still
the separate `messages_send_attachment` tool — read the same `sendingMode`
provider already on `MessageService`. The authorization branch sits
immediately around the attachment path's own final attachment confirmation
and nowhere else: the native picker, bounded file validation,
destination/file revalidation, Automation/addressability verification, the
single dispatch, categorical logging, and the redacted result are all
identical, shared, unconditional code in both modes. In Send Automatically,
only the confirmation step is skipped — the picker still always runs, and
selecting a file is never itself treated as authorization, so attachment
sending is not fully unattended even in that mode. Verified-new-recipient
attachment rejection happens before the picker is ever presented and is
unaffected by the mode.

The public description of that attachment path was updated the same way as
the text path: it no longer promises confirmation unconditionally, and now
explains that whether confirmation happens follows the Sending mode setting
while the native picker itself always runs. ADR 0009's "confirmation for
every attachment submission" language is reconciled in place (not
superseded) the same way ADR 0002's was, for the same accepted exception.
See ADR 0009 and ADR 0010 for the full record.

Later the same day, ADR 0011 briefly consolidated the then-separate
`messages_send_attachment` tool into `messages_send`'s `attachment` payload.
That consolidation did not touch this Sending-mode wiring: the authorization
branch, the unconditional picker, and every invariant above carried forward
unchanged onto the unified tool's attachment path. It was implemented and
code-reviewed but never manually accepted; the user reversed it before the
runtime checkpoint. ADR 0012 then restored a separate attachment tool under
its current name, `message_send_attachment`, again without touching any of
this Sending-mode wiring. The picker-attachment manual acceptance checkpoint
deferred at the end of this wiring slice remains outstanding and now applies
to `message_send_attachment`. See ADR 0012 and "Attachment submission" above
for the current tool's full schema and behavior.

The next day, ADR 0013 corrected two pieces of ADR 0012's shipped-but-not-
fully-accepted public input: it folded the separate `recipient`/`recipients`
destination properties into one scalar-or-array `recipients` property on
both tools, and removed `message_send_text`'s missing-body elicitation in
favor of a hard non-empty-`body` requirement. Neither change touched this
Sending-mode wiring, the picker, or any downstream revalidation/Automation/
dispatch invariant for either tool — both corrections are strictly upstream,
in the destination/body parsing that feeds `sendText`/`sendAttachment`. The
deferred picker-attachment manual acceptance checkpoint remains outstanding
and applies to `message_send_attachment` in its current schema shape.

## Reference implementation

The direct-send automation was informed by Carter LaSalle's MIT-licensed
[`mac_messages_mcp`](https://github.com/carterlasalle/mac_messages_mcp).
Source-level attribution and the complete license notice are retained in
`App/Services/MessagesSender.swift` and `THIRD_PARTY_NOTICES.md`.

`../mac_messages_mcp` was inspected as read-only reference material at commit
`3f750fc0cf93871bcae4435a0492f07914604e31`. It is MIT licensed, copyright
2023 Carter Lasalle.

Useful behavior includes separating direct recipients from chats, validating
inputs, bounding automation, and mocking automation in tests. The Python
subprocess model, temporary-file message bridge, private AddressBook SQL,
global selection state, recipient logging, US-centric normalization, broad
fallback, and stringly errors should not be copied.

The Swift implementation is a native redesign rather than a verbatim port.
The adapted automation concepts are identified at source level, and the
upstream MIT notice is retained in `THIRD_PARTY_NOTICES.md`. Apply the same
source-level identification if additional substantial source or tests are
adapted later.

## Delivery strategy

Development is feature-complete-first. The safe public-API scope is finished and
hardened on the active review branch before any of it is decomposed into
upstream pull requests, so the maintainer receives a coherent, polished
contribution rather than a partially designed feature.

No maintainer-facing pull request is opened during feature completion. See
[`development-workflow.md`](development-workflow.md) for branch, review, and
acceptance sequencing.

### Upstream decomposition, after feature completion

Once the public scope is complete and hardened, map the accumulated
implementation into independently reviewable pull requests whose intermediate
states each build and test. Likely boundaries, kept in dependency order:

1. **Generic form elicitation.** The per-connection call context and requester,
   capability handling, cancellation and timeout behavior, and proxy round-trip
   coverage. Carries no Messages-specific behavior.
2. **Safe direct send and automation.** Typed send errors, the fixed AppleScript
   adapter, entitlements and usage description, mandatory confirmation showing
   the exact destination and body, minimal JSON text result, redacted logging,
   and the relevant Proposed ADRs.
3. **Conversation index.** Schema-resilient read-only listing, participant
   identity, and metadata availability reporting.
4. **Chat-target sending and existing-conversation matching.** Opaque chat IDs,
   revalidation before dispatch, and exact participant-set matching.
5. **New-recipient routing.** Only after its own experiments.
6. **Contacts resolution**, then **attachments**, then **release
   documentation.**

These boundaries are a plan, not a commitment; confirm them against the actual
accumulated diff when decomposition begins.

## Unresolved upstream questions

- Whether the maintainer's Developer ID and notarization pipeline accepts the
  Messages temporary Apple Events exception.
- The exact form-mode capabilities advertised by each supported MCP client.
- Messages participant lookup behavior across supported macOS versions.

The earlier `CSSMERR_TP_NOT_TRUSTED` result was caused by running `codesign`
inside a restricted execution context that could not consult the login
keychain. The Apple Development leaf, WWDR G3 intermediate, and Apple root all
validated, including revocation checks. Repeating the original strict
verification with normal keychain access passed; no trust settings were added
or weakened.

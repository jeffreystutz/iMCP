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

`messages_send` has two deliberately different routes, chosen by destination
resolution before any authorization, with **no automatic fallback in either
direction**.

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
editable. Missing-input elicitation may still precede routing, because gathering
an input is not authorizing a send. The confirmation-mode setting therefore
governs the programmatic path only.

Route selection for a new recipient is delegated to Messages. There is no
caller-facing service selector, and an authorized experiment confirmed Messages
will choose SMS with no transport supplied. `didShareItems` reports that the
sharing interaction completed — not delivery, and not evidence that the seeded
values were the ones sent. App Sandbox is retained, no Accessibility or private
framework is involved, and the path needs no additional entitlement. See ADR
0006.

## First send behavior

`messages_send` initially accepts plain text and one exact canonical
E.164-style phone handle or syntactically valid email handle.

The tool:

- may elicit missing input, then validates the effective values;
- always performs a separate final confirmation, for every destination form,
  with no opt-out of any kind;
- shows the exact destination and exact body in that confirmation, because it is
  the surface on which the user authorizes an externally visible side effect;
- treats missing-input elicitation as input gathering only, never as
  authorization;
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
`recipient`, `recipients`, or `chat_id`. A chat ID must be the opaque value returned by
`messages_list_chats`; raw GUIDs, group IDs, chat identifiers, service names,
and scripting expressions are not accepted from callers.

An exact `recipient` is normalized only for matching: verified E.164 numbers
remain byte-for-byte unchanged, and syntactically valid email addresses are
trimmed and lowercased. No country code is inferred, and phone and email
identities are never merged. One unique direct membership match uses the
existing-chat path. A verified no-match uses system-owned composition; multiple
direct matches fail and require `chat_id`. Group chats are never considered for
this single-recipient lookup.

`recipients` is the complete set of remote participants in an existing group.
Input order and exact duplicate membership rows do not matter, but there must
be at least two distinct normalized handles. Only exact set equality matches:
subsets and supersets never match. iMCP cannot create a new group. No match,
unavailable membership, or incomplete membership fails without dispatch;
multiple matching groups require `chat_id`, which is preferred whenever the
caller already knows the intended group. Contacts and message-history senders
are not consulted.

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
`messages_fetch` and `messages_send` service prefix. It performs only a
read-only SQLite query and does not invoke Apple Events, launch Messages, or
change any send behavior.

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

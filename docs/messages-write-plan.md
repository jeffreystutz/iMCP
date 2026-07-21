# Messages write support plan

## Status

This document records the approved architecture and delivery sequence for safe
Apple Messages write support. Generic form elicitation and the narrow direct
send implementation are combined on the working branch. Track B succeeded
locally. Verified repository facts remain separate from unresolved upstream
distribution questions.

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

## First send behavior

`messages_send` initially accepts plain text and one exact canonical
E.164-style phone handle or syntactically valid email handle. It targets
iMessage only.

The tool:

- may elicit missing input, then validates the effective values;
- performs a separate form-elicitation confirmation by default;
- permits an explicit, persistent app-local opt-out with a destructive warning
  for clients that do not support form elicitation;
- fails closed for unsupported, declined, cancelled, malformed, or timed-out
  elicitation;
- requests TCC only after confirmation, or after validation when confirmation
  has been explicitly disabled;
- passes recipient and body as Apple Event descriptors to a fixed in-process
  handler;
- dispatches at most one send event and never retries after dispatch or an
  ambiguous outcome;
- reports only that Messages accepted a submission, never delivery; and
- never logs or returns recipients or message bodies.

The first version has no contact lookup, normalization, groups, attachments,
SMS, RCS, fallback, or delivery tracking. Existing `messages_fetch` behavior
is preserved.

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

## Pull request sequence

1. **Combined form elicitation and direct iMessage send.** Add the
   per-connection call context and requester, proxy round-trip coverage, local
   typed send errors, fixed AppleScript adapter, entitlements and usage
   description, default-on confirmation with an explicit local opt-out,
   minimal JSON text result, redacted
   logging, tests, and both Proposed ADRs. The direct-send portion depends on a
   successful local Track B experiment. Do not open the PR until requested.
2. **Generic structured tool outputs.** Forward optional output schemas and
   structured content while retaining JSON text compatibility. Depends on the
   combined first PR.
3. **URL elicitation and broader compatibility.** Extend the requester to URL
   mode, add completion correlation, extract pure proxy framing, and expand the
   client compatibility matrix. Depends on the combined first PR but follows
   structured-output support in delivery.
4. **Native contact resolution.** Use Contacts APIs and form elicitation for
   ambiguity; do not query private AddressBook databases.
5. **Explicit groups and additional services.** Add only after separate
   experiments; never silently fall back or issue more than one send event.

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

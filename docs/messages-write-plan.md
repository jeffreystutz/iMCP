# Messages write support plan

## Status

This document records the approved architecture and delivery sequence for safe
Apple Messages write support. PR 1 is implemented on the working branch;
Track B is scaffolded but remains blocked on a valid Apple Development signing
identity. Verified repository facts are separated from platform behavior that
still requires a signed experiment.

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

The ignored probe now compiles as a sandboxed app bundle with stable local
bundle identifier `com.loopwork.imcp.messages-automation-probe`. Its fixed
script only obtains the Messages application name, and its arguments are inert
probe strings passed as Apple Event descriptors. On 2026-07-20,
`security find-identity -v -p codesigning` reported no valid identities.
Consequently Apple Development signing, effective-entitlement inspection,
TCC preflight, and harmless automation have not yet been run. PR 2 remains
gated until a local identity is installed and those checks pass.

## First send behavior

`messages_send` initially accepts plain text and one exact canonical
E.164-style phone handle or syntactically valid email handle. It targets
iMessage only.

The tool:

- may elicit missing input, then validates the effective values;
- always performs a separate form-elicitation confirmation;
- fails closed for unsupported, declined, cancelled, malformed, or timed-out
  elicitation;
- requests TCC only after confirmation;
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

## Reference implementation

`../mac_messages_mcp` was inspected as read-only reference material at commit
`3f750fc0cf93871bcae4435a0492f07914604e31`. It is MIT licensed, copyright
2023 Carter Lasalle.

Useful behavior includes separating direct recipients from chats, validating
inputs, bounding automation, and mocking automation in tests. The Python
subprocess model, temporary-file message bridge, private AddressBook SQL,
global selection state, recipient logging, US-centric normalization, broad
fallback, and stringly errors should not be copied.

The Swift implementation is an independent native design. If substantial
source or tests are directly adapted later, retain the upstream MIT notice in
a third-party notice and identify the adapted source.

## Pull request sequence

1. **Per-connection form elicitation.** Add the call context, form requester,
   capability checks, unit tests, a production-proxy round-trip test, the
   Proposed elicitation ADR, and CI test execution. Depends only on the verified
   baseline.
2. **Direct confirmed iMessage send.** Add the local typed errors, fixed
   AppleScript adapter, entitlements and usage description, mandatory
   confirmation, minimal JSON text result, redacted logging, tests, and the
   Proposed Messages automation ADR. Depends on PR 1 and a successful local
   Track B experiment.
3. **Generic structured tool outputs.** Forward optional output schemas and
   structured content while retaining JSON text compatibility. Depends on PR 2.
4. **URL elicitation and broader compatibility.** Extend the requester to URL
   mode, add completion correlation, extract pure proxy framing, and expand the
   client compatibility matrix. Depends on PR 1 but follows PR 3 in delivery.
5. **Native contact resolution.** Use Contacts APIs and form elicitation for
   ambiguity; do not query private AddressBook databases.
6. **Explicit groups and additional services.** Add only after separate
   experiments; never silently fall back or issue more than one send event.

## Unresolved upstream questions

- Whether the maintainer's Developer ID and notarization pipeline accepts the
  Messages temporary Apple Events exception.
- The exact form-mode capabilities advertised by each supported MCP client.
- Messages participant lookup behavior across supported macOS versions.

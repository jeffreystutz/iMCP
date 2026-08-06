# ADR 0003: Expose versioned opaque Messages chat identifiers

- Status: Proposed
- Date: 2026-07-21
- Deciders: iMCP maintainers
- Supersedes:
- Superseded by:

## Context

A read-only conversation-listing tool needs to identify both direct and group
Messages chats across later MCP calls without exposing SQLite row identifiers
or turning identifiers into executable AppleScript input. A future
chat-targeted operation must reject malformed and stale identifiers before any
side effect.

Messages stores a unique `chat.guid` value and a process-local SQLite `ROWID`.
The GUID is the existing library's chat identity and works for both direct and
group chats. Its behavior across Messages database migrations is not specified
by this repository.

## Decision drivers

- Resolve one current chat unambiguously.
- Avoid coupling clients to SQLite row numbering.
- Treat all identifiers as bound query data.
- Validate format, version, and current existence before future use.
- Remain deterministic without global mutable state.
- Avoid claiming untested persistence guarantees.

## Options considered

### Expose the SQLite row identifier

Compact and easy to query, but leaks a database implementation detail and may
be reassigned by migration or database reconstruction.

### Expose the raw Messages chat GUID

Uses the best available Messages-level identity, but exposes its internal form
and leaves no application-level version boundary.

### Wrap the Messages chat GUID in a keyed versioned application identifier

Derive an HMAC-SHA256 of the GUID with an app-local persistent random key and
encode it behind an `imcp-chat-v1_` prefix. Resolve by deriving IDs for current
GUIDs and matching exactly one. This hides GUIDs that may embed participant
handles without introducing a mutable identifier registry.

## Decision

`messages_list_chats` returns a versioned application identifier formed as
`imcp-chat-v1_` plus unpadded base64url of HMAC-SHA256 over the Messages chat
GUID. A random 256-bit key is generated once and persisted in iMCP defaults.
Validation accepts only the known prefix and canonical 32-byte base64url form.

Resolution must validate the identifier, read only current `chat.guid` values,
derive each candidate identifier, and require exactly one match. Malformed
identifiers fail as invalid; well-formed identifiers with no current match fail
as stale. The identifier must never be interpolated into SQL or AppleScript.

## Rationale

Messages' GUID is a better cross-call identity than SQLite `ROWID`, but direct
chat GUIDs may contain participant handles. A keyed derivation prevents that
private value from being recovered from the API identifier. The version wrapper
permits a future representation to coexist, and deterministic derivation works
across MCP connections and iMCP process restarts without a mutable registry.

## Consequences

### Positive

- Direct and group chats share one validated identifier type.
- IDs are deterministic across calls, MCP reconnects, and iMCP restarts for an
  unchanged database GUID and persisted key.
- Future chat operations have a mandatory safe resolution boundary.
- No mutable identifier registry or global state is introduced.

### Negative

- Clearing app defaults or reinstalling iMCP rotates the key and invalidates
  previously returned identifiers.
- One random 32-byte derivation key is stored in app-local defaults; it is not a
  user credential or an authorization secret, but must not be logged or exposed.
- IDs remain indirectly coupled to Messages' GUID lifecycle and require a scan
  of current chat GUIDs to resolve.
- Existing IDs become invalid if Apple changes or migrates a chat GUID.

### Risks and mitigations

- A stale or migrated GUID fails closed through the exact existence check.
- An identifier from an installation with another key does not resolve;
  identifiers remain locators, not authorization credentials.
- Opacity provides versioning, validation, and concealment of the underlying
  GUID representation. It is not a confidentiality mechanism for the
  conversation itself: `messages_list_chats` intentionally returns participant
  handles, `chatGuid`, room and group identifiers, and other conversation
  metadata alongside the opaque ID. Do not treat an opaque ID as evidence that
  the rest of that metadata is protected, and do not rely on it as an access
  control.
- Future side-effecting tools must resolve again immediately before dispatch
  and must not pass the opaque identifier or resolved GUID to AppleScript without a
  separately reviewed routing design.

## Validation

Synthetic tests verify deterministic creation with a fixed key, resolution by
a separately constructed repository with that key, and invalid and stale
failures. Stability across MCP reconnects and iMCP restarts follows from the
persisted key and deterministic derivation. Stability across Messages.app
restarts, macOS reboots, and Messages database migrations has not been
experimentally verified and is not guaranteed.

## References

- `App/Services/MessagesChatRepository.swift`
- `AppTests/MessagesChatListingTests.swift`
- `docs/messages-write-plan.md`

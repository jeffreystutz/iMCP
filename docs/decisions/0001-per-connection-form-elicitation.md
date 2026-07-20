# ADR 0001: Per-connection form elicitation

- Status: Proposed
- Date: 2026-07-20
- Deciders: iMCP maintainers
- Supersedes:
- Superseded by:

## Context

Tools currently receive only their arguments. MCP elicitation is issued by the
server toward the connected client, so a tool that needs input or confirmation
must be associated with the exact server connection that originated its call.
Services are shared singletons and may serve concurrent clients.

## Decision drivers

- Prevent responses from one client from resuming another client's tool call.
- Make elicitation reusable across services.
- Preserve existing tool declarations.
- Fail closed when a client cannot present form elicitation.
- Leave room for URL elicitation without implementing it prematurely.

## Options considered

### Explicit per-call context

Pass a context through `Service.call` and the tool closure. Construct its
requester from the active connection's server and negotiated capabilities.

### Requester on service singletons

Store the current requester on each service. This is rejected because
concurrent calls could overwrite connection state.

### Global or task-local requester

Resolve the requester implicitly. This is rejected because ownership and
lifetime would be hidden and difficult to test.

## Decision

Add an explicit `ToolCallContext` containing a generic `ElicitationRequester`.
PR 1 exposes form requests only. Existing argument-only tools keep a compatible
initializer that ignores the context.

Capture the client's initialization capabilities per connection. Treat an
empty elicitation capability as form support and reject unsupported modes
before emitting a request. Do not enable SDK strict mode globally.

## Rationale

Explicit context makes connection ownership visible at every call boundary and
allows deterministic fakes in tests. It avoids shared mutable state while
remaining a small extension of the existing Tool and Service models.

## Consequences

### Positive

- Elicitation is reusable across services.
- Concurrent connection isolation is testable.
- Existing tools need no source changes.

### Negative

- Tool dispatch gains an additional parameter.
- Connection capability state must be retained for the connection lifetime.

### Risks and mitigations

- A response could be routed to the wrong call. Cover concurrent requests and
  unique IDs through the production CLI proxy.
- Clients vary in support. Fail closed before sending an unsupported request.

## Validation

- Unit tests for accept, decline, cancel, malformed content, timeout, and
  capability combinations.
- End-to-end round trip from app-side server through the production CLI proxy
  to a test client and back to the originating tool call.

## References

- MCP 2025-11-25 elicitation specification
- MCP Swift SDK 0.12.0 `CreateElicitation` and `Server.requestElicitation`


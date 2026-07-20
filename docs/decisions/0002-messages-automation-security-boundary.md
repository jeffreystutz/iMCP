# ADR 0002: Messages automation security boundary

- Status: Proposed
- Date: 2026-07-20
- Deciders: iMCP maintainers
- Supersedes:
- Superseded by:

## Context

iMCP reads the Messages database but has no supported write path. Messages 26
exposes AppleScript `send` through bundle identifier `com.apple.MobileSMS`.
Automating it from a sandboxed, hardened app requires an Apple Events usage
description, automation entitlement, temporary Apple Events exception, and
user TCC consent.

Message submission is externally visible and cannot safely be retried after an
ambiguous result.

## Decision drivers

- Require explicit user confirmation for every send.
- Keep Apple Events authority in the signed app rather than the CLI proxy.
- Prevent script injection and duplicate sends.
- Preserve the read-only Messages flow.
- Avoid private frameworks and database writes.

## Options considered

### In-process fixed AppleScript handler

Compile a fixed handler in the app and pass recipient and body using Apple
Event descriptors.

### Spawn `/usr/bin/osascript`

Rejected because subprocess identity complicates sandboxing and TCC, and a
killable timeout still cannot prove whether a send was accepted before
termination.

### Direct or private Messages APIs

Rejected because no supported public send API was found and private APIs would
not be appropriate upstream.

## Decision

Use an actor-serialized, in-process fixed AppleScript handler. Request TCC only
after form-elicitation confirmation. Pass untrusted values through descriptors,
dispatch no more than one `send` event, and never retry after dispatch or an
ambiguous result.

The initial tool sends plain text by iMessage to one exact canonical phone or
email handle. It does not resolve contacts, address groups, use SMS/RCS, or
fallback between services.

Keep automation authority on the app target. The CLI remains a transport proxy
without Messages entitlements.

## Rationale

AppleScript is the supported automation surface exposed by Messages. Running it
in the app keeps TCC attribution aligned with the visible iMCP application.
Descriptor arguments avoid interpolating user-controlled content into source.

## Consequences

### Positive

- Permission and confirmation boundaries are explicit.
- Tests can replace the automation adapter without touching Messages.
- No private database or framework writes are required.

### Negative

- A temporary Apple Events exception is required.
- Script execution is synchronous and cancellation after dispatch is
  inherently ambiguous.
- Submission cannot establish delivery.

### Risks and mitigations

- Duplicate sends: issue one event and prohibit automatic retry.
- Privacy leakage: exclude recipient and body from logs, errors, and results.
- Distribution rejection: document Developer ID/notarization uncertainty with
  the maintainer; local development viability is a separate gate.

## Validation

- Before implementation, sign an ignored development probe with the app
  sandbox and required entitlements.
- Preflight a harmless core `get data` event through TCC without sending an
  Apple Event.
- Execute only a harmless fixed-handler Messages operation.
- Unit-test every no-send path and the at-most-one dispatch invariant with
  fakes.

## References

- Messages 26 scripting definition
- Apple Events automation entitlement and TCC documentation
- MCP form elicitation specification

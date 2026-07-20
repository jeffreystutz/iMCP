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

- Require explicit user confirmation by default, with a deliberate local
  opt-out for clients that do not support form elicitation.
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

Use an actor-serialized, in-process fixed AppleScript handler. Require
form-elicitation confirmation by default. Expose a persistent app setting that
can disable only the final confirmation step after presenting a destructive
warning; when disabled, any trusted client can submit immediately with a valid,
complete tool call. Missing inputs continue to require generic elicitation.

Request TCC only after confirmation when confirmation is enabled, or after
input validation when the user has explicitly disabled confirmation. Pass
untrusted values through descriptors, dispatch no more than one `send` event,
and never retry after dispatch or an ambiguous result.

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
- Clients without elicitation can send only after the user explicitly disables
  the default confirmation requirement in iMCP settings.
- Tests can replace the automation adapter without touching Messages.
- No private database or framework writes are required.

### Negative

- A temporary Apple Events exception is required.
- Script execution is synchronous and cancellation after dispatch is
  inherently ambiguous.
- Submission cannot establish delivery.
- Disabling confirmation delegates authorization to the trusted MCP client;
  each valid `messages_send` call can immediately cause an external side effect.

### Risks and mitigations

- Duplicate sends: issue one event and prohibit automatic retry.
- Confirmation bypass: default to confirmation enabled, require a destructive
  warning before disabling it, and limit the bypass to the final confirmation
  rather than missing-input collection or validation.
- Privacy leakage: exclude recipient and body from logs, errors, and results.
- Distribution rejection: document Developer ID/notarization uncertainty with
  the maintainer; local development viability is a separate gate.

## Validation

On 2026-07-20, an ignored probe and clean app copy were signed with an Apple
Development identity and Hardened Runtime. Strict signature verification
passed. Effective entitlements showed App Sandbox and Messages automation only
on the app; the nested CLI had sandbox inheritance and no Apple Events
authority.

A no-prompt harmless core `get data` preflight returned consent-required.
After explicit user approval, prompted preflight succeeded and a fixed handler
obtained only the Messages application name. The probe contained no send
command and performed no account, chat, participant, contact, or history
enumeration. No message was sent.

Automated tests use a fake dispatcher and cover every no-send confirmation
path, missing-input elicitation, confirmation-disabled behavior, redacted
results, fixed script source, and the at-most-one dispatch invariant.

The app previously carried an Apple Events exception for Terminal, but no
production source automates Terminal. Shortcuts invokes its command-line tool
directly. The unused Terminal exception is removed, leaving Messages as the
only Apple Events target exception.

An apparent `CSSMERR_TP_NOT_TRUSTED` result was traced to strict verification
running in a restricted context without login-keychain access. The Apple
Development leaf chains through the installed WWDR G3 intermediate to the
Apple root and passed revocation-aware verification. The original strict
bundle verification passed when repeated with normal keychain access. No
custom trust setting was added.

## References

- Messages 26 scripting definition
- Apple Events automation entitlement and TCC documentation
- MCP form elicitation specification

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

The recipient path first compares one validated handle with direct-chat
membership. One unique match uses the existing-chat path; no match preserves
the original plain-text iMessage recipient path and its explicit local
confirmation opt-out. Multiple matches fail and require a chat ID. This does
not resolve contacts or match a participant's group chats.

A complete set of two or more validated remote handles may select only one
existing group whose normalized membership is exactly equal. Ordering and
duplicate relationship rows do not matter. Subsets, supersets, unavailable or
incomplete membership, no match, and ambiguity dispatch nothing. This path
never creates a group; ambiguous callers must provide a chat ID. Email matching
lowercases the trimmed address, while phone matching accepts only already-valid
E.164 and never infers a country code or equates a phone with an email.

The tool also accepts one opaque chat ID produced by the conversation index.
Chat sends always require form confirmation, including when recipient
confirmation is disabled. Resolve current safe display metadata before
confirmation, resolve the opaque ID again afterward, require the confirmed
metadata to remain unchanged, and pass only the resulting chat GUID and body
as descriptors to a fixed handler. The handler requires exactly one scripting
chat whose public `id` equals that GUID before issuing its single send event.
Never fall back to a recipient send.

Unique recipient and group-set matches are repeated immediately before
dispatch. The public ID, classification, normalized participants, and safe
confirmation metadata must remain unchanged. Revalidation failure never
selects another conversation or changes dispatch paths.

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
  each valid recipient-based `messages_send` call can immediately cause an
  external side effect. It does not disable existing-chat confirmation.

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

On 2026-07-21, a second ignored signed sandboxed probe performed no-send lookup
only. Messages' scripting definition identifies `chat.id` as the chat GUID and
permits `send` to a chat. The probe verified unique GUID lookup for recent
direct iMessage/SMS/RCS conversations and iMessage groups; caller-visible chat
identifiers and group IDs did not match scripting chat IDs. Some older SMS/RCS
group database rows were not exposed through scripting and therefore remain
unsupported rather than receiving a fallback. No route-preservation or
post-dispatch claim is made until deliberately authorized manual sends are
observed.

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

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

- Require explicit user confirmation for every submission, with no opt-out.
- Show the exact destination and exact body in that confirmation.
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

Use an actor-serialized, in-process fixed AppleScript handler. Require one
explicit affirmative final confirmation before every submission, on every
destination form. There is no setting, build flag, debug path, environment
variable, or injectable Boolean that can bypass it. Missing-input elicitation
gathers values only and is never treated as authorization; a separate final
confirmation always follows.

Final confirmation has one persisted presentation mode: Automatic, MCP form,
or iMCP app. Missing, unknown, or corrupt values decode as Automatic; no mode
means off. Automatic selects MCP form before authorization begins when the
current connection advertises form elicitation, otherwise it selects the native
iMCP dialog. MCP form never falls back. iMCP app never sends an MCP final-
confirmation request.

Selection occurs once. After an MCP final-confirmation request is dispatched,
decline, cancel, timeout, malformed acceptance, request error, and parent-task
cancellation are terminal and dispatch nothing. They never open a native dialog
for the same send. The native AppKit dialog runs on the main actor, activates
iMCP, presents frontmost Send and Cancel actions, and treats every response
other than the explicit affirmative action as cancellation.

The confirmation displays the exact destination and the exact body. It is the
surface on which a person authorizes an externally visible side effect, so
hiding those values there would make authorization meaningless. They remain
excluded from logs, diagnostics, errors, and tool results.

Request TCC only after a successful confirmation. Pass untrusted values through
descriptors, dispatch no more than one `send` event, and never retry after
dispatch or an ambiguous result.

The recipient path first compares one validated handle with direct-chat
membership. Only a verified no-match may use the plain-text iMessage recipient
path, and its confirmation states that a new direct conversation will be
started. A unique match uses the existing-chat path. Multiple matches fail and
require a chat ID.

Unresolvable membership is distinct from a verified no-match. When a stored
participant cannot be compared exactly — a phone number kept in a local or
formatted style, for instance — and it could still denote the requested
recipient, matching reports incomplete and the call fails with a dedicated
direct-membership error. Treating unresolvable evidence as absence could
abandon an existing SMS or RCS conversation and start a new one on a different
route. A stored handle that could not denote any requested participant, such as
a short code, remains a plain no-match. This does not resolve contacts or match
a participant's group chats.

A complete set of two or more validated remote handles may select only one
existing group whose normalized membership is exactly equal. Ordering and
duplicate relationship rows do not matter. Subsets, supersets, unavailable or
incomplete membership, no match, and ambiguity dispatch nothing. This path
never creates a group; ambiguous callers must provide a chat ID. Email matching
lowercases the trimmed address, while phone matching accepts only already-valid
E.164 and never infers a country code or equates a phone with an email.

The tool also accepts one opaque chat ID produced by the conversation index.
Resolve current safe display metadata before
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

- Permission and confirmation boundaries are explicit and unconditional.
- Clients without MCP form UI can still authorize through the visible native
  iMCP dialog without weakening the confirmation boundary.
- Tests can replace the automation adapter without touching Messages.
- No private database or framework writes are required.

### Negative

- A temporary Apple Events exception is required.
- Script execution is synchronous and cancellation after dispatch is
  inherently ambiguous.
- Submission cannot establish delivery.
- Native confirmation is limited to final send authorization; missing-input and
  generic structured elicitation remain MCP-form-only.
- A recipient whose existing conversation cannot be resolved exactly fails
  rather than sending, so some legitimate sends require an explicit `chat_id`.
- Timeout or cancellation cancels the wrapper's underlying request task but
  cannot retract a prompt the client already displayed; the pinned MCP Swift SDK
  never exposes the elicitation request ID that `Server.cancelRequest` would
  need. A late response is discarded and can never dispatch.

### Risks and mitigations

- Duplicate sends: issue one event and prohibit automatic retry.
- Confirmation bypass: no bypass exists. A regression test asserts the removed
  preference key, settings UI, and injectable predicate have not returned.
- Double prompting: choose one presenter before authorization and never catch an
  MCP failure into native fallback.
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
path, mode defaults and selection, terminal MCP failures with zero native
fallback, native cancellation, shared exact-value authorization content,
missing-input elicitation being distinct from final confirmation, unresolvable
direct membership failing closed, redacted results, fixed script source, and
the at-most-one dispatch invariant.

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
- AppKit `NSAlert` and application activation APIs

# ADR 0008: Contacts-side phone-number normalization via PhoneNumberKit

- Status: Proposed
- Date: 2026-08-10
- Deciders:
- Supersedes:
- Superseded by:

## Context

`contacts_find_conversations` and any other reader of `contacts_search` could
only treat a stored phone number as a Messages identity when it was already
strict E.164. A local-format number — the overwhelming majority of what
Contacts actually stores — contributed no identity at all, because turning it
into E.164 requires knowing which numbering plan it belongs to, and neither
Contacts nor Messages tracked that.

Messages' own exact-only design (ADR 0007, ADR 0005) is deliberately not the
place to add that inference: `MessagesHandleNormalization` and every Messages
send/discovery path must keep working from exact identities only, with no
country guessing. Region interpretation is a Contacts-side concern about what
a stored value *means*, not a Messages-side concern about how to compare two
handles.

## Decision drivers

- Keep Messages exact-only; add no country inference to any Messages
  send/discovery path.
- Never guess a region, try multiple regions, or invent an identity; a value
  that cannot be parsed and validated under one effective region publishes no
  identity.
- Preserve the existing primitive-fact invariant: the composite behind
  `contacts_find_conversations` may derive phone identities only from a public
  Contacts fact, never from richer data `contacts_search` does not itself
  expose.
- Preserve `Person.telephone` unchanged for backward compatibility.
- Make the region a live, dynamically-read setting rather than one snapshotted
  at construction time, so a Settings change or a system region change take
  effect on the next search.

## Options considered

### Option A: Hand-written digit stripping and country-code prefixing

Guess a country from the system region and prepend its calling code after
stripping formatting characters.

Rejected outright by the accepted design (`imessage-mcp/contacts-phone-normalization-design`):
this is exactly the "invent an identity" failure mode the settled behavior
forbids. National significant number formats, trunk prefixes, and length
rules vary per numbering plan; a hand-rolled heuristic would silently produce
wrong E.164 values for many regions.

### Option B: A frozen phone-number library

Numbering plans change (new area codes, new mobile prefixes, format changes).
A frozen, no-longer-maintained fork would drift from reality with no path to
catch up, silently misinterpreting more numbers over time.

### Option C (selected): PhoneNumberKit, the actively maintained fork

[`PhoneNumberKit/PhoneNumberKit`](https://github.com/PhoneNumberKit/PhoneNumberKit),
5.x line (5.0.6 pinned), the actively maintained continuation of the earlier
`marmelroy/PhoneNumberKit`. Pure-Swift, MIT licensed, SwiftPM-compatible,
Swift tools 5.9, macOS 10.15+ — all compatible with this repository's Swift 5
language mode / macOS 15.1 deployment target and its up-to-next-major SPM
convention. Only the core `PhoneNumberKit` library product is linked; no
static/dynamic variant, no Contacts-framework integration flag beyond its
default.

## Decision

Contacts owns regional interpretation and E.164 production:

- A stored value that is already explicit international format (`+...`)
  parses independently of any region setting.
- A local-format value parses using one **effective region**: an explicit
  iMCP Settings override when configured, otherwise the Mac's live system
  region (read via `Locale.autoupdatingCurrent`, never snapshotted).
- If the system supplies no region and there is no override, a local-format
  value publishes no identity rather than falling back to a guessed country.
  An explicit international value remains usable because its own country
  calling code is authoritative.
- If parsing/validation fails under that one effective region, the value
  publishes no E.164 identity. No other region is ever tried.
- One `PhoneNumberUtility` instance is constructed once and reused
  (`PhoneNumberKitNormalizer.shared`) rather than reloading metadata per
  phone number.
- The parser and the effective-region resolver both sit behind narrow
  protocols (`PhoneNumberNormalizing`, `EffectiveRegionProviding`) so domain
  and composite tests inject fakes, while a separate adapter test exercises
  the real library against known-valid fixture numbers.

The stored region setting (`PhoneNumberRegionSetting`, backed by
`UserDefaults` under an explicit key) is either the `.system` sentinel or an
explicit ISO region-code override, validated against PhoneNumberKit's supported regions
on read; an absent, empty, or no-longer-recognized stored value falls back to
`.system` rather than crashing or guessing.

`contacts_search` gains an additive public fact, `ContactRecord`, wrapping the
unchanged `Person` plus `phoneNumbers: [ContactPhoneNumber]` — one entry per
stored phone value, each carrying its raw value (identical to the
corresponding `Person.telephone` entry), its optional Contacts label, and its
optional normalized E.164 identity. `contacts_find_conversations` carries the
same `ContactRecord` shape unchanged, and its composite derives phone
identities only from `phoneNumbers[].e164` plus the existing public email
facts — never from the raw `telephone` field directly, never from `CNContact`, never
from parser or region state.

## Rationale

Splitting "what a stored value normalizes to" (Contacts, region-dependent)
from "is this handle exact enough to act on" (Messages, region-independent)
keeps each side's job small and testable, and keeps the existing composite's
reproducibility invariant intact: `contacts_search` still exposes every fact
`contacts_find_conversations` uses, so a client can reproduce the same result
by calling the public tools and joining them itself.

A live, unsnapshotted effective region means a user who changes their Mac's
region, or picks an explicit override in Settings, sees the next search behave
correctly without restarting the app or reconstructing any service — matching
how every other live setting in this codebase already behaves
(`MessagesSendConfirmationMode`, service enablement).

## Consequences

### Positive

- Local-format Contacts numbers become usable Messages identities without any
  Messages-side inference, closing the gap `docs/messages-conversation-search.md`
  previously documented as "local numbers are skipped".
- One dependency, one shared parser instance, one narrow seam — no change to
  Messages' exact-only guarantees, no change to the composite's ordering,
  deduplication, single-lookup, or zero-identity short-circuit behavior.
- `Person.telephone` (and thus any existing caller reading it) is completely
  unaffected.
- Existing `Person` JSON keys remain at the same level; `phoneNumbers` is one
  additive sibling, so callers do not need to unwrap a new result object.

### Negative

- A new production dependency (PhoneNumberKit) with its own metadata update
  cadence to track via `Package.resolved`.
- `contacts_search` gains a `phoneNumbers` field on each existing flat
  `Person` result. Clients that reject unknown JSON keys must allow that
  additive field.

### Risks and mitigations

- **Risk:** a caller assumes `phoneNumbers[].e164` is present whenever
  `telephone` has an entry. **Mitigation:** tool descriptions and
  `docs/messages-conversation-search.md` state explicitly that a value with no
  `e164` contributes no identity, matching the existing "skip rather than
  guess" language readers already expect from Messages.
- **Risk:** a stale or unsupported Settings override outlives numbering-plan
  metadata. **Mitigation:** `PhoneNumberRegionSetting.decode` validates
  against PhoneNumberKit's supported regions on every read and falls back to
  `.system`.
- **Risk:** metadata drift between PhoneNumberKit releases changes which
  numbers validate. **Mitigation:** pinned via `Package.resolved` with an
  up-to-next-major requirement, consistent with every other dependency in this
  project; upgrades are a reviewed, explicit act.

## Validation

Focused tests cover: an explicit `+E.164` value normalizing identically under
materially different regions; two local-format numbers each normalizing only
under their own matching region (and failing under a mismatched one); an
invalid/garbage local value producing no identity; explicit override
precedence over system region; system region followed dynamically with no
snapshot; a stale/invalid stored override falling back to `.system`; raw
`Person.telephone` staying unchanged while the additive `phoneNumbers` fact is
public; standard-label, custom-label, and nil-label preservation; the
`contacts_search` tool exposing the additive fact; the composite consuming
only the public normalized fact (never falling back to raw `telephone`,
verified directly); phone-before-email order and first-occurrence
deduplication preserved; and existing zero-identity short-circuit and
count-only telemetry behavior unchanged.

## References

- `imessage-mcp/contacts-phone-normalization-design` (Hexa, accepted contract
  for this slice)
- [ADR 0007](0007-reusable-search-operations-behind-mcp-adapters.md)
- [`docs/messages-conversation-search.md`](../messages-conversation-search.md)
- [PhoneNumberKit/PhoneNumberKit](https://github.com/PhoneNumberKit/PhoneNumberKit)

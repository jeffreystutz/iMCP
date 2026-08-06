# iMCP working instructions

Preflight contract: 1

This file is a routing and safety contract. It deliberately does not restate the
project's full architecture, roadmap, or process knowledge. That knowledge lives
in Hexa; this file tells you how to reach it and which rules are non-negotiable
inside this repository.

## Purpose

We are extending iMCP with safe Apple Messages write support and reusable MCP
elicitation capabilities. Prefer changes that are useful to the upstream
project rather than architecture specific only to one user's setup.

## Hexa preflight

Before any implementation task:

1. Retrieve `imessage-mcp/coding-agent-bootstrap` from the Hexa organization
   `imessage-mcp`.
2. Follow the project documents and the `global-instructions` engineering
   documents that the bootstrap routes you to.
3. Read the applicable repository instructions and `docs/decisions/` records.

Authority:

- Hexa holds accepted product intent, scope, decisions, roadmap, and cross-task
  status.
- Git history, code, tests, entitlements, signing configuration, and the
  documents under `docs/` hold implementation truth.
- Prompt logs and prior transcripts are evidence, not current specifications.

Verify `imessage-mcp/current-status` against Git before acting. Report and
reconcile any mismatch explicitly; never silently treat reported work as
committed, pushed, reviewed, accepted, or merged.

If Hexa is unavailable, inaccessible, or does not return the named documents,
stop and report the exact failure before editing. Do not pretend the context was
loaded, and do not substitute a prior conversation summary for retrieval.

Repository instructions point to Hexa rather than copying the Hexa knowledge
corpus. Keep it that way.

## Working model

Full sequencing lives in [`docs/development-workflow.md`](docs/development-workflow.md).
The binding rules:

- Work is single-threaded. Active implementation, pending review, or pending
  manual acceptance blocks unrelated work.
- Every milestone ends with applicable verification, meaningful commits, and a
  normal push to the active user-controlled review branch.
- The coding agent never merges, never pushes directly to the protected base
  branch, never pushes to the maintainer repository, never force-pushes active
  work, and never claims acceptance.
- The supervising ChatGPT reviews the exact pushed head before any manual
  product verification begins.
- Manual or externally observable behavior is not accepted merely because the
  project compiles or automated tests pass.

## Apple Messages safety and privacy

- No real message may be sent without separate explicit authorization of the
  exact destination and the exact body for that manual test.
- Every message submission requires its own accepted form confirmation. There is
  no setting, build flag, debug path, environment variable, or injected
  dependency that may bypass it.
- Product work must preserve the fixed-script, descriptor-input, one-dispatch,
  no-retry, fail-closed architecture. AppleScript source stays fixed; untrusted
  identifiers and message content enter only as Apple Event descriptors.

### What may contain private values

These surfaces exist to serve the user and are allowed to carry the values the
user asked for:

- Documented `messages_list_chats` output may contain the conversation metadata
  its API defines, including participant handles and conversation identifiers.
- The final confirmation elicitation may — and must — contain the exact
  destination and the exact message body, because it is the authorization
  surface. A prompt that hides what is being sent cannot authorize it.
- Tests and documentation may contain unmistakably synthetic, non-real values.

### What must never contain real private values

Real Messages data must never appear in production logs, operational errors,
redacted send results, analytics, test fixtures, assertions, documentation
examples, prompt logs, or commits.

Recipient handles, participant sets, chat identifiers, message bodies,
attachment paths, and raw database rows must stay redacted from ordinary send
results and from every diagnostic.

Use synthetic values such as `example.invalid` handles. Never relax the rule
against logging or committing real private data.
- Apple Events authority belongs to the signed app, never the nested CLI.
- Prefer mocks, fixtures, dry-run behavior, or a designated test recipient.
- Do not modify the sibling `../mac_messages_mcp` repository. Treat it as
  read-only reference material.
- Treat Apple Events permissions, TCC behavior, sandbox entitlements, and
  Messages automation as security-sensitive architecture.
- Do not weaken signing, sandbox, entitlement, permission, or confirmation
  behavior merely to make verification pass.
- Success means submitted to Messages, not delivered. Do not claim delivery from
  submission.

## Required session logging

Maintain local development records under `.codex-log/`. These records are local
evidence and are excluded from version control.

At the beginning of each substantive user task:

1. Append the current local timestamp to `.codex-log/prompts.md`.
2. Append the user's request as closely to verbatim as practical.
3. Redact credentials, tokens, private message text, phone numbers, email
   addresses, contact information, and other sensitive personal data.
4. Note whether the task is planning, implementation, debugging, review, or
   research.

During the task, append significant decisions to
`.codex-log/decisions.md`. For each decision record:

- Date and task
- Context or problem
- Options considered
- Selected option
- Rationale
- Consequences or tradeoffs
- Whether the decision is provisional or durable

Record rejected approaches when understanding why they were rejected would
prevent future rework. Do not log every minor code-editing choice.

At the end of each substantive task, append to `.codex-log/worklog.md`:

- Concise outcome
- Files created or changed
- Commands and tests run
- Results of verification
- Unresolved questions
- Recommended next step

Logging is part of task completion, but logging must not substitute for making
the requested change.

## Architecture decision records

Use `docs/decisions/` for durable architectural decisions.

Create an ADR when a decision is:

- Cross-cutting
- Difficult or expensive to reverse
- Relevant to future contributors
- Related to security, privacy, permissions, protocol behavior, public APIs,
  service boundaries, or persistent data formats
- Likely to be questioned again later

Do not create ADRs for routine implementation details or easily reversible
choices.

New ADRs start with status `Proposed`. Do not mark an ADR `Accepted` unless the
user has explicitly approved the decision or it was already established by the
upstream project.

When an architecture decision changes:

- Preserve the old ADR
- Mark it `Superseded`
- Link it to the replacement ADR
- Update relevant architecture or planning documentation

Keep `docs/decisions/README.md` updated as an ADR index.

## Planning and implementation

For multi-step or architectural work:

1. Inspect the relevant source and documentation.
2. Separate verified facts from assumptions.
3. Identify experiments needed to resolve assumptions.
4. Present or update a concrete plan before changing production code.
5. Implement the smallest coherent, independently testable chunk that reaches a
   meaningful manual checkpoint. See
   [`docs/development-workflow.md`](docs/development-workflow.md) for sizing and
   milestone sequencing.
6. Challenge the requested design when the repository indicates a materially
   better approach. If repository reality materially contradicts the prescribed
   plan, stop and report rather than silently redesigning.

Do not modify production code during a planning-only task.

Update `docs/messages-write-plan.md` whenever findings or decisions materially
change the implementation sequence or architecture.

## Upstream contribution discipline

- Preserve existing read-only behavior unless explicitly changing it.
- Prefer focused upstreamable changes over a long-lived private-fork design.
- Avoid unrelated formatting, renaming, or cleanup.
- Match existing Swift and repository conventions.
- Do not add production dependencies without explaining the need and receiving
  approval.
- Do not rewrite git history, force-push, delete branches, or discard user work.
- Do not commit local logs or private data.
- Clearly identify code adapted from another project and preserve any required
  attribution.
- Do not open maintainer-facing pull requests during feature completion.

## Verification

After implementation:

- Run the narrowest relevant tests first.
- Run the legitimate project-level build and tests when practical.
- Keep DerivedData and generated output in ignored repository-local paths where
  practical.
- Do not disable meaningful signing, sandbox, entitlement, or permission checks
  merely to make verification pass.
- Report exactly what was and was not verified.
- Review the final diff for unrelated changes, sensitive data, regressions, and
  missing documentation.

No verification step may send a real message.

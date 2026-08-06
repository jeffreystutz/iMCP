# Development workflow

This document describes how implementation work on the Apple Messages write
feature is planned, verified, committed, reviewed, and accepted.

The repository-root [`AGENTS.md`](../AGENTS.md) is the entry point and carries
the Hexa preflight contract and the binding safety rules. This document covers
sequencing.

## Authority

- **Hexa** owns accepted product intent, scope, decisions, roadmap, and the
  concise cross-task status handoff. The organization slug is `imessage-mcp`;
  shared engineering policy lives in `global-instructions`.
- **Git, code, tests, entitlements, signing configuration, and the documents
  under `docs/`** own implementation truth.
- **Prompt logs** under `.codex-log/` are trajectory evidence, not
  specifications.

When these disagree, name the conflict explicitly and reconcile it. Status never
overrides Git.

## Active-branch policy

The active review branch containing the accumulated feature-completion work is:

```text
feat/messages-write-foundation
```

Its diff base is the upstream release commit `b84f266` (`upstream/main`, tag
`1.4.1`).

Rules:

- During feature completion this branch is the persistent review branch. It is
  not renamed, reset, or reconstructed. Migrating to another branch requires an
  explicit decision recorded in Hexa.
- Only one implementation or review cycle is active at a time.
- Push with normal non-force pushes to `origin`
  (the user-controlled fork). Never push to `upstream` (the maintainer
  repository), and never push directly to the base branch.
- Upstream pull-request decomposition begins only after the public feature scope
  is complete and hardened.

## Milestone lifecycle

For each milestone:

1. Retrieve Hexa context via `imessage-mcp/coding-agent-bootstrap`.
2. Inspect the exact repository and Git state: branch, upstream tracking,
   remotes, history, worktree, diffs, and any open pull-request state.
3. Verify the assumptions in the supervising prompt against that state.
4. Stop and report if repository reality materially contradicts the prescribed
   architecture. Do not silently redesign.
5. Implement the coherent milestone — the smallest chunk that completes a
   meaningful capability and reaches a useful manual checkpoint. Separate known
   implementation from platform experiments; do not split merely to shrink a
   diff, and do not combine work with independent acceptance gates.
6. Use meaningful internal checkpoint commits when they aid recovery or review.
7. Run focused verification for the changed behavior, then the full applicable
   repository verification.
8. Perform an adversarial self-review of the complete branch diff against the
   base.
9. Stage and commit only task-owned changes. Never absorb unrelated work.
10. Push the active review branch normally.
11. Report exact full commit SHAs, verification commands, and outcomes.
12. Stop for supervising ChatGPT review.
13. Perform manual product verification only after the exact pushed head passes
    supervising review.
14. Never merge as the coding agent.

### Verification entry points

- Lint: `swift format lint --strict --recursive .`
- Build: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" -derivedDataPath .build/DerivedData build`
- Tests: `xcodebuild -quiet -scheme imcp-serverTests -configuration Debug -destination "platform=macOS" -derivedDataPath .build/DerivedData test`
- Elicitation proxy round trip: `python3 CLITests/test_elicitation_proxy.py .build/DerivedData/Build/Products/Debug/iMCP.app/Contents/MacOS/imcp-server`
- Whitespace: `git diff --check`

These mirror `.github/workflows/ci.yml`. No verification step may send a real
message.

## Review and acceptance boundary

- The supervising ChatGPT reviews the **exact pushed head** and the complete
  branch diff. Reports must state the full SHA being reviewed.
- Review corrections are additional commits on the active branch. Reviewed
  commits are not rewritten merely to tidy history.
- A changed branch head invalidates earlier exact-head review conclusions until
  the new head is reviewed.
- Automated tests establish code completion, not acceptance. Permission-gated,
  interactive, or externally observable behavior requires separate human
  acceptance.
- A real Messages send requires separate explicit human authorization of the
  exact destination and the exact body.
- Manual verification must inspect Messages.app before retrying any ambiguous
  submission. No automatic retry or fallback follows a dispatch attempt.

When an environment cannot run a permission-gated or signed interactive check,
complete all safe automated verification, state the exact limitation, and supply
a compact human checklist. Do not invent Accessibility automation, temporary UI
tests, AppleScript sends, or fabricated manual evidence, and do not weaken
security or entitlements to work around the limitation.

## Upstream handoff

- Do not open maintainer-facing pull requests during feature completion unless
  the user explicitly changes the strategy.
- After feature completion and hardening, map the accumulated implementation
  into independently reviewable upstream pull requests.
- Each intermediate pull request must build and test against its predecessor.
- Keep generic MCP infrastructure separable from Messages-specific reading,
  automation, indexing, destination resolution, routing, Contacts, attachments,
  and release documentation.

## Status and evidence

- Keep `imessage-mcp/current-status` concise and exact: one complete
  next-executable-work handoff, verified against Git.
- Status never overrides Git. Replace obsolete state rather than appending
  chronology, and never call pushed work accepted or merged without explicit
  evidence.
- Preserve prompts, commits, test outcomes, review findings, manual
  verification, and failures as trajectory evidence under `.codex-log/` and in
  Hexa trajectory records.
- Do not turn the status document into an implementation journal. Detailed
  narratives belong in `docs/`, decision records, or trajectory records.

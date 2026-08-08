# ADR 0004: Directory-scoped access to the Messages database family

- Status: Proposed
- Date: 2026-07-21

## Context

`messages_list_chats` reads the live Messages SQLite database. A Powerbox
bookmark for only `chat.db` lets the sandbox open the main file but does not
authorize its sibling write-ahead log and shared-memory files. Production
diagnostics verified a sandbox denial for `chat.db-wal`, followed by an SQLite
authorization failure while preparing or executing the listing query.

The listing must include current activity without requesting broad Full Disk
Access or weakening App Sandbox. Existing `messages_fetch` behavior uses a
single-file bookmark and is outside this decision.

## Decision

Chat listing and future chat-identifier resolution will use a distinct,
read-only security-scoped bookmark for a user-selected directory containing
`chat.db`. The security scope stays active only around the database operation.
The SQLite connection is opened with `SQLITE_OPEN_READONLY`, extended result
codes are enabled, and `PRAGMA query_only = ON` is required before a query.

The selected directory is persisted as an **app-scoped** security-scoped
bookmark, so the app declares `com.apple.security.files.bookmarks.app-scope` in
both its Debug and Release entitlements. Bookmark data is created with
`[.withSecurityScope, .securityScopeAllowOnlyReadAccess]` and resolved with
`.withSecurityScope`. Both options are required: `.withSecurityScope` is what
makes the bookmark security-scoped, and the read-only option is only meaningful
alongside it. Omitting either — or omitting the entitlement — fails at runtime
when the bookmark is created, with `NSCocoaErrorDomain` 256, "Failed to retrieve
app-scope key". The same options apply to the legacy single-file `messages_fetch`
bookmark.

Because these guarantees exist only in a signed, sandboxed process, manual
permission and TCC verification must use a correctly signed app. The ordinary
credential-free CI Debug artifact is unsigned and carries no entitlements at
all, so it cannot exercise or validate this behavior. See
[`development-workflow.md`](../development-workflow.md) for the signed
manual-verification build.

The app validates that the selected directory contains a readable `chat.db`.
It stores neither the path nor database metadata in logs. Repository failures
may log only a fixed operation stage and a numeric SQLite result code.

The existing file bookmark remains in place for `messages_fetch`; an existing
file bookmark does not silently authorize or substitute for directory access.

## Alternatives considered

- Opening `chat.db` with `immutable=1` avoids sidecar access but can ignore
  recent WAL-backed changes and therefore cannot reliably provide latest
  activity.
- Full Disk Access is much broader than the selected Messages directory and is
  not required for this design.
- Copying the database is incomplete without coordinating its WAL and adds
  lifecycle, consistency, and sensitive-data handling risks.
- Expanding sandbox exceptions would bypass explicit user selection and make
  distribution behavior more difficult to review.

## Consequences

Users upgrading from the single-file flow must select the Messages directory
once before using chat listing. A versioned startup migration prompts existing
users whose Messages service is already enabled and explains the new
conversation-listing capability and its narrower read-only purpose. Declining
the upgrade preserves existing fetch and send configuration; a later listing
call may request the missing permission again. Bookmark persistence across
ordinary app and system restarts follows the platform security-scoped bookmark mechanism, but
behavior after directory moves, permission revocation, or future Messages
storage migrations is not guaranteed. A stale or unusable bookmark fails
closed and requires renewed selection.

The database remains live and may change concurrently. SQLite supplies the
consistent read transaction; iMCP does not retry side effects or perform any
Apple Events operation as part of listing.

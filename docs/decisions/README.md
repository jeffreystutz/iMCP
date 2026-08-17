# Architecture Decision Records

Architecture Decision Records document consequential technical decisions made
for this project.

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](0001-per-connection-form-elicitation.md) | Proposed | Bind form elicitation to an explicit per-connection tool-call context. |
| [0002](0002-messages-automation-security-boundary.md) | Proposed | Keep confirmed Messages automation in the signed app and issue at most one send event. |
| [0003](0003-opaque-messages-chat-identifiers.md) | Proposed | Wrap Messages chat GUIDs in versioned opaque identifiers and resolve them with exact bound lookups. |
| [0004](0004-directory-scoped-messages-database-access.md) | Proposed | Use a read-only directory bookmark for SQLite access to the live Messages database family. |
| [0005](0005-schema-resilient-messages-conversation-index.md) | Proposed | Discover schema capabilities and assemble bounded summary/full conversation metadata in stages. |
| [0006](0006-new-recipient-system-composition.md) | Proposed | Compose to a recipient with no existing conversation in the system-owned Messages panel instead of a guessed iMessage participant. |
| [0007](0007-reusable-search-operations-behind-mcp-adapters.md) | Proposed | Put contact and conversation search behind reusable operations with thin MCP adapters, and model conversation discovery as conversation evidence rather than send routing. |
| [0008](0008-contacts-phone-number-normalization.md) | Proposed | Normalize Contacts phone numbers to E.164 via PhoneNumberKit under one live effective region, exposed as an additive public Contacts fact; Messages stays exact-only. |
| [0009](0009-attachment-only-existing-chat-submission.md) | Superseded by [0011](0011-unified-messages-send-tool.md) | Submit one picker-selected bounded file to one exact existing conversation through a separate attachment-only tool, with no path in MCP arguments and full post-confirmation revalidation. Its security/validation contract is carried forward unchanged by ADR 0011. |
| [0010](0010-global-automatic-send-authorization-policy.md) | Accepted | Persist one global, binary Sending mode (Ask Before Sending / Send Automatically), app-owned and unreachable by any MCP caller, wired identically into both `message_send_text` and `message_send_attachment`. |
| [0011](0011-unified-messages-send-tool.md) | Superseded by [0012](0012-split-messages-send-tools.md) | Consolidated `messages_send` and `messages_send_attachment` into one public `messages_send` tool with mutually exclusive `body`/`attachment` payloads. Implemented and code-reviewed, but never manually accepted before the user reversed the decision. |
| [0012](0012-split-messages-send-tools.md) | Superseded by [0013](0013-unified-recipients-and-strict-body.md) | Restored two public Messages send tools, `message_send_text` and `message_send_attachment`, one per Messages submission class. Its two-tool split stands; only its `recipient`/`recipients` field shape and missing-body elicitation were later corrected. |
| [0013](0013-unified-recipients-and-strict-body.md) | Accepted | Unify `recipient`/`recipients` into one `recipients` property (scalar-or-array via `oneOf`) on both send tools; require non-empty `message_send_text.body` with no elicitation. ADR 0009's and ADR 0010's contracts, and ADR 0012's two-tool split, carried forward unchanged. |

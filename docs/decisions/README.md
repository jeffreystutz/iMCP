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

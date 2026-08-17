import MCP
import SQLite3
import XCTest

@testable import iMCP

private let chatIdentifierTestKey = Data(repeating: 0xA5, count: 32)

final class MessagesChatListingTests: XCTestCase {
    func testSummaryPreservesCoreFieldsAndUsesMembershipParticipants() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let queries = LockedStrings()
        let index = try repository(observer: { queries.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        )

        XCTAssertEqual(index.detail, .summary)
        XCTAssertEqual(index.chats.map(\.displayName), ["Synthetic Group", "Direct Thread"])
        XCTAssertEqual(index.chats.map(\.kind), [.group, .direct])
        XCTAssertEqual(index.chats.map(\.participantCount), [3, 1])
        XCTAssertNil(index.chats[0].full)
        XCTAssertFalse(queries.values.contains("messages"))
        XCTAssertFalse(queries.values.contains("attachments"))

        let group = index.chats[0]
        XCTAssertEqual(group.chatId, group.id)
        XCTAssertEqual(group.chatGuid, "group-guid.example")
        XCTAssertEqual(group.chatIdentifier, "group-identifier.example")
        XCTAssertEqual(group.groupId, "group-id.example")
        XCTAssertEqual(group.originalGroupId, "original-group-id.example")
        XCTAssertEqual(group.roomName, "Synthetic Room")
        XCTAssertEqual(group.service, "iMessage")
        XCTAssertEqual(group.isArchived, true)
        XCTAssertEqual(group.isFiltered, false)
        XCTAssertNotNil(group.lastReadTimestamp)
        XCTAssertNotNil(group.latestActivity)
        XCTAssertEqual(
            group.participants?.map(\.handle),
            ["+15550100001", "local-number", "person@example.invalid"]
        )
        XCTAssertEqual(group.participants?[0].canonicalE164, "+15550100001")
        XCTAssertNil(group.participants?[1].canonicalE164)
        XCTAssertEqual(group.participants?[2].email, "person@example.invalid")
        XCTAssertEqual(group.participants?[0].originalHandle, "(555) 010-0001")
        XCTAssertEqual(group.participants?[0].country, "US")
        XCTAssertEqual(index.metadataAvailability["mentions"], false)
        XCTAssertEqual(index.metadataAvailability["screened"], false)
    }

    func testDuplicateHandleRowsCollapseToOneParticipantAndStayDirect() throws {
        let fixture = try ChatDatabaseFixture.participantIdentity()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: nil,
            detail: .summary
        )
        let byName = Dictionary(
            uniqueKeysWithValues: index.chats.map { ($0.displayName ?? "", $0) }
        )

        // Same email in two rows differing only by letter case.
        let caseDuplicate = try XCTUnwrap(byName["Case Duplicate"])
        XCTAssertEqual(caseDuplicate.participantCount, 1)
        XCTAssertEqual(caseDuplicate.kind, .direct)
        XCTAssertEqual(caseDuplicate.participants?.map(\.handle), ["person@example.invalid"])

        // Same exact E.164 number in two rows.
        let e164Duplicate = try XCTUnwrap(byName["E164 Duplicate"])
        XCTAssertEqual(e164Duplicate.participantCount, 1)
        XCTAssertEqual(e164Duplicate.kind, .direct)
        XCTAssertEqual(e164Duplicate.participants?.map(\.handle), ["+15550100001"])

        // One identity observed with differing service, country, and original handle.
        let metadataDuplicate = try XCTUnwrap(byName["Metadata Duplicate"])
        XCTAssertEqual(metadataDuplicate.participantCount, 1)
        XCTAssertEqual(metadataDuplicate.kind, .direct)
        let merged = try XCTUnwrap(metadataDuplicate.participants?.first)
        XCTAssertEqual(merged.handle, "meta@example.invalid")
        XCTAssertEqual(merged.services, ["SMS", "iMessage"])
        XCTAssertEqual(merged.countries, ["gb", "us"])
        XCTAssertEqual(merged.originalHandles, ["META@example.invalid", "meta@example.invalid"])
        // Representative values are the deterministic lexicographic minimum.
        XCTAssertEqual(merged.service, "SMS")
        XCTAssertEqual(merged.country, "gb")

        // Duplicate relationship rows for one handle.
        let relationshipDuplicate = try XCTUnwrap(byName["Relationship Duplicate"])
        XCTAssertEqual(relationshipDuplicate.participantCount, 1)
        XCTAssertEqual(relationshipDuplicate.kind, .direct)

        // Two genuinely distinct identities remain a group.
        let realGroup = try XCTUnwrap(byName["Real Group"])
        XCTAssertEqual(realGroup.participantCount, 2)
        XCTAssertEqual(realGroup.kind, .group)

        // A handle that is neither E.164 nor an email is still one participant.
        let shortCode = try XCTUnwrap(byName["Short Code"])
        XCTAssertEqual(shortCode.participantCount, 1)
        XCTAssertEqual(shortCode.kind, .direct)
        XCTAssertEqual(shortCode.participants?.map(\.handle), ["SHORTCODE"])
        XCTAssertNil(shortCode.participants?.first?.canonicalE164)
        XCTAssertNil(shortCode.participants?.first?.email)
    }

    func testCaseDistinctNonEmailHandlesStayTwoIdentitiesAndAppearInTheGroupFilter() throws {
        // "BOT" and "bot" fold together in SQL but are two identities in Swift. The old SQL
        // prefilter excluded this chat from the group query and admitted it to the direct
        // query, where Swift then removed it, so it appeared in neither filtered view.
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }

        let unfiltered = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: nil,
            detail: .summary
        )
        let caseGroup = try XCTUnwrap(
            unfiltered.chats.first { $0.displayName == "Case Group" }
        )
        XCTAssertEqual(caseGroup.participantCount, 2)
        XCTAssertEqual(caseGroup.kind, .group)
        XCTAssertEqual(caseGroup.participants?.map(\.handle), ["BOT", "bot"])

        let groups = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .group,
            detail: .summary
        )
        XCTAssertTrue(groups.chats.contains { $0.displayName == "Case Group" })

        let directs = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .direct,
            detail: .summary
        )
        XCTAssertFalse(directs.chats.contains { $0.displayName == "Case Group" })
    }

    func testCaseDifferentEmailsRemainOneDirectIdentity() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }

        let directs = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .direct,
            detail: .summary
        )
        let emailCase = try XCTUnwrap(
            directs.chats.first { $0.displayName == "Email Case Direct" }
        )
        XCTAssertEqual(emailCase.participantCount, 1)
        XCTAssertEqual(emailCase.kind, .direct)
        XCTAssertEqual(emailCase.participants?.map(\.handle), ["person@example.invalid"])

        let groups = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .group,
            detail: .summary
        )
        XCTAssertFalse(groups.chats.contains { $0.displayName == "Email Case Direct" })
    }

    func testWhitespaceAndNewlinePaddingFollowsSwiftTrimming() throws {
        // SQLite TRIM strips spaces only, so " padded " and "\tpadded\n" would stay two
        // values in SQL. Swift trims whitespace and newlines, making them one identity.
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }

        let directs = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .direct,
            detail: .summary
        )
        let padded = try XCTUnwrap(
            directs.chats.first { $0.displayName == "Whitespace Direct" }
        )
        XCTAssertEqual(padded.participantCount, 1)
        XCTAssertEqual(padded.kind, .direct)
        XCTAssertEqual(padded.participants?.map(\.handle), ["padded"])

        let groups = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .group,
            detail: .summary
        )
        XCTAssertFalse(groups.chats.contains { $0.displayName == "Whitespace Direct" })
    }

    func testFilteredScanPagesPastNonMatchingChatsAndStopsWhenTheLimitIsFilled() throws {
        // Ordering is ROWID descending: 8, 7, 6, 5 are direct fillers; 4 and 3 are direct;
        // 2 is the only group; 1 is direct. With a two-row page the only group appears on
        // the fourth page, which a single-page fetch would never reach.
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }
        let stages = LockedStrings()

        let groups = try repository(filterPageSize: 2, observer: { stages.append($0) })
            .listChats(
                databasePath: fixture.path,
                limit: 1,
                kind: .group,
                detail: .summary
            )

        XCTAssertEqual(groups.chats.compactMap(\.displayName), ["Case Group"])
        // Pages covering rows 8/7, 6/5, 4/3, then 2/1 where the match is found.
        XCTAssertEqual(stages.values.filter { $0 == "chats" }.count, 4)
    }

    func testFilteredScanStopsEarlyOncePageYieldsTheRequestedLimit() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }
        let stages = LockedStrings()

        let directs = try repository(filterPageSize: 2, observer: { stages.append($0) })
            .listChats(
                databasePath: fixture.path,
                limit: 2,
                kind: .direct,
                detail: .summary
            )

        // The first page already holds two direct chats, so scanning stops immediately.
        XCTAssertEqual(directs.chats.count, 2)
        XCTAssertEqual(stages.values.filter { $0 == "chats" }.count, 1)
    }

    func testFilteredResultsPreserveUnfilteredSourceOrdering() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }

        let unfiltered = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: nil,
            detail: .summary
        )
        let expected = unfiltered.chats.filter { $0.kind == .direct }.map(\.id)

        let directs = try repository(filterPageSize: 3).listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .direct,
            detail: .summary
        )
        XCTAssertEqual(directs.chats.map(\.id), expected)
        XCTAssertFalse(expected.isEmpty)
    }

    func testFilteredResultIsShortOnlyWhenTheSourceIsExhausted() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }
        let stages = LockedStrings()

        let groups = try repository(filterPageSize: 2, observer: { stages.append($0) })
            .listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: .group,
                detail: .summary
            )

        // Only one group exists, so fewer than `limit` rows come back — but only after the
        // scan reached an empty page, proving the source was genuinely exhausted.
        XCTAssertEqual(groups.chats.count, 1)
        XCTAssertEqual(stages.values.filter { $0 == "chats" }.count, 5)
    }

    func testFilteredFullDetailFetchesMetadataOnlyForSelectedChats() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }
        let stages = LockedStrings()

        _ = try repository(filterPageSize: 2, observer: { stages.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 1,
            kind: .group,
            detail: .full
        )

        // Four header pages were scanned, but the expensive aggregates ran once, after the
        // final selection — not once per scanned page.
        XCTAssertEqual(stages.values.filter { $0 == "chats" }.count, 4)
        XCTAssertEqual(stages.values.filter { $0 == "messages" }.count, 1)
        XCTAssertEqual(stages.values.filter { $0 == "attachments" }.count, 1)
    }

    func testParticipantFilterContainsAllAndComposesWithKind() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }

        let groupParticipants: Set<String> = ["+15550100001", "person@example.invalid"]
        let matches = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            participants: groupParticipants,
            detail: .summary
        )
        XCTAssertEqual(matches.chats.map(\.displayName), ["Synthetic Group"])
        XCTAssertEqual(matches.chats.first?.participantCount, 3)

        let groups = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: .group,
            participants: ["+15550100001"],
            detail: .summary
        )
        XCTAssertEqual(groups.chats.map(\.displayName), ["Synthetic Group"])

        let directs = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: .direct,
            participants: ["+15550100001"],
            detail: .summary
        )
        XCTAssertTrue(directs.chats.isEmpty)

        let partial = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            participants: ["person@example.invalid", "absent@example.invalid"],
            detail: .summary
        )
        XCTAssertTrue(partial.chats.isEmpty)
    }

    func testParticipantFilterUsesAuthoritativeEmailPhoneAndOtherIdentitySemantics() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }

        let email = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            participants: [MessagesHandleIdentity.identity(" PERSON@example.invalid ")!],
            detail: .summary
        )
        XCTAssertEqual(email.chats.map(\.displayName), ["Email Case Direct"])

        let exactOther = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            participants: [MessagesHandleIdentity.identity("BOT")!],
            detail: .summary
        )
        XCTAssertEqual(exactOther.chats.map(\.displayName), ["Case Group"])

        let differentCase = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            participants: [MessagesHandleIdentity.identity("Bot")!],
            detail: .summary
        )
        XCTAssertTrue(differentCase.chats.isEmpty)

        let phoneFixture = try ChatDatabaseFixture.participantIdentity()
        defer { phoneFixture.remove() }
        let phone = try repository().listChats(
            databasePath: phoneFixture.path,
            limit: 10,
            kind: .direct,
            participants: [MessagesHandleIdentity.identity("+15550100001")!],
            detail: .summary
        )
        XCTAssertEqual(phone.chats.map(\.displayName), ["E164 Duplicate"])
    }

    func testParticipantFilteredPagingAppliesLimitAfterFilteringAndStopsEarly() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }

        let lateStages = LockedStrings()
        let late = try repository(filterPageSize: 2, observer: { lateStages.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 1,
            kind: nil,
            participants: ["tail@example.invalid"],
            detail: .summary
        )
        XCTAssertEqual(late.chats.map(\.displayName), ["Tail Direct"])
        XCTAssertEqual(lateStages.values.filter { $0 == "chats" }.count, 4)

        let earlyStages = LockedStrings()
        let early = try repository(filterPageSize: 2, observer: { earlyStages.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 1,
            kind: nil,
            participants: ["filler-d@example.invalid"],
            detail: .summary
        )
        XCTAssertEqual(early.chats.map(\.displayName), ["Filler D"])
        XCTAssertEqual(earlyStages.values.filter { $0 == "chats" }.count, 1)
    }

    func testParticipantFilteredOrderingExhaustionAndFullEnrichmentStayBounded() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }
        try fixture.execute("INSERT INTO chat_handle_join VALUES (8, 11), (5, 11);")

        let stages = LockedStrings()
        let limited = try repository(filterPageSize: 2, observer: { stages.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 2,
            kind: nil,
            participants: ["tail@example.invalid"],
            detail: .full
        )
        XCTAssertEqual(limited.chats.map(\.displayName), ["Filler D", "Filler A"])
        XCTAssertEqual(stages.values.filter { $0 == "messages" }.count, 1)
        XCTAssertEqual(stages.values.filter { $0 == "attachments" }.count, 1)

        let allStages = LockedStrings()
        let all = try repository(filterPageSize: 2, observer: { allStages.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            participants: ["tail@example.invalid"],
            detail: .summary
        )
        XCTAssertEqual(all.chats.map(\.displayName), ["Filler D", "Filler A", "Tail Direct"])
        XCTAssertEqual(allStages.values.filter { $0 == "chats" }.count, 5)
    }

    func testTimeoutDuringFilteredScanFailsInsteadOfReturningAPartialPage() throws {
        let fixture = try ChatDatabaseFixture.identityAndPaging()
        defer { fixture.remove() }
        let pageCount = LockedCounter()

        // Deterministically outlive the deadline part-way through the scan: the second page
        // request blocks past the timeout, so the scan cannot complete.
        let repo = repository(
            timeout: 0.2,
            filterPageSize: 2,
            observer: { stage in
                guard stage == "chats", pageCount.increment() == 2 else { return }
                Thread.sleep(forTimeInterval: 0.4)
            }
        )

        do {
            let index = try repo.listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: nil,
                participants: ["tail@example.invalid"],
                detail: .summary
            )
            XCTFail("Expected a timeout, got \(index.chats.count) conversations")
        } catch let error as MessagesChatRepositoryError {
            guard case .queryFailed = error else {
                return XCTFail("Expected a query failure, got \(error)")
            }
        }
    }

    func testUnreadableHandlesReportIdentityUnavailableAndRejectKindFilters() throws {
        let fixture = try ChatDatabaseFixture.unreadableHandles()
        defer { fixture.remove() }

        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        )

        // Chat metadata still comes back, but nothing may be inferred from relationship or
        // handle row IDs — two handle rows and a duplicate join row create no participants.
        XCTAssertEqual(index.chats.count, 1)
        let chat = index.chats[0]
        XCTAssertEqual(chat.displayName, "Unreadable Handles")
        XCTAssertNil(chat.kind)
        XCTAssertNil(chat.participantCount)
        XCTAssertNil(chat.participants)
        XCTAssertEqual(index.metadataAvailability["participants"], false)
        XCTAssertEqual(index.metadataAvailability["participantCount"], false)
        XCTAssertEqual(index.metadataAvailability["kind"], false)

        for kind in [MessagesChatKind.direct, .group] {
            do {
                _ = try repository().listChats(
                    databasePath: fixture.path,
                    limit: 10,
                    kind: kind,
                    detail: .summary
                )
                XCTFail("Expected \(kind.rawValue) filtering to fail without readable handles")
            } catch let error as MessagesChatRepositoryError {
                XCTAssertEqual(error.diagnosticStage, "kind-unavailable")
            }
        }

        XCTAssertThrowsError(
            try repository().listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: nil,
                participants: ["person@example.invalid"],
                detail: .summary
            )
        ) { error in
            XCTAssertEqual(
                (error as? MessagesChatRepositoryError)?.diagnosticStage,
                "participants-unavailable"
            )
        }
    }

    func testProductionSQLDerivesNoIdentityFromRelationshipRowIDs() throws {
        // Behavioral tests above are primary; this guards the specific SQL shortcuts that
        // caused the defect from reappearing. Comments are stripped so explanatory prose
        // cannot fail the check.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("App/Services/MessagesChatRepository.swift"),
            encoding: .utf8
        )
        let code =
            source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains("COUNT(DISTINCT handle_id)"))
        XCTAssertFalse(code.contains("LOWER(TRIM("))
    }

    func testKindFilterCannotDisagreeWithReturnedClassification() throws {
        let fixture = try ChatDatabaseFixture.participantIdentity()
        defer { fixture.remove() }

        let directs = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .direct,
            detail: .summary
        )
        XCTAssertFalse(directs.chats.isEmpty)
        XCTAssertTrue(directs.chats.allSatisfy { $0.kind == .direct })
        XCTAssertEqual(
            Set(directs.chats.compactMap(\.displayName)),
            [
                "Case Duplicate", "E164 Duplicate", "Metadata Duplicate",
                "Relationship Duplicate", "Short Code", "Local Format",
            ]
        )

        let groups = try repository().listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: .group,
            detail: .summary
        )
        XCTAssertTrue(groups.chats.allSatisfy { $0.kind == .group })
        XCTAssertEqual(groups.chats.compactMap(\.displayName), ["Real Group"])
    }

    func testListingAndChatResolutionAgreeOnParticipantIdentity() throws {
        let fixture = try ChatDatabaseFixture.participantIdentity()
        defer { fixture.remove() }
        let repo = repository()
        let index = try repo.listChats(
            databasePath: fixture.path,
            limit: 50,
            kind: nil,
            detail: .summary
        )

        for chat in index.chats {
            let resolved = try repo.resolveChatDestination(chat.id, databasePath: fixture.path)
            XCTAssertEqual(
                resolved.participantCount,
                chat.participantCount,
                "participant count disagreed for \(chat.displayName ?? chat.id)"
            )
            XCTAssertEqual(
                resolved.kind,
                chat.kind,
                "kind disagreed for \(chat.displayName ?? chat.id)"
            )
            XCTAssertEqual(
                resolved.participantHandles.sorted(),
                (chat.participants ?? []).map(\.handle).sorted(),
                "participant identities disagreed for \(chat.displayName ?? chat.id)"
            )
        }
    }

    func testSendMatchingUsesTheSameIdentityAsListing() throws {
        let fixture = try ChatDatabaseFixture.participantIdentity()
        defer { fixture.remove() }
        let repo = repository()

        // A duplicated-case email resolves to exactly one existing direct conversation.
        let caseMatch = try repo.matchConversation(
            normalizedParticipants: ["person@example.invalid"],
            kind: .direct,
            databasePath: fixture.path
        )
        guard case .unique(_, let destination) = caseMatch else {
            return XCTFail("Expected a unique direct match, got \(caseMatch)")
        }
        XCTAssertEqual(destination.chatGuid, "case-guid.example")
        XCTAssertEqual(destination.participantCount, 1)
        XCTAssertEqual(destination.kind, .direct)

        // The exact remote set of the real group matches regardless of order.
        let groupMatch = try repo.matchConversation(
            normalizedParticipants: ["second@example.invalid", "first@example.invalid"],
            kind: .group,
            databasePath: fixture.path
        )
        guard case .unique(_, let group) = groupMatch else {
            return XCTFail("Expected a unique group match, got \(groupMatch)")
        }
        XCTAssertEqual(group.chatGuid, "group-guid.example")
        XCTAssertEqual(group.participantCount, 2)

        // A subset of the group never matches.
        XCTAssertEqual(
            try repo.matchConversation(
                normalizedParticipants: ["first@example.invalid"],
                kind: .direct,
                databasePath: fixture.path
            ),
            .none
        )
    }

    func testNonmatchableStoredParticipantMakesMatchingIncomplete() throws {
        let fixture = try ChatDatabaseFixture.participantIdentity()
        defer { fixture.remove() }
        let repo = repository()

        // "(555) 010-0009" is stored in a local format that is not valid E.164, and no
        // country code may be inferred to decide whether it is this recipient. The request
        // therefore cannot be ruled out and must report incomplete, never a confident
        // no-match that would start a new conversation on a different route.
        XCTAssertEqual(
            try repo.matchConversation(
                normalizedParticipants: ["+15550100009"],
                kind: .direct,
                databasePath: fixture.path
            ),
            .incomplete
        )

        // A short code cannot denote a phone number or an email, so it stays a plain
        // no-match and does not block unrelated sends.
        XCTAssertEqual(
            try repo.matchConversation(
                normalizedParticipants: ["+15559999999"],
                kind: .direct,
                databasePath: fixture.path
            ),
            .none
        )

        // The unresolvable single member cannot complete a two-participant request, so
        // exact group matching still resolves normally.
        guard
            case .unique(_, let group) = try repo.matchConversation(
                normalizedParticipants: ["first@example.invalid", "second@example.invalid"],
                kind: .group,
                databasePath: fixture.path
            )
        else {
            return XCTFail("Expected the exact group match to remain resolvable")
        }
        XCTAssertEqual(group.chatGuid, "group-guid.example")
    }

    func testFullMetadataCountsOnlyUserVisibleBaseMessages() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: .group,
            detail: .full
        )
        let metadata = try XCTUnwrap(index.chats.first?.full)

        XCTAssertEqual(metadata.messageCount, 9)
        XCTAssertEqual(metadata.incomingMessageCount, 6)
        XCTAssertEqual(metadata.outgoingMessageCount, 3)
        XCTAssertEqual(metadata.unreadIncomingCount, 6)
        XCTAssertEqual(metadata.failedOutgoingCount, 1)
        XCTAssertEqual(metadata.reactionEventCount, 2)
        XCTAssertEqual(metadata.reactionAddCount, 1)
        XCTAssertEqual(metadata.reactionRemoveCount, 1)
        XCTAssertEqual(metadata.replyCount, 1)
        XCTAssertEqual(metadata.editedMessageCount, 1)
        XCTAssertEqual(metadata.retractionCount, 1)
        XCTAssertEqual(metadata.expressiveEffectMessageCount, 1)
        XCTAssertEqual(metadata.pluginMessageCount, 1)
        XCTAssertNil(metadata.mentionCount)
        XCTAssertEqual(index.metadataAvailability["mentions"], false)

        XCTAssertEqual(metadata.latestIncomingMessage?.messageGuid, "retracted-message.example")
        XCTAssertEqual(metadata.latestOutgoingMessage?.messageGuid, "failed-message.example")
        XCTAssertEqual(metadata.latestOutgoingMessage?.deliveryState, "failed")
        XCTAssertEqual(metadata.latestActivity?.messageGuid, "system-event.example")
        XCTAssertFalse(metadata.latestActivity?.messageGuid.contains("body") ?? true)
    }

    func testAttachmentAggregatesDeduplicateJoinsAndExposeOnlyCategories() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: .group,
            detail: .full
        )
        let metadata = try XCTUnwrap(index.chats.first?.full)
        XCTAssertEqual(metadata.hasAttachments, true)
        XCTAssertEqual(metadata.attachmentCount, 2)
        XCTAssertEqual(metadata.messagesWithAttachmentsCount, 1)
        XCTAssertEqual(metadata.attachmentCountByMediaCategory, ["image": 1, "other": 1])
        XCTAssertEqual(metadata.stickerAttachmentCount, 1)
        XCTAssertEqual(
            metadata.latestAttachmentTimestamp?.timeIntervalSinceReferenceDate,
            806_281_604
        )

        let data = try JSONEncoder().encode(index)
        let encoded = String(data: data, encoding: .utf8)!
        XCTAssertFalse(encoded.contains("synthetic-private-filename"))
        XCTAssertFalse(encoded.contains("/private/synthetic"))
        XCTAssertFalse(encoded.contains("synthetic message body"))

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let chats = try XCTUnwrap(object["chats"] as? [[String: Any]])
        let group = try XCTUnwrap(chats.first { $0["kind"] as? String == "group" })
        let full = try XCTUnwrap(group["full"] as? [String: Any])
        XCTAssertEqual(full["latestAttachmentTimestamp"] as? String, "2026-07-20T23:06:44Z")
        XCTAssertTrue(group["lastReadTimestamp"] is String)
        XCTAssertTrue(group["latestActivity"] is String)
        XCTAssertTrue(full["latestReplyTimestamp"] is String)
        XCTAssertTrue(full["latestReactionEventTimestamp"] is String)
        XCTAssertTrue(full["latestEditTimestamp"] is String)
        XCTAssertTrue(full["latestRetractionTimestamp"] is String)
        let latestActivity = try XCTUnwrap(full["latestActivity"] as? [String: Any])
        XCTAssertTrue(latestActivity["timestamp"] is String)
    }

    func testDuplicateParticipantsDeduplicateButPhoneAndEmailRemainDistinct() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let group = try XCTUnwrap(
            repository().listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: .group,
                detail: .summary
            ).chats.first
        )
        XCTAssertEqual(group.participants?.count, 3)
        XCTAssertEqual(Set(group.participants?.map(\.handle) ?? []).count, 3)
    }

    func testConversationMatchingUsesExactNormalizedMembershipSets() throws {
        let fixture = try ChatDatabaseFixture.reduced()
        defer { fixture.remove() }
        try fixture.execute(
            """
            INSERT INTO chat VALUES
              (2, 'direct-match.example', 'Direct Match', 'iMessage'),
              (3, 'group-match.example', 'Group Match', 'RCS'),
              (4, 'larger-group.example', 'Larger Group', 'iMessage');
            INSERT INTO handle VALUES
              (1, 'direct@example.invalid'),
              (2, 'FIRST@example.invalid'),
              (3, '+15550100002'),
              (4, 'third@example.invalid');
            INSERT INTO chat_handle_join VALUES
              (2, 1), (3, 2), (3, 2), (3, 3), (4, 2), (4, 3), (4, 4);
            """
        )
        let repository = repository()

        let direct = try repository.matchConversation(
            normalizedParticipants: ["direct@example.invalid"],
            kind: .direct,
            databasePath: fixture.path
        )
        guard case .unique(_, let directDestination) = direct else {
            return XCTFail("Expected one synthetic direct match")
        }
        XCTAssertEqual(directDestination.kind, .direct)

        let exact = try repository.matchConversation(
            normalizedParticipants: ["first@example.invalid", "+15550100002"],
            kind: .group,
            databasePath: fixture.path
        )
        guard case .unique(_, let groupDestination) = exact else {
            return XCTFail("Expected one synthetic group match")
        }
        XCTAssertEqual(groupDestination.participantCount, 2)
        XCTAssertEqual(
            groupDestination.participantHandles,
            ["+15550100002", "first@example.invalid"]
        )

        XCTAssertEqual(
            try repository.matchConversation(
                normalizedParticipants: ["first@example.invalid", "third@example.invalid"],
                kind: .group,
                databasePath: fixture.path
            ),
            .none
        )
        XCTAssertEqual(
            try repository.matchConversation(
                normalizedParticipants: [
                    "first@example.invalid", "+15550100002", "third@example.invalid",
                    "fourth@example.invalid",
                ],
                kind: .group,
                databasePath: fixture.path
            ),
            .none
        )

        try fixture.execute(
            """
            INSERT INTO chat VALUES (5, 'group-match.example', 'Group Match', 'RCS');
            INSERT INTO chat_handle_join VALUES (5, 2), (5, 3);
            """
        )
        guard
            case .unique = try repository.matchConversation(
                normalizedParticipants: ["first@example.invalid", "+15550100002"],
                kind: .group,
                databasePath: fixture.path
            )
        else { return XCTFail("Equivalent rows for one public chat should deduplicate") }

        try fixture.execute(
            """
            INSERT INTO chat VALUES (6, 'duplicate-group.example', 'Duplicate Group', 'SMS');
            INSERT INTO chat_handle_join VALUES (6, 2), (6, 3);
            """
        )
        XCTAssertEqual(
            try repository.matchConversation(
                normalizedParticipants: ["first@example.invalid", "+15550100002"],
                kind: .group,
                databasePath: fixture.path
            ),
            .ambiguous
        )

        XCTAssertNil(MessagesHandleNormalization.normalize("5550100002"))
        XCTAssertEqual(
            MessagesHandleNormalization.normalize("Mixed@Example.Invalid"),
            "mixed@example.invalid"
        )
    }

    func testReducedSchemaDegradesOptionalFieldsAndKeepsCoreListing() throws {
        let fixture = try ChatDatabaseFixture.reduced()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .full
        )
        let chat = try XCTUnwrap(index.chats.first)
        XCTAssertEqual(chat.displayName, "Reduced Chat")
        XCTAssertEqual(chat.participants, [])
        XCTAssertEqual(chat.participantCount, 0)
        XCTAssertNil(chat.roomName)
        XCTAssertNil(chat.isArchived)
        XCTAssertEqual(index.metadataAvailability["roomName"], false)
        XCTAssertEqual(index.metadataAvailability["archived"], false)
        XCTAssertEqual(index.metadataAvailability["attachments"], false)
        XCTAssertEqual(index.metadataAvailability["reactions"], true)
        XCTAssertNil(chat.full?.attachmentCount)
        XCTAssertEqual(chat.full?.reactionEventCount, 0)
        XCTAssertEqual(chat.full?.messageCount, 1)
    }

    func testMessageDateFallbackOrdersVariantWithoutJoinDateColumn() throws {
        let fixture = try ChatDatabaseFixture.reduced()
        defer { fixture.remove() }
        try fixture.execute(
            """
            INSERT INTO chat (ROWID, guid, display_name, service_name)
            VALUES (2, 'newer-guid.example', 'Newer Chat', 'iMessage');
            INSERT INTO message (ROWID, guid, date, is_from_me, is_read,
              is_system_message, is_service_message, is_empty, item_type,
              associated_message_type)
            VALUES (2, 'newer-message.example', 9000000000, 0, 1, 0, 0, 0, 0, 0);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (2, 2);
            """
        )
        let chats = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        ).chats
        XCTAssertEqual(chats.map(\.displayName), ["Newer Chat", "Reduced Chat"])
    }

    func testMissingMembershipMarksParticipantsUnavailableWithoutHistoryFallback() throws {
        let fixture = try ChatDatabaseFixture.identityOnly()
        defer { fixture.remove() }
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        )
        XCTAssertNil(index.chats.first?.participants)
        XCTAssertNil(index.chats.first?.participantCount)
        XCTAssertNil(index.chats.first?.kind)
        XCTAssertEqual(index.metadataAvailability["participants"], false)
    }

    func testMissingMinimumIdentityFailsWithRedactedError() throws {
        let fixture = try ChatDatabaseFixture.withoutSchema()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try repository().listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: nil,
                detail: .summary
            )
        ) { error in
            XCTAssertEqual(error as? MessagesChatRepositoryError, .minimumSchemaUnavailable)
            XCTAssertEqual(
                error.localizedDescription,
                "The Messages database does not expose a safe conversation identity."
            )
        }
    }

    func testQueryCountIsBoundedAndSummarySkipsFullStages() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let summaryQueries = LockedStrings()
        _ = try repository(observer: { summaryQueries.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .summary
        )
        XCTAssertEqual(summaryQueries.values, ["snapshot", "chats", "participants", "snapshot"])

        let fullQueries = LockedStrings()
        _ = try repository(observer: { fullQueries.append($0) }).listChats(
            databasePath: fixture.path,
            limit: 1,
            kind: nil,
            detail: .full
        )
        XCTAssertEqual(
            fullQueries.values,
            ["snapshot", "chats", "participants", "messages", "attachments", "snapshot"]
        )
    }

    func testFullModeRemainsBoundedOnLargeSyntheticHistory() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        try fixture.execute(
            """
            WITH RECURSIVE sequence(value) AS (
              SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 10000
            )
            INSERT INTO message (
              ROWID, guid, date, is_from_me, service, is_delivered, is_sent,
              is_finished, error, is_read, is_system_message, is_service_message,
              is_empty, item_type, associated_message_type
            )
            SELECT 1000 + value, 'bulk-' || value || '.example',
              20000000000 + value, value % 2, 'iMessage', 0, 1, 1, 0, 1, 0, 0, 0, 0, 0
            FROM sequence;
            INSERT INTO chat_message_join (chat_id, message_id, message_date)
            SELECT 1, ROWID, date FROM message WHERE ROWID >= 1001;
            """
        )
        let start = ContinuousClock.now
        let index = try repository().listChats(
            databasePath: fixture.path,
            limit: 1,
            kind: nil,
            detail: .full
        )
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(index.chats.count, 1)
        XCTAssertEqual(index.chats[0].full?.messageCount, 10001)
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    func testRepositoryDoesNotWriteOrModifySchema() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let schemaVersion = try fixture.scalar("PRAGMA schema_version")
        let messageCount = try fixture.scalar("SELECT COUNT(*) FROM message")
        _ = try repository().listChats(
            databasePath: fixture.path,
            limit: 10,
            kind: nil,
            detail: .full
        )
        XCTAssertEqual(try fixture.scalar("PRAGMA schema_version"), schemaVersion)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM message"), messageCount)
    }

    func testTimeoutFailsWithStableRedactedCode() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try repository(timeout: 0).listChats(
                databasePath: fixture.path,
                limit: 10,
                kind: nil,
                detail: .summary
            )
        ) { error in
            guard case .queryFailed(let stage, let code) = error as? MessagesChatRepositoryError
            else { return XCTFail("Expected a redacted timeout failure") }
            XCTAssertTrue(["chats-step", "cancelled-or-timeout"].contains(stage))
            XCTAssertEqual(code, SQLITE_INTERRUPT)
        }
    }

    func testIdentifierIsStableAndResolutionRejectsInvalidAndStaleValues() throws {
        let fixture = try ChatDatabaseFixture.full()
        defer { fixture.remove() }
        let codec = MessagesChatIdentifierCodec(keyData: chatIdentifierTestKey)
        let identifier = try codec.create(for: "group-guid.example")
        XCTAssertEqual(identifier, try codec.create(for: "group-guid.example"))
        XCTAssertEqual(
            try repository().resolveChatIdentifier(identifier, databasePath: fixture.path),
            "group-guid.example"
        )
        let destination = try repository().resolveChatDestination(
            identifier,
            databasePath: fixture.path
        )
        XCTAssertEqual(destination.chatGuid, "group-guid.example")
        XCTAssertEqual(destination.displayName, "Synthetic Group")
        XCTAssertEqual(destination.roomName, "Synthetic Room")
        XCTAssertEqual(destination.kind, .group)
        XCTAssertEqual(destination.participantCount, 3)
        XCTAssertEqual(
            destination.participantHandles,
            ["+15550100001", "local-number", "person@example.invalid"]
        )
        XCTAssertEqual(destination.service, "iMessage")
        XCTAssertThrowsError(
            try repository().resolveChatIdentifier("invalid", databasePath: fixture.path)
        ) { XCTAssertEqual($0 as? MessagesChatRepositoryError, .invalidIdentifier) }
        let stale = try codec.create(for: "stale-guid.example")
        XCTAssertThrowsError(try repository().resolveChatIdentifier(stale, databasePath: fixture.path)) {
            XCTAssertEqual($0 as? MessagesChatRepositoryError, .staleIdentifier)
        }

        try fixture.execute(
            "INSERT INTO chat (guid, display_name) VALUES ('group-guid.example', 'Duplicate');"
        )
        XCTAssertThrowsError(
            try repository().resolveChatDestination(identifier, databasePath: fixture.path)
        ) { error in
            guard case .queryFailed(let stage, _) = error as? MessagesChatRepositoryError else {
                return XCTFail("Expected ambiguous identifier resolution")
            }
            XCTAssertEqual(stage, "resolve-duplicate")
        }
    }

    func testToolDefaultsNormalizesParticipantsAndValidatesInputs() async throws {
        let recording = RecordingChatRepository()
        let tool = try chatTool(repository: recording)
        _ = try await tool([:], context: ToolCallContext(elicitation: UnsupportedElicitation()))
        _ = try await tool(
            [
                "limit": .int(100),
                "kind": .string("group"),
                "participants": .array([
                    .string(" Person@Example.invalid "), .string("person@example.invalid"),
                ]),
                "detail": .string("full"),
            ],
            context: ToolCallContext(elicitation: UnsupportedElicitation())
        )
        XCTAssertEqual(
            recording.requests,
            [
                .init(limit: 30, kind: nil, participants: nil, detail: .summary),
                .init(
                    limit: 100,
                    kind: .group,
                    participants: ["person@example.invalid"],
                    detail: .full
                ),
            ]
        )

        for arguments: [String: Value] in [
            ["limit": .int(0)], ["limit": .int(101)], ["kind": .string("unknown")],
            ["detail": .string("verbose")], ["participants": .array([])],
            ["participants": .array([.string("  ")])],
        ] {
            do {
                _ = try await tool(arguments, context: ToolCallContext(elicitation: UnsupportedElicitation()))
                XCTFail("Expected invalid conversation-index arguments to fail")
            } catch is MessagesChatListingError {}
        }
        XCTAssertEqual(recording.requests.count, 2)
    }

    func testExistingFetchAndSendContractsRemainUnchanged() throws {
        let service = MessageService(
            sender: NonDispatchingSender(),
            chatRepository: RecordingChatRepository(),
            chatDatabasePathOverride: "/synthetic/chat.db"
        )
        let list = try XCTUnwrap(service.tools.first { $0.name == "messages_list_chats" })
        let fetch = try XCTUnwrap(service.tools.first { $0.name == "messages_fetch" })
        let send = try XCTUnwrap(service.tools.first { $0.name == "message_send_text" })
        XCTAssertEqual(list.annotations.readOnlyHint, true)
        XCTAssertEqual(fetch.annotations.readOnlyHint, true)
        XCTAssertEqual(send.annotations.readOnlyHint, false)
        XCTAssertEqual(send.annotations.idempotentHint, false)

        let encoder = JSONEncoder()
        let fetchSchema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(fetch.inputSchema)) as? [String: Any]
        )
        let sendSchema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(send.inputSchema)) as? [String: Any]
        )
        let listSchema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(list.inputSchema)) as? [String: Any]
        )
        XCTAssertEqual(
            Set((listSchema["properties"] as? [String: Any] ?? [:]).keys),
            Set(["limit", "kind", "participants", "detail"])
        )
        XCTAssertEqual(
            Set((fetchSchema["properties"] as? [String: Any] ?? [:]).keys),
            Set(["participants", "start", "end", "query", "limit"])
        )
        XCTAssertEqual(
            Set((sendSchema["properties"] as? [String: Any] ?? [:]).keys),
            Set(["recipients", "chat_id", "body"])
        )
        XCTAssertEqual(sendSchema["required"] as? [String], ["body"])
    }

    func testMessagesFetchLimitIsBoundedAndInvalidValuesAreRejected() throws {
        let service = MessageService(
            sender: NonDispatchingSender(),
            chatRepository: RecordingChatRepository(),
            chatDatabasePathOverride: "/synthetic/chat.db"
        )
        let fetch = try XCTUnwrap(service.tools.first { $0.name == "messages_fetch" })

        let encoder = JSONEncoder()
        let fetchSchema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(fetch.inputSchema)) as? [String: Any]
        )
        let properties = try XCTUnwrap(fetchSchema["properties"] as? [String: Any])
        let limitSchema = try XCTUnwrap(properties["limit"] as? [String: Any])
        let defaultValue = try XCTUnwrap(limitSchema["default"] as? Int)
        let minimumValue = try XCTUnwrap(limitSchema["minimum"] as? Int)
        let maximumValue = try XCTUnwrap(limitSchema["maximum"] as? Int)

        // The database fetch always scans exactly this many rows, so a request cannot
        // force an unbounded scan by asking for a larger limit than the schema allows.
        XCTAssertEqual(maximumValue, 1024)

        XCTAssertEqual(try resolveMessagesFetchLimit(nil), defaultValue)
        XCTAssertEqual(try resolveMessagesFetchLimit(.int(minimumValue)), minimumValue)
        XCTAssertEqual(try resolveMessagesFetchLimit(.int(maximumValue)), maximumValue)

        for invalid in [0, -1, maximumValue + 1] {
            do {
                _ = try resolveMessagesFetchLimit(.int(invalid))
                XCTFail("Expected messages_fetch limit \(invalid) to be rejected")
            } catch MessagesFetchError.invalidLimit {}
        }
    }

    private func repository(
        timeout: TimeInterval = 5,
        filterPageSize: Int = SQLiteMessagesChatRepository.defaultFilterPageSize,
        observer: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SQLiteMessagesChatRepository {
        SQLiteMessagesChatRepository(
            identifierKey: chatIdentifierTestKey,
            timeout: timeout,
            filterPageSize: filterPageSize,
            queryObserver: observer
        )
    }

    private func chatTool(repository: RecordingChatRepository) throws -> iMCP.Tool {
        let service = MessageService(
            sender: NonDispatchingSender(),
            chatRepository: repository,
            chatDatabasePathOverride: "/synthetic/chat.db",
            chatListingLog: { _ in }
        )
        return try XCTUnwrap(service.tools.first { $0.name == "messages_list_chats" })
    }
}

private struct RecordedRequest: Equatable {
    let limit: Int
    let kind: MessagesChatKind?
    let participants: Set<String>?
    let detail: MessagesChatDetail
}

private final class RecordingChatRepository: MessagesChatListing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [RecordedRequest] = []
    var requests: [RecordedRequest] { lock.withLock { storedRequests } }

    func listChats(
        databasePath: String,
        limit: Int,
        kind: MessagesChatKind?,
        participants: Set<String>?,
        detail: MessagesChatDetail
    ) throws -> MessagesConversationIndex {
        lock.withLock {
            storedRequests.append(
                .init(limit: limit, kind: kind, participants: participants, detail: detail)
            )
        }
        return MessagesConversationIndex(detail: detail, metadataAvailability: [:], chats: [])
    }

    func resolveChatIdentifier(_ identifier: String, databasePath: String) throws -> String {
        try MessagesChatIdentifierCodec(keyData: chatIdentifierTestKey).validate(identifier)
        return "synthetic-guid.example"
    }

    func resolveChatDestination(
        _ identifier: String,
        databasePath: String
    ) throws -> MessagesResolvedChatDestination {
        try MessagesChatIdentifierCodec(keyData: chatIdentifierTestKey).validate(identifier)
        return MessagesResolvedChatDestination(
            chatGuid: "synthetic-guid.example",
            displayName: "Synthetic conversation",
            roomName: nil,
            kind: .direct,
            participantCount: 1,
            participantHandles: ["recipient@example.invalid"],
            service: "iMessage"
        )
    }
}

private struct NonDispatchingSender: MessagesSending {
    func automationAuthorization() -> MessagesAutomationAuthorization {
        XCTFail("Conversation indexing must not consult Messages automation")
        return .denied
    }

    func requestAutomationAuthorization() throws {
        XCTFail("Conversation indexing must not request automation permission")
    }

    func isChatAddressable(chatGUID: String) throws -> Bool {
        XCTFail("Conversation indexing must not send Apple Events")
        return false
    }

    func submit(recipient: String, body: String) throws {
        XCTFail("Conversation indexing must not dispatch a message")
    }

    func submit(chatGUID: String, body: String) throws {
        XCTFail("Conversation indexing must not dispatch a message")
    }

    func submitChatAttachment(chatGUID: String, attachmentFile: URL) throws {
        XCTFail("Conversation indexing must not dispatch an attachment")
    }
}

private struct UnsupportedElicitation: ElicitationRequester {
    let supportsFormElicitation = false

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        throw ElicitationRequestError.formUnsupported
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    /// Increments and returns the new value.
    func increment() -> Int {
        lock.withLock {
            storedValue += 1
            return storedValue
        }
    }
}

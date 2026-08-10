import Contacts
import Foundation
import MCP
import Ontology
import XCTest

@testable import iMCP

/// The reusable contact-search operation and the thin `contacts_search` adapter over it.
///
/// Nothing here reads the user's Contacts database: the adapter tests inject a fake
/// operation, and the predicate tests inspect the predicate the production operation would
/// hand to Contacts.
final class ContactSearchTests: XCTestCase {
    func testToolDelegatesEveryCriterionToTheSearchOperation() async throws {
        let searcher = RecordingContactSearcher()
        let tool = try searchTool(searcher: searcher)

        _ = try await tool(
            [
                "name": .string("Synthetic Person"),
                "phone": .string("+15550100001"),
                "email": .string("person@example.invalid"),
            ],
            context: ToolCallContext(elicitation: UnsupportedContactElicitation())
        )

        XCTAssertEqual(
            searcher.queries,
            [
                ContactSearchQuery(
                    name: "Synthetic Person",
                    phone: "+15550100001",
                    email: "person@example.invalid"
                )
            ]
        )
    }

    func testToolRepresentsOmittedAndNonStringArgumentsAsAbsent() async throws {
        let searcher = RecordingContactSearcher()
        let tool = try searchTool(searcher: searcher)

        _ = try await tool(
            ["name": .string("Synthetic Person"), "phone": .int(5)],
            context: ToolCallContext(elicitation: UnsupportedContactElicitation())
        )

        XCTAssertEqual(searcher.queries, [ContactSearchQuery(name: "Synthetic Person")])
    }

    func testToolReturnsTheOperationsPeopleUnchanged() async throws {
        let searcher = RecordingContactSearcher(
            result: [
                contactRecord(name: "Synthetic Person"),
                contactRecord(name: "Second Person"),
            ]
        )
        let tool = try searchTool(searcher: searcher)

        let value = try await tool(
            ["name": .string("Synthetic")],
            context: ToolCallContext(elicitation: UnsupportedContactElicitation())
        )

        let records = try XCTUnwrap(value.arrayValue)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].objectValue?["givenName"]?.stringValue, "Synthetic")
        XCTAssertEqual(records[1].objectValue?["familyName"]?.stringValue, "Person")
        XCTAssertNil(records[0].objectValue?["person"])
    }

    func testToolExposesTheAdditivePhoneFactAlongsideUnchangedRawTelephone() async throws {
        // The raw stored value survives unchanged in `telephone`, and the additive
        // `phoneNumbers` fact carries the same raw value plus its label and, only when the
        // effective region parsed and validated it, its E.164 identity.
        let record = ContactRecord(
            person: {
                var person = Person(name: "Synthetic Person")
                person.telephone = ["(555) 010-0001", "+15550100002"]
                return person
            }(),
            phoneNumbers: [
                ContactPhoneNumber(value: "(555) 010-0001", label: "mobile", e164: nil),
                ContactPhoneNumber(value: "+15550100002", label: nil, e164: "+15550100002"),
            ]
        )
        let searcher = RecordingContactSearcher(result: [record])
        let tool = try searchTool(searcher: searcher)

        let value = try await tool(
            ["name": .string("Synthetic")],
            context: ToolCallContext(elicitation: UnsupportedContactElicitation())
        )

        let entry = try XCTUnwrap(value.arrayValue?.first?.objectValue)
        XCTAssertNil(entry["person"])
        XCTAssertEqual(entry["@type"]?.stringValue, "Person")
        XCTAssertEqual(entry["givenName"]?.stringValue, "Synthetic")
        XCTAssertNotNil(entry["phoneNumbers"])
        XCTAssertEqual(
            entry["telephone"]?.arrayValue?.map(\.stringValue),
            ["(555) 010-0001", "+15550100002"]
        )

        let phoneNumbers = try XCTUnwrap(entry["phoneNumbers"]?.arrayValue)
        XCTAssertEqual(phoneNumbers.count, 2)
        XCTAssertEqual(phoneNumbers[0].objectValue?["value"]?.stringValue, "(555) 010-0001")
        XCTAssertEqual(phoneNumbers[0].objectValue?["label"]?.stringValue, "mobile")
        // A value that did not normalize omits `e164` entirely rather than a misleading key.
        XCTAssertNil(phoneNumbers[0].objectValue?["e164"])
        XCTAssertEqual(phoneNumbers[1].objectValue?["value"]?.stringValue, "+15550100002")
        XCTAssertNil(phoneNumbers[1].objectValue?["label"])
        XCTAssertEqual(phoneNumbers[1].objectValue?["e164"]?.stringValue, "+15550100002")
    }

    func testToolSurfacesTheOperationsFailure() async throws {
        let tool = try searchTool(searcher: RecordingContactSearcher())

        do {
            _ = try await tool(
                [:],
                context: ToolCallContext(elicitation: UnsupportedContactElicitation())
            )
            XCTFail("An empty search should have been rejected")
        } catch let error as ContactSearchError {
            XCTAssertEqual(error, .noSearchCriteria)
            XCTAssertEqual(
                error.localizedDescription,
                "At least one valid search parameter is required"
            )
        }
    }

    func testEmptySearchIsRejectedByTheProductionOperation() {
        for query in [
            ContactSearchQuery(),
            ContactSearchQuery(name: "   "),
            ContactSearchQuery(email: " "),
            ContactSearchQuery(name: "", email: ""),
        ] {
            XCTAssertThrowsError(try CNContactStoreSearch.predicate(for: query)) { error in
                XCTAssertEqual(error as? ContactSearchError, .noSearchCriteria)
            }
        }
    }

    func testOneCriterionProducesOneUncompoundedPredicate() throws {
        let predicate = try CNContactStoreSearch.predicate(for: ContactSearchQuery(name: "Synthetic"))
        XCTAssertNil(predicate as? NSCompoundPredicate)
    }

    func testSeveralCriteriaCombineWithAnd() throws {
        let predicate = try CNContactStoreSearch.predicate(
            for: ContactSearchQuery(
                name: "Synthetic Person",
                phone: "+15550100001",
                email: "person@example.invalid"
            )
        )

        let compound = try XCTUnwrap(predicate as? NSCompoundPredicate)
        XCTAssertEqual(compound.compoundPredicateType, .and)
        XCTAssertEqual(compound.subpredicates.count, 3)
    }

    func testBlankNameAndEmailContributeNoCriterionWhilePhoneAlwaysDoes() throws {
        // A phone number is passed to Contacts exactly as supplied, including an empty
        // string, so supplying only a phone always produces a searchable criterion.
        XCTAssertNoThrow(try CNContactStoreSearch.predicate(for: ContactSearchQuery(phone: "")))

        let predicate = try CNContactStoreSearch.predicate(
            for: ContactSearchQuery(name: "  ", phone: "+15550100001", email: "  ")
        )
        XCTAssertNil(predicate as? NSCompoundPredicate)
    }

    func testTheOperationCanBeFakedWithoutTouchingContacts() async throws {
        let searcher = RecordingContactSearcher(result: [contactRecord(name: "Synthetic Person")])
        let records = try await searcher.search(ContactSearchQuery(name: "Synthetic"))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(searcher.queries, [ContactSearchQuery(name: "Synthetic")])
    }

    func testContactsToolSurfaceIsUnchanged() throws {
        let service = contactsService(searcher: RecordingContactSearcher())
        XCTAssertEqual(
            service.tools.map(\.name),
            [
                "contacts_me",
                "contacts_search",
                "contacts_find_conversations",
                "contacts_update",
                "contacts_create",
            ]
        )

        let search = try XCTUnwrap(service.tools.first { $0.name == "contacts_search" })
        XCTAssertEqual(search.annotations.title, "Search Contacts")
        XCTAssertEqual(search.annotations.readOnlyHint, true)
        XCTAssertEqual(search.annotations.openWorldHint, false)
        XCTAssertTrue(search.description.hasPrefix("Search contacts by name, phone number, and/or email"))

        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(search.inputSchema))
                as? [String: Any]
        )
        XCTAssertEqual(
            Set((schema["properties"] as? [String: Any] ?? [:]).keys),
            Set(["name", "phone", "email"])
        )
        XCTAssertNil(schema["required"])
    }

    private func searchTool(searcher: any ContactSearching) throws -> iMCP.Tool {
        let service = contactsService(searcher: searcher)
        return try XCTUnwrap(service.tools.first { $0.name == "contacts_search" })
    }

    /// A Contacts service whose Messages seam fails the test if anything reaches it, so
    /// these tests also assert that `contacts_search` never consults Messages.
    private func contactsService(searcher: any ContactSearching) -> ContactsService {
        ContactsService(
            contactSearch: searcher,
            conversationLookup: UnconsultedConversationLookup(),
            conversationSearchLog: { _ in }
        )
    }

    /// A contact record with no phone values, for tests that only care about the unchanged
    /// `Person` fields.
    private func contactRecord(name: String) -> ContactRecord {
        ContactRecord(person: Person(name: name), phoneNumbers: [])
    }
}

private struct UnconsultedConversationLookup: MessagesConversationLookup {
    func findConversations(
        handles: [String],
        limitPerHandle: Int
    ) async throws -> MessagesConversationSearchResult {
        XCTFail("Contact search must not look up conversations")
        return MessagesConversationSearchResult(metadataAvailability: [:], results: [])
    }
}

private final class RecordingContactSearcher: ContactSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var storedQueries: [ContactSearchQuery] = []
    private let result: [ContactRecord]

    init(result: [ContactRecord] = []) { self.result = result }

    var queries: [ContactSearchQuery] { lock.withLock { storedQueries } }

    func search(_ query: ContactSearchQuery) async throws -> [ContactRecord] {
        // The production operation rejects a criterion-free query before reaching Contacts;
        // the fake reproduces that so adapter tests observe the same behavior.
        _ = try CNContactStoreSearch.predicate(for: query)
        lock.withLock { storedQueries.append(query) }
        return result
    }
}

private struct UnsupportedContactElicitation: ElicitationRequester {
    let supportsFormElicitation = false

    func requestForm(
        message: String,
        schema: Elicitation.RequestSchema
    ) async throws -> CreateElicitation.Result {
        XCTFail("Contact search must not elicit")
        throw ElicitationRequestError.formUnsupported
    }
}

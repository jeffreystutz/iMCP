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
            result: [Person(name: "Synthetic Person"), Person(name: "Second Person")]
        )
        let tool = try searchTool(searcher: searcher)

        let value = try await tool(
            ["name": .string("Synthetic")],
            context: ToolCallContext(elicitation: UnsupportedContactElicitation())
        )

        let people = try XCTUnwrap(value.arrayValue)
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(people[0].objectValue?["givenName"]?.stringValue, "Synthetic")
        XCTAssertEqual(people[1].objectValue?["familyName"]?.stringValue, "Person")
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
        let searcher = RecordingContactSearcher(result: [Person(name: "Synthetic Person")])
        let people = try await searcher.search(ContactSearchQuery(name: "Synthetic"))
        XCTAssertEqual(people.count, 1)
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
        XCTAssertEqual(search.description, "Search contacts by name, phone number, and/or email")

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
    private let result: [Person]

    init(result: [Person] = []) { self.result = result }

    var queries: [ContactSearchQuery] { lock.withLock { storedQueries } }

    func search(_ query: ContactSearchQuery) async throws -> [Person] {
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

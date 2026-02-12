import XCTest
@testable import Palace

class TPPAccountListDataSourceTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a test Account with the given name and uuid.
    private func makeAccount(name: String, uuid: String = UUID().uuidString) -> Account {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: nil,
            id: uuid,
            title: name
        )
        let publication = OPDS2Publication(
            links: [],
            metadata: metadata,
            images: nil
        )
        return Account(publication: publication, imageCache: MockImageCache())
    }

    /// Extracts all account names from the data source in display order (section 0 then section 1).
    private func allNames(from dataSource: TPPAccountListDataSource) -> [String] {
        var names: [String] = []
        for section in 0..<2 {
            let count = dataSource.accounts(in: section)
            for row in 0..<count {
                let account = dataSource.account(at: IndexPath(row: row, section: section))
                names.append(account.name)
            }
        }
        return names
    }

    // MARK: - Sorting Tests

    /// Regression test for PP-3671: Library names starting with a lowercase letter
    /// (e.g. "eRead Kids") were sorted to the bottom of the list because the sort
    /// was case-sensitive. They should appear in proper alphabetical position.
    func testLoadData_MixedCaseLibraryNames_SortsCaseInsensitively() {
        // Arrange — names deliberately chosen to expose case-sensitive sorting.
        // Case-sensitive sort would produce: Austin, Baltimore, Zion, eRead
        // Case-insensitive sort should produce: Austin, Baltimore, eRead, Zion
        let accounts = [
            makeAccount(name: "Zion Public Library"),
            makeAccount(name: "eRead Kids - Springfield"),
            makeAccount(name: "Austin Public Library"),
            makeAccount(name: "Baltimore County Library")
        ]

        let dataSource = TPPAccountListDataSource(
            accountsProvider: { accounts },
            nationalAccountUUIDs: []
        )

        // Act — loadData is called during init, accounts are in section 1 (no nationals)
        let names = allNames(from: dataSource)

        // Assert — "eRead" should sort between Baltimore and Zion, not at the end
        XCTAssertEqual(names, [
            "Austin Public Library",
            "Baltimore County Library",
            "eRead Kids - Springfield",
            "Zion Public Library"
        ])
    }

    /// Verifies national accounts are separated into section 0 and still sorted case-insensitively.
    func testLoadData_WithNationalAccounts_SeparatesAndSortsCaseInsensitively() {
        let nationalUUID = "urn:uuid:national-1"
        let accounts = [
            makeAccount(name: "Zion Public Library"),
            makeAccount(name: "eRead Kids - Springfield"),
            makeAccount(name: "Palace Bookshelf", uuid: nationalUUID),
            makeAccount(name: "Austin Public Library")
        ]

        let dataSource = TPPAccountListDataSource(
            accountsProvider: { accounts },
            nationalAccountUUIDs: [nationalUUID]
        )

        // Section 0 = national accounts
        XCTAssertEqual(dataSource.accounts(in: 0), 1)
        XCTAssertEqual(dataSource.account(at: IndexPath(row: 0, section: 0)).name, "Palace Bookshelf")

        // Section 1 = non-national accounts, sorted case-insensitively
        XCTAssertEqual(dataSource.accounts(in: 1), 3)
        let nonNationalNames = (0..<3).map {
            dataSource.account(at: IndexPath(row: $0, section: 1)).name
        }
        XCTAssertEqual(nonNationalNames, [
            "Austin Public Library",
            "eRead Kids - Springfield",
            "Zion Public Library"
        ])
    }

    /// Verifies that the search filter works correctly with mixed-case names.
    func testLoadData_WithFilter_FiltersCaseInsensitively() {
        let accounts = [
            makeAccount(name: "eRead Kids - Springfield"),
            makeAccount(name: "Austin Public Library"),
            makeAccount(name: "eRead Illinois")
        ]

        let dataSource = TPPAccountListDataSource(
            accountsProvider: { accounts },
            nationalAccountUUIDs: []
        )

        // Act
        dataSource.loadData("eread")

        // Assert — filter is already case-insensitive, both eRead libraries should match
        let names = allNames(from: dataSource)
        XCTAssertEqual(names, [
            "eRead Illinois",
            "eRead Kids - Springfield"
        ])
    }
}

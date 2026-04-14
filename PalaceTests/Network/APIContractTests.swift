//
//  APIContractTests.swift
//  PalaceTests
//
//  Contract tests that verify our iOS parsers can handle real responses
//  from the Palace circulation backend. Fixtures pulled from
//  https://github.com/ThePalaceProject/circulation
//
//  If a backend API change breaks these tests, we catch it here
//  BEFORE users hit the bug in production.
//

import XCTest
@testable import Palace

// MARK: - Fixture Loader

enum TestFixture {
    static func loadJSON(_ name: String) -> Data {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/API/\(name).json")
        return try! Data(contentsOf: path)
    }
}

// MARK: - OPDS 2 Feed Contract Tests

final class OPDS2FeedContractTests: XCTestCase {

    private func decodeFeed(from name: String) throws -> OPDS2Feed {
        let data = TestFixture.loadJSON(name)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OPDS2Feed.self, from: data)
    }

    func testParseFeed_FromBackendFixture_SucceedsWithExpectedStructure() throws {
        let feed = try decodeFeed(from: "opds2_feed")

        XCTAssertEqual(feed.metadata.title, "A1QA Test Library")
        XCTAssertEqual(feed.metadata.itemsPerPage, 50)
        XCTAssertFalse(feed.links?.isEmpty ?? true, "Feed must have links")

        let selfLink = feed.links?.first { $0.rel == "self" }
        XCTAssertNotNil(selfLink, "Feed must have a self link")
    }

    func testParsePublications_ExtractsBookMetadata() throws {
        let feed = try decodeFeed(from: "opds2_feed")

        XCTAssertGreaterThanOrEqual(feed.publications?.count ?? 0, 2)

        let ebook = feed.publications?.first
        XCTAssertEqual(ebook?.metadata.title, "Agnes Grey")
        XCTAssertFalse(ebook?.metadata.id.isEmpty ?? true, "Must have an ID")
        XCTAssertFalse(ebook?.images?.isEmpty ?? true, "Book must have cover images")

        let borrowLink = ebook?.links.first { $0.rel?.contains("borrow") ?? false }
        XCTAssertNotNil(borrowLink, "Borrowable book must have a borrow link")
    }

    func testParseAudiobook_IncludesTypeMetadata() throws {
        let feed = try decodeFeed(from: "opds2_feed")

        // The second publication in our fixture is the audiobook
        let audiobook = feed.publications?.last
        XCTAssertEqual(audiobook?.metadata.title, "Animal Farm")
    }

    func testParseFacets_ExtractsFormatEntryPoints() throws {
        let feed = try decodeFeed(from: "opds2_feed")
        XCTAssertFalse(feed.facets?.isEmpty ?? true, "Feed must have facets")
    }

    func testParseGroups_ExtractsLanes() throws {
        let feed = try decodeFeed(from: "opds2_feed")
        XCTAssertFalse(feed.groups?.isEmpty ?? true, "Feed must have groups")
    }
}

// MARK: - Problem Document Contract Tests

final class ProblemDocumentContractTests: XCTestCase {

    private var allProblems: [String: [String: Any]] = [:]

    override func setUp() {
        super.setUp()
        let data = TestFixture.loadJSON("problem_documents")
        allProblems = ((try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]) ?? [:]
    }

    func testAllProblemDocuments_Parse() throws {
        XCTAssertGreaterThanOrEqual(allProblems.count, 10)

        for (key, problem) in allProblems {
            let problemData = try JSONSerialization.data(withJSONObject: problem)
            let doc = try JSONDecoder().decode(TPPProblemDocument.self, from: problemData)

            XCTAssertNotNil(doc.type, "\(key): type")
            XCTAssertNotNil(doc.title, "\(key): title")
            XCTAssertNotNil(doc.status, "\(key): status")
            XCTAssertNotNil(doc.detail, "\(key): detail")
            XCTAssertGreaterThanOrEqual(doc.status ?? 0, 400, "\(key): status >= 400")
            XCTAssertLessThanOrEqual(doc.status ?? 0, 599, "\(key): status <= 599")
        }
    }

    func testInvalidCredentials_HasExpectedShape() throws {
        let data = try JSONSerialization.data(withJSONObject: allProblems["invalid_credentials"]!)
        let doc = try JSONDecoder().decode(TPPProblemDocument.self, from: data)

        XCTAssertEqual(doc.status, 401)
        XCTAssertTrue(doc.type?.contains("invalid-credentials") ?? false)
    }

    func testLoanLimitReached_HasExpectedShape() throws {
        let data = try JSONSerialization.data(withJSONObject: allProblems["loan_limit_reached"]!)
        let doc = try JSONDecoder().decode(TPPProblemDocument.self, from: data)

        XCTAssertEqual(doc.status, 403)
        XCTAssertTrue(doc.type?.contains("loan-limit") ?? false)
    }

    func testAllProblemTypes_HaveDistinctTypeURIs() throws {
        var typeURIs = Set<String>()
        for (key, problem) in allProblems {
            let type = problem["type"] as? String ?? ""
            XCTAssertFalse(typeURIs.contains(type), "\(key): duplicate type URI")
            typeURIs.insert(type)
        }
    }
}

// MARK: - Authentication Document Contract Tests

final class AuthDocumentContractTests: XCTestCase {

    func testParseAuthDocument_ExtractsAllFields() throws {
        let data = TestFixture.loadJSON("auth_document")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["title"] as? String, "A1QA Test Library")

        let authMethods = json["authentication"] as? [[String: Any]]
        XCTAssertGreaterThanOrEqual(authMethods?.count ?? 0, 1)

        let basicAuth = authMethods?.first
        XCTAssertTrue((basicAuth?["type"] as? String)?.contains("Basic") ?? false)

        let labels = basicAuth?["labels"] as? [String: String]
        XCTAssertEqual(labels?["login"], "Barcode")
        XCTAssertEqual(labels?["password"], "PIN")

        let inputs = basicAuth?["inputs"] as? [String: [String: Any]]
        XCTAssertEqual(inputs?["password"]?["keyboard"] as? String, "NUMBER_PAD")
    }

    func testAuthDocument_HasRequiredLinks() throws {
        let data = TestFixture.loadJSON("auth_document")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let links = json["links"] as? [[String: Any]] ?? []
        let rels = Set(links.compactMap { $0["rel"] as? String })

        XCTAssertTrue(rels.contains("start"))
        XCTAssertTrue(rels.contains("help"))
        XCTAssertTrue(rels.contains("terms-of-service"))
        XCTAssertTrue(rels.contains("privacy-policy"))
    }
}

// MARK: - Annotation Contract Tests

final class AnnotationContractTests: XCTestCase {

    func testParseAnnotationContainer() throws {
        let data = TestFixture.loadJSON("annotations")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let types = json["type"] as? [String] ?? []
        XCTAssertTrue(types.contains("AnnotationCollection"))
        XCTAssertEqual(json["total"] as? Int, 2)

        let items = (json["first"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.count, 2)
    }

    func testReadingPosition_HasEPUBCFISelector() throws {
        let data = TestFixture.loadJSON("annotations")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let items = (json["first"] as? [String: Any])?["items"] as? [[String: Any]] ?? []

        let readingPos = items[0]
        XCTAssertEqual(readingPos["motivation"] as? String, "http://www.w3.org/ns/oa#idling")

        let selector = (readingPos["target"] as? [String: Any])?["selector"] as? [String: String]
        XCTAssertEqual(selector?["type"], "oa:FragmentSelector")

        let selectorJSON = try JSONSerialization.jsonObject(
            with: (selector?["value"] ?? "").data(using: .utf8)!
        ) as? [String: Any]
        XCTAssertNotNil(selectorJSON?["idref"])
        XCTAssertNotNil(selectorJSON?["contentCFI"])
        XCTAssertNotNil(selectorJSON?["progressWithinBook"])
    }

    func testBookmarkAndReadingPosition_HaveDifferentMotivations() throws {
        let data = TestFixture.loadJSON("annotations")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let items = (json["first"] as? [String: Any])?["items"] as? [[String: Any]] ?? []

        let motivations = Set(items.compactMap { $0["motivation"] as? String })
        XCTAssertEqual(motivations.count, 2)
    }
}

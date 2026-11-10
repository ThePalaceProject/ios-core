//
//  LibraryServiceProcessingTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

/// PP-5473 — a book that fails to open must stop showing as processing. The
/// open clears the flag through the registry, which tells the screens.
@MainActor
final class LibraryServiceProcessingTests: XCTestCase {

    func testOpenSampleFailure_ClearsTheBooksProcessingFlag() async throws {
        let registry = TPPBookRegistryMock()
        let book = try XCTUnwrap(TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Missing Sample",
            "categories": ["Fiction"],
            "id": "library-service-missing-sample",
            "updated": "2024-01-01T00:00:00Z"
        ]))
        registry.setProcessing(true, for: book.identifier)
        let service = LibraryService(bookRegistry: registry)
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).epub")

        let failed: Bool = await withCheckedContinuation { continuation in
            service.openSample(book, sampleURL: missingFile, sender: UIViewController()) { result in
                if case .failure = result { continuation.resume(returning: true) } else { continuation.resume(returning: false) }
            }
        }

        XCTAssertTrue(failed, "precondition: a missing file fails to open")
        XCTAssertFalse(registry.processing(forIdentifier: book.identifier))
    }
}

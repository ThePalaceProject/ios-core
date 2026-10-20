//
//  SupportReportContextTests.swift
//  PalaceTests
//
//  Support emails and exported diagnostics carry a hashed patron reference,
//  never the raw library card barcode (PP-4818).
//

import TriageBotCore
import XCTest
@testable import Palace

@MainActor
final class SupportReportContextTests: PalaceWiringTestCase {

    /// The reference is the triage bot's token, so support can match a legacy
    /// report to bot tickets from the same patron.
    func testRawIdentifier_isHashedWithTheTriageBotToken() {
        let context = SupportReportContext(rawPatronIdentifier: "23333098765432", libraryName: nil, libraryUUID: nil)

        XCTAssertEqual(context.patronReference, ContextRedactor().hashIdentifier("23333098765432"))
        XCTAssertNotEqual(context.patronReference, "23333098765432")
    }

    func testMissingOrEmptyIdentifier_hasNoReferenceOrLine() {
        for raw in [nil, ""] as [String?] {
            let context = SupportReportContext(rawPatronIdentifier: raw, libraryName: "Lib", libraryUUID: nil)
            XCTAssertNil(context.patronReference, "raw: \(String(describing: raw))")
            XCTAssertNil(context.patronReferenceLine, "raw: \(String(describing: raw))")
        }
    }

    func testReferenceLine_namesTheHashedToken() {
        let context = SupportReportContext(rawPatronIdentifier: "12345678901234", libraryName: nil, libraryUUID: nil)

        XCTAssertEqual(context.patronReferenceLine, "Patron reference: \(ContextRedactor().hashIdentifier("12345678901234"))")
    }

    /// The exported diagnostics carry the same reference, not the barcode.
    func testErrorLogDeviceInfo_signedIn_carriesTheReferenceNotTheBarcode() async {
        let barcode = "23333098765432"
        let exporter = ErrorLogExporter(
            accountsManager: makeFreshAccountsManager(defaults: Self.testUserDefaults()),
            bookRegistry: TPPBookRegistryMock(),
            supportContext: { SupportReportContext(rawPatronIdentifier: barcode, libraryName: "Lib", libraryUUID: nil) }
        )

        let info = await exporter.collectDeviceInfo()

        XCTAssertFalse(info.contains(barcode), "the raw barcode must not reach the exported diagnostics")
        XCTAssertTrue(info.contains("Patron reference: \(ContextRedactor().hashIdentifier(barcode))"))
    }

    func testErrorLogDeviceInfo_signedOut_saysSo() async {
        let exporter = ErrorLogExporter(
            accountsManager: makeFreshAccountsManager(defaults: Self.testUserDefaults()),
            bookRegistry: TPPBookRegistryMock(),
            supportContext: { SupportReportContext(rawPatronIdentifier: nil, libraryName: nil, libraryUUID: nil) }
        )

        let info = await exporter.collectDeviceInfo()

        XCTAssertTrue(info.contains("Patron reference: not signed in"))
    }
}

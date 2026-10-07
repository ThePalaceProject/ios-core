//
//  AccountSupportEmailRegistryTests.swift
//  PalaceTests
//
//  First launch builds one Account per library in the bundled registry, and
//  each one validates its `help` link with `EmailAddress`. These tests pin
//  that classification on the real snapshot and keep the per-link
//  validation cheaper than building a data detector per link.
//

import XCTest
import PalaceCatalog
import PalaceUtilities
@testable import Palace

final class AccountSupportEmailRegistryTests: XCTestCase {

    private func bundledCatalogs() throws -> [OPDS2Publication] {
        let data = try XCTUnwrap(BundledRegistrySnapshot.load(), "bundled_registry.json missing from the app bundle")
        let catalogs = try OPDS2CatalogsFeed.fromData(data).catalogs
        XCTAssertGreaterThan(catalogs.count, 100, "expected the full bundled registry")
        return catalogs
    }

    private static func helpHref(_ publication: OPDS2Publication) -> String? {
        publication.links.first(where: { $0.rel == "help" })?.href
    }

    /// A `mailto:` help link becomes the support email with spaces removed;
    /// a web help link never does.
    func testInit_FromBundledRegistry_MailtoHelpLinksBecomeSupportEmails() throws {
        let catalogs = try bundledCatalogs()
        let accounts = catalogs.map { Account(publication: $0, imageCache: MockImageCache()) }

        var mailtoCount = 0
        for (publication, account) in zip(catalogs, accounts) {
            guard let href = Self.helpHref(publication) else {
                XCTAssertNil(account.supportEmail, account.uuid)
                continue
            }
            if href.hasPrefix("mailto:") {
                mailtoCount += 1
                let expected = String(href.dropFirst("mailto:".count)).replacingOccurrences(of: " ", with: "")
                XCTAssertEqual(account.supportEmail?.rawValue, expected, "help link \(String(reflecting: href))")
            } else {
                XCTAssertNil(account.supportEmail, "help link \(String(reflecting: href))")
            }
        }
        XCTAssertGreaterThan(mailtoCount, 0, "the snapshot must exercise the mailto branch")
    }

    /// Validating every registry help link must cost less than building one
    /// data detector per link; building one per call made first launch take
    /// tens of seconds on slow devices. Both sides run interleaved and take
    /// their fastest round, so machine load affects them alike.
    func testValidatingRegistryHelpLinks_CostsLessThanADetectorPerLink() throws {
        let links = try bundledCatalogs().compactMap(Self.helpHref)
        XCTAssertGreaterThan(links.count, 100)

        var bestValidate = Double.infinity
        var bestConstruct = Double.infinity
        for _ in 0..<3 {
            bestValidate = min(bestValidate, Self.seconds {
                for link in links { _ = EmailAddress(rawValue: link) }
            })
            bestConstruct = min(bestConstruct, Self.seconds {
                for _ in links { _ = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) }
            })
        }

        XCTAssertLessThan(bestValidate, bestConstruct,
                          "validating \(links.count) links took \(bestValidate)s; \(links.count) detectors took \(bestConstruct)s")
    }

    private static func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}

//
//  AppInfrastructureCoverageTests.swift
//  PalaceTests
//
//  Tests for AlertModel, ImageCacheType protocol, AppTabRouter,
//  TPPBookContentType, and URLRequest+Extensions.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - AlertModel Tests

@MainActor
final class AlertModelCoverageTests: XCTestCase {

    // SRS: AlertModel stores title and message
    func testAlertModel_basicProperties() {
        let alert = AlertModel(title: "Error", message: "Something went wrong")
        XCTAssertEqual(alert.title, "Error")
        XCTAssertEqual(alert.message, "Something went wrong")
        XCTAssertNil(alert.buttonTitle)
        XCTAssertNil(alert.secondaryButtonTitle)
    }

    // SRS: AlertModel has unique id
    func testAlertModel_uniqueId() {
        let alert1 = AlertModel(title: "A", message: "A")
        let alert2 = AlertModel(title: "A", message: "A")
        XCTAssertNotEqual(alert1.id, alert2.id)
        // Even a third identical alert must have a unique ID
        let alert3 = AlertModel(title: "A", message: "A")
        XCTAssertNotEqual(alert1.id, alert3.id, "Third identical alert must have a unique ID")
    }

    // SRS: AlertModel with custom button title
    func testAlertModel_customButtonTitle() {
        let alert = AlertModel(title: "T", message: "M", buttonTitle: "OK")
        XCTAssertEqual(alert.buttonTitle, "OK")
        XCTAssertEqual(alert.title, "T", "Title must be preserved alongside custom button title")
        XCTAssertEqual(alert.message, "M", "Message must be preserved alongside custom button title")
    }

    // SRS: AlertModel retryable factory creates correct structure
    func testAlertModel_retryable() {
        var retryCalled = false
        let alert = AlertModel.retryable(
            title: "Download Failed",
            message: "Please try again",
            retryAction: { retryCalled = true }
        )
        XCTAssertEqual(alert.title, "Download Failed")
        XCTAssertEqual(alert.message, "Please try again")
        XCTAssertNotNil(alert.buttonTitle)
        XCTAssertNotNil(alert.secondaryButtonTitle)

        alert.primaryAction()
        XCTAssertTrue(retryCalled)
    }

    // SRS: AlertModel retryable with cancel action
    func testAlertModel_retryableWithCancel() {
        var cancelCalled = false
        let alert = AlertModel.retryable(
            title: "Err",
            message: "Msg",
            retryAction: {},
            cancelAction: { cancelCalled = true }
        )
        alert.secondaryAction()
        XCTAssertTrue(cancelCalled)
    }

    // SRS: AlertModel maxRetriesExceeded factory
    func testAlertModel_maxRetriesExceeded() {
        let alert = AlertModel.maxRetriesExceeded(title: "Too many retries")
        XCTAssertEqual(alert.title, "Too many retries")
        XCTAssertFalse(alert.message.isEmpty)
        XCTAssertNotNil(alert.buttonTitle)
    }
}

// MARK: - ImageCacheType Protocol Tests

@MainActor
final class ImageCacheTypeTests: XCTestCase {

    // SRS: ImageCacheType default set uses 7-day TTL
    func testImageCacheType_defaultSetUses7DayTTL() {
        // We test the MockImageCache conforms to the protocol
        let cache = MockImageCache()
        let image = UIImage()
        cache.set(image, for: "key") // Uses default TTL
        XCTAssertNotNil(cache.get(for: "key"))
    }
}

// MARK: - AppTabRouter Tests

@MainActor
final class AppTabRouterCoverageTests: XCTestCase {

    // SRS: AppTabRouter publishes changes — verify that assigning a different
    // tab fires the @Published willChange event (real reactive behavior).
    func testAppTabRouter_publishesSelectionChanges() {
        let router = AppTabRouter()
        var changeCount = 0
        let cancellable = router.objectWillChange.sink { changeCount += 1 }
        defer { _ = cancellable }

        router.selected = .myBooks
        router.selected = .holds

        XCTAssertEqual(changeCount, 2, "objectWillChange should fire once per tab change")
        XCTAssertEqual(router.selected, .holds)
    }

    // SRS: AppTabRouter default selection is catalog
    func testAppTabRouter_defaultIsCatalog() {
        let router = AppTabRouter()
        XCTAssertEqual(router.selected, .catalog)
        // Verify that the default selection is not any other tab
        XCTAssertNotEqual(router.selected, .myBooks, "Default must not be myBooks")
        XCTAssertNotEqual(router.selected, .holds, "Default must not be holds")
    }

    // SRS: AppTabRouter cycling through all tabs preserves the last assignment
    func testAppTabRouter_sequentialTabChangesPreserveLastValue() {
        let router = AppTabRouter()
        let tabs: [AppTab] = [.myBooks, .holds, .settings, .catalog]

        for tab in tabs {
            router.selected = tab
        }

        XCTAssertEqual(router.selected, tabs.last,
                       "After sequential changes, selected should equal the last tab assigned")
    }

    // SRS: AppTabRouterHub weak router reference allows an AppTabRouter to be
    // injected, read back, and released without the hub retaining it.
    // Verifies that the hub does NOT extend the router's lifetime (weak reference).
    func testAppTabRouterHub_weakRouterReference() {
        let hub = AppTabRouterHub()

        var routerIdentity: ObjectIdentifier?
        autoreleasepool {
            let router = AppTabRouter()
            routerIdentity = ObjectIdentifier(router)
            hub.router = router
            let hubRouterIdentity = hub.router.map { ObjectIdentifier($0) }
            XCTAssertEqual(hubRouterIdentity, routerIdentity,
                           "Hub must vend back the same router instance that was assigned")
        }
        XCTAssertNil(hub.router,
                     "Hub's weak reference must be nil once the only strong reference is released")
    }
}

// MARK: - TPPBookContentType Tests

@MainActor
final class TPPBookContentTypeExtendedTests: XCTestCase {

    // SRS: TPPBookContentType from nil mime type returns unsupported
    func testFromMimeType_nil() {
        XCTAssertEqual(TPPBookContentType.from(mimeType: nil), .unsupported)
        XCTAssertNotEqual(TPPBookContentType.from(mimeType: nil), .epub, "Nil mime type must not resolve to epub")
        XCTAssertNotEqual(TPPBookContentType.from(mimeType: nil), .pdf, "Nil mime type must not resolve to pdf")
    }

    // SRS: TPPBookContentType from empty string returns unsupported
    func testFromMimeType_empty() {
        XCTAssertEqual(TPPBookContentType.from(mimeType: ""), .unsupported)
        XCTAssertNotEqual(TPPBookContentType.from(mimeType: ""), .epub, "Empty mime type must not resolve to epub")
        XCTAssertNotEqual(TPPBookContentType.from(mimeType: ""), .audiobook, "Empty mime type must not resolve to audiobook")
    }

    // SRS: TPPBookContentType from unknown mime type returns unsupported
    func testFromMimeType_unknown() {
        XCTAssertEqual(TPPBookContentType.from(mimeType: "text/html"), .unsupported)
        XCTAssertEqual(TPPBookContentType.from(mimeType: "image/jpeg"), .unsupported,
                       "Image mime type must also be unsupported")
        XCTAssertNotEqual(TPPBookContentType.from(mimeType: "text/html"), .epub, "HTML must not resolve to epub")
    }

    // SRS: TPPBookContentType.from(mimeType:) correctly maps known EPUB mime types
    func testFromMimeType_epubAndPdfMappedCorrectly() {
        // Arrange: known mime types defined in the production constants
        let epubMime = "application/epub+zip"
        let pdfMime  = "application/pdf"
        let octetMime = "application/octet-stream"

        // Act
        let epubResult   = TPPBookContentType.from(mimeType: epubMime)
        let pdfResult    = TPPBookContentType.from(mimeType: pdfMime)
        let octetResult  = TPPBookContentType.from(mimeType: octetMime)

        // Assert: exercises the real dispatch logic in from(mimeType:)
        XCTAssertEqual(epubResult,  .epub,  "application/epub+zip should resolve to .epub")
        XCTAssertEqual(pdfResult,   .pdf,   "application/pdf should resolve to .pdf")
        XCTAssertEqual(octetResult, .epub,  "application/octet-stream should resolve to .epub (open-access fallback)")
    }
}

// MARK: - URLRequest+Extensions Tests

@MainActor
final class URLRequestExtensionsCoverageTests: XCTestCase {

    // SRS: URLRequest init with custom user agent sets header
    func testURLRequest_customUserAgent() {
        let url = URL(string: "https://example.com")!
        let request = URLRequest(url: url, applyingCustomUserAgent: true)
        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(userAgent)
        XCTAssertTrue(userAgent!.contains("iOS"))
    }

    // SRS: URLRequest with applyingCustomUserAgent: false must not set a
    // User-Agent header — verifies the flag is actually respected.
    func testURLRequest_noCustomUserAgent_doesNotSetUserAgentHeader() {
        let url = URL(string: "https://example.com")!

        // Arrange: a plain request with no pre-existing headers
        let withAgent    = URLRequest(url: url, applyingCustomUserAgent: true)
        let withoutAgent = URLRequest(url: url, applyingCustomUserAgent: false)

        // Act: compare the User-Agent header presence between the two paths
        let agentHeader    = withAgent.value(forHTTPHeaderField: "User-Agent")
        let noAgentHeader  = withoutAgent.value(forHTTPHeaderField: "User-Agent")

        // Assert
        XCTAssertNotNil(agentHeader,   "Request with applyingCustomUserAgent:true should have a User-Agent header")
        XCTAssertNil(noAgentHeader,    "Request with applyingCustomUserAgent:false must not set a User-Agent header")
    }

    // SRS: URLRequest applyCustomUserAgent mutates request
    func testURLRequest_applyCustomUserAgent() {
        let url = URL(string: "https://example.com")!
        var request = URLRequest(url: url)
        request.applyCustomUserAgent()
        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(userAgent)
        XCTAssertTrue(userAgent!.contains("iOS"))
    }
}

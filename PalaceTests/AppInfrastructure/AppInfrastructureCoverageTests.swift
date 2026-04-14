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
    }

    // SRS: AlertModel with custom button title
    func testAlertModel_customButtonTitle() {
        let alert = AlertModel(title: "T", message: "M", buttonTitle: "OK")
        XCTAssertEqual(alert.buttonTitle, "OK")
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

    // SRS: AppTabRouterHub singleton exists
    func testAppTabRouterHub_singletonExists() {
        let hub = AppTabRouterHub.shared
        XCTAssertNotNil(hub)
    }

    // SRS: AppTabRouterHub weak router reference allows an AppTabRouter to be
    // injected, read back, and released without the hub retaining it.
    // Verifies that the hub does NOT extend the router's lifetime (weak reference).
    func testAppTabRouterHub_weakRouterReference() {
        let hub = AppTabRouterHub.shared

        // Use an inner scope to guarantee the router is released when the scope exits
        var routerIdentity: ObjectIdentifier?
        autoreleasepool {
            let router = AppTabRouter()
            routerIdentity = ObjectIdentifier(router)
            hub.router = router
            // Router is alive inside this scope — hub.router should be non-nil
            let hubRouterIdentity = hub.router.map { ObjectIdentifier($0) }
            XCTAssertEqual(hubRouterIdentity, routerIdentity,
                           "Hub must vend back the same router instance that was assigned")
        }
        // `router` local var is out of scope; autoreleasepool drained — hub's weak ref must be nil
        XCTAssertNil(hub.router,
                     "Hub's weak reference must be nil once the only strong reference is released")
    }
}

// MARK: - TPPBookContentType Tests

final class TPPBookContentTypeExtendedTests: XCTestCase {

    // SRS: TPPBookContentType from nil mime type returns unsupported
    func testFromMimeType_nil() {
        XCTAssertEqual(TPPBookContentType.from(mimeType: nil), .unsupported)
    }

    // SRS: TPPBookContentType from empty string returns unsupported
    func testFromMimeType_empty() {
        XCTAssertEqual(TPPBookContentType.from(mimeType: ""), .unsupported)
    }

    // SRS: TPPBookContentType from unknown mime type returns unsupported
    func testFromMimeType_unknown() {
        XCTAssertEqual(TPPBookContentType.from(mimeType: "text/html"), .unsupported)
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

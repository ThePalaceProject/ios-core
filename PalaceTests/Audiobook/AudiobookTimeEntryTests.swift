//
//  AudiobookTimeEntryTests.swift
//  PalaceTests
//
//  Tests for AudiobookTimeEntry, DataManager protocol,
//  and NotificationService.TokenData.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import PalaceCatalog
@testable import Palace

// MARK: - AudiobookTimeEntry Tests

@MainActor
final class AudiobookTimeEntryTests: XCTestCase {

    // SRS: AudiobookTimeEntry stores all properties
    func testTimeEntry_storesProperties() {
        let url = URL(string: "https://example.com/track")!
        let entry = AudiobookTimeEntry(
            id: "entry-1",
            bookId: "book-123",
            libraryId: "lib-456",
            timeTrackingUrl: url,
            duringMinute: "2024-01-15T10:30Z",
            duration: 45
        )
        XCTAssertEqual(entry.id, "entry-1")
        XCTAssertEqual(entry.bookId, "book-123")
        XCTAssertEqual(entry.libraryId, "lib-456")
        XCTAssertEqual(entry.timeTrackingUrl, url)
        XCTAssertEqual(entry.duringMinute, "2024-01-15T10:30Z")
        XCTAssertEqual(entry.duration, 45)
    }

    // SRS: AudiobookTimeEntry conforms to TimeEntry protocol
    func testTimeEntry_conformsToProtocol() {
        let url = URL(string: "https://example.com")!
        let entry = AudiobookTimeEntry(id: "1", bookId: "b", libraryId: "l", timeTrackingUrl: url, duringMinute: "m", duration: 10)
        let asProtocol: TimeEntry = entry
        XCTAssertEqual(asProtocol.id, "1")
        XCTAssertEqual(asProtocol.duration, 10)
    }

    // SRS: AudiobookTimeEntry is Codable (round-trip)
    func testTimeEntry_codableRoundTrip() throws {
        let url = URL(string: "https://example.com/track")!
        let entry = AudiobookTimeEntry(id: "e1", bookId: "b1", libraryId: "l1", timeTrackingUrl: url, duringMinute: "2024-01-15T10:30Z", duration: 30)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(AudiobookTimeEntry.self, from: data)
        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.bookId, entry.bookId)
        XCTAssertEqual(decoded.duration, entry.duration)
    }

    // SRS: AudiobookTimeEntry is Hashable
    func testTimeEntry_hashable() {
        let url = URL(string: "https://example.com")!
        let entry1 = AudiobookTimeEntry(id: "1", bookId: "b", libraryId: "l", timeTrackingUrl: url, duringMinute: "m", duration: 10)
        let entry2 = AudiobookTimeEntry(id: "2", bookId: "b", libraryId: "l", timeTrackingUrl: url, duringMinute: "m", duration: 20)
        var set = Set<AudiobookTimeEntry>()
        set.insert(entry1)
        set.insert(entry2)
        XCTAssertEqual(set.count, 2)
    }

    // SRS: AudiobookTimeEntry equality based on all fields
    func testTimeEntry_equality() {
        let url = URL(string: "https://example.com")!
        let entry1 = AudiobookTimeEntry(id: "1", bookId: "b", libraryId: "l", timeTrackingUrl: url, duringMinute: "m", duration: 10)
        let entry2 = AudiobookTimeEntry(id: "1", bookId: "b", libraryId: "l", timeTrackingUrl: url, duringMinute: "m", duration: 10)
        XCTAssertEqual(entry1, entry2)
        // Entries with different IDs must not be equal
        let entry3 = AudiobookTimeEntry(id: "2", bookId: "b", libraryId: "l", timeTrackingUrl: url, duringMinute: "m", duration: 10)
        XCTAssertNotEqual(entry1, entry3, "Different IDs must produce unequal entries")
    }

    // SRS: AudiobookTimeEntry duration capped semantics (max 60 in tracker)
    func testTimeEntry_durationCanExceed60InStruct() {
        let url = URL(string: "https://example.com")!
        let entry = AudiobookTimeEntry(id: "1", bookId: "b", libraryId: "l", timeTrackingUrl: url, duringMinute: "m", duration: 120)
        // The struct itself doesn't cap; the tracker caps to 60 before creating
        XCTAssertEqual(entry.duration, 120)
        // Contrast: a correctly-created entry uses the exact duration passed in
        let entry60 = AudiobookTimeEntry(id: "2", bookId: "b", libraryId: "l", timeTrackingUrl: url, duringMinute: "m", duration: 60)
        XCTAssertEqual(entry60.duration, 60, "Duration of 60 must be stored as-is")
        XCTAssertNotEqual(entry.duration, entry60.duration, "120 must not equal 60")
    }
}

// MARK: - NotificationService.TokenData Tests

@MainActor
final class NotificationTokenDataTests: XCTestCase {

    // SRS: TokenData initializes with token and sets type
    func testTokenData_init() {
        let tokenData = NotificationService.TokenData(token: "abc123")
        XCTAssertEqual(tokenData.device_token, "abc123")
        XCTAssertEqual(tokenData.token_type, "FCMiOS")
    }

    // SRS: TokenData produces non-nil data
    func testTokenData_dataNotNil() {
        let tokenData = NotificationService.TokenData(token: "test")
        XCTAssertNotNil(tokenData.data)
        // The produced data must be valid JSON (non-empty and parseable)
        if let data = tokenData.data {
            XCTAssertGreaterThan(data.count, 0, "Encoded data must not be empty")
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data), "Encoded data must be valid JSON")
        }
    }

    // SRS: TokenData encodes to valid JSON
    func testTokenData_encodesToJSON() throws {
        let tokenData = NotificationService.TokenData(token: "myToken")
        let data = tokenData.data!
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["device_token"] as? String, "myToken")
        XCTAssertEqual(dict?["token_type"] as? String, "FCMiOS")
    }

    // SRS: TokenData is Codable round-trip
    func testTokenData_codableRoundTrip() throws {
        let original = NotificationService.TokenData(token: "roundTrip")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: encoded)
        XCTAssertEqual(decoded.device_token, "roundTrip")
        XCTAssertEqual(decoded.token_type, "FCMiOS")
    }
}

// MARK: - NSNotification+TPP Tests

@MainActor
final class NSNotificationTPPTests: XCTestCase {

    // SRS: Notification.Name constants exist
    func testNotificationNames_exist() {
        XCTAssertEqual(Notification.Name.TPPSettingsDidChange.rawValue, "TPPSettingsDidChange")
        XCTAssertEqual(Notification.Name.TPPCurrentAccountDidChange.rawValue, "TPPCurrentAccountDidChange")
        XCTAssertEqual(Notification.Name.TPPCatalogDidLoad.rawValue, "TPPCatalogDidLoad")
        XCTAssertEqual(Notification.Name.TPPSyncBegan.rawValue, "TPPSyncBegan")
        XCTAssertEqual(Notification.Name.TPPSyncEnded.rawValue, "TPPSyncEnded")
        XCTAssertEqual(Notification.Name.TPPUseBetaDidChange.rawValue, "TPPUseBetaDidChange")
        XCTAssertEqual(Notification.Name.TPPDidSignOut.rawValue, "TPPDidSignOut")
        XCTAssertEqual(Notification.Name.TPPIsSigningIn.rawValue, "TPPIsSigningIn")
        XCTAssertEqual(Notification.Name.TPPBookRegistryDidChange.rawValue, "TPPBookRegistryDidChange")
        XCTAssertEqual(Notification.Name.TPPBookRegistryStateDidChange.rawValue, "TPPBookRegistryStateDidChange")
        XCTAssertEqual(Notification.Name.TPPBookProcessingDidChange.rawValue, "TPPBookProcessingDidChange")
        XCTAssertEqual(Notification.Name.TPPMyBooksDownloadCenterDidChange.rawValue, "TPPMyBooksDownloadCenterDidChange")
        XCTAssertEqual(Notification.Name.TPPBookDetailDidClose.rawValue, "TPPBookDetailDidClose")
        XCTAssertEqual(Notification.Name.TPPAccountSetDidLoad.rawValue, "TPPAccountSetDidLoad")
        XCTAssertEqual(Notification.Name.TPPReachabilityChanged.rawValue, "TPPReachabilityChanged")
    }

    // SRS: NSNotification static constants match Swift counterparts
    func testNSNotificationConstants_matchSwift() {
        XCTAssertEqual(NSNotification.TPPSettingsDidChange, Notification.Name.TPPSettingsDidChange)
        XCTAssertEqual(NSNotification.TPPCurrentAccountDidChange, Notification.Name.TPPCurrentAccountDidChange)
        XCTAssertEqual(NSNotification.TPPBookRegistryDidChange, Notification.Name.TPPBookRegistryDidChange)
    }

    // SRS: TPPNotificationKeys constants
    func testNotificationKeys_exist() {
        XCTAssertEqual(TPPNotificationKeys.bookProcessingBookIDKey, "identifier")
        XCTAssertEqual(TPPNotificationKeys.bookProcessingValueKey, "value")
    }
}

// MARK: - DPLAAudiobooks.DPLAError Tests

@MainActor
final class DPLAErrorTests: XCTestCase {

    // SRS: DPLAError requestError has readable description
    func testRequestError_readableError() {
        let url = URL(string: "https://example.com")!
        let nsError = NSError(domain: "test", code: 42, userInfo: nil)
        let error = DPLAAudiobooks.DPLAError.requestError(url, nsError)
        XCTAssertEqual(error.readableError, "Error receiving DRM key.")
        XCTAssertTrue(error.localisedDescription.contains("example.com"))
    }

    // SRS: DPLAError drmKeyError has readable description
    func testDrmKeyError_readableError() {
        let error = DPLAAudiobooks.DPLAError.drmKeyError("Bad key data")
        XCTAssertEqual(error.readableError, "Error decoding DRM key data.")
        XCTAssertEqual(error.localisedDescription, "Bad key data")
    }

    // SRS: DPLAAudiobooks certificateUrl is valid
    func testCertificateUrl_isValid() {
        XCTAssertEqual(DPLAAudiobooks.certificateUrl.host, "listen.cantookaudio.com")
        XCTAssertTrue(DPLAAudiobooks.certificateUrl.absoluteString.contains("jwks.json"))
    }
}

// MARK: - OPDSParser Tests

@MainActor
final class OPDSParserTests: XCTestCase {

    // SRS: OPDSParser.ParserError invalidXML has description
    func testParserError_invalidXML() {
        let error = OPDSParser.ParserError.invalidXML
        XCTAssertEqual(error.errorDescription, "Unable to parse OPDS XML.")
        // Error description must be non-empty and distinct from other errors
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "Error description must not be empty")
        XCTAssertNotEqual(error.errorDescription, OPDSParser.ParserError.invalidFeed.errorDescription,
                          "Different errors must have distinct descriptions")
    }

    // SRS: OPDSParser.ParserError invalidFeed has description
    func testParserError_invalidFeed() {
        let error = OPDSParser.ParserError.invalidFeed
        XCTAssertEqual(error.errorDescription, "Invalid or unsupported OPDS feed format.")
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "Error description must not be empty")
        XCTAssertNotEqual(error.errorDescription, OPDSParser.ParserError.invalidXML.errorDescription,
                          "invalidFeed description must differ from invalidXML")
    }

    // SRS: OPDSParser parseFeed throws for invalid data
    func testParseFeed_throwsForInvalidData() {
        let parser = OPDSParser()
        XCTAssertThrowsError(try parser.parseFeed(from: Data())) { error in
            XCTAssertTrue(error is OPDSParser.ParserError)
        }
    }

    // SRS: OPDSParser parseFeed throws for non-XML data
    func testParseFeed_throwsForNonXML() {
        let parser = OPDSParser()
        let data = "not xml".data(using: .utf8)!
        XCTAssertThrowsError(try parser.parseFeed(from: data)) { error in
            // Must throw a typed OPDSParser error (not a random Swift error)
            XCTAssertTrue(error is OPDSParser.ParserError, "Must throw a ParserError for non-XML input")
        }
    }
}

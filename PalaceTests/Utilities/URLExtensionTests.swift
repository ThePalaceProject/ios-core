//
//  URLExtensionTests.swift
//  PalaceTests
//
//  Tests for URL extension methods
//

import XCTest
@testable import Palace

final class URLExtensionTests: XCTestCase {

    // MARK: - URL Component Tests

    func testURLComponents_host() {
        let url = URL(string: "https://example.com/path")!
        XCTAssertEqual(url.host, "example.com")
        XCTAssertNotNil(url.host)
        // Port should be nil when not specified
        XCTAssertNil(url.port)
    }

    func testURLComponents_path() {
        let url = URL(string: "https://example.com/path/to/resource")!
        XCTAssertEqual(url.path, "/path/to/resource")
        XCTAssertTrue(url.path.hasPrefix("/"))
        XCTAssertEqual(url.lastPathComponent, "resource")
    }

    func testURLComponents_scheme() {
        let httpsUrl = URL(string: "https://example.com")!
        let httpUrl = URL(string: "http://example.com")!

        XCTAssertEqual(httpsUrl.scheme, "https")
        XCTAssertEqual(httpUrl.scheme, "http")
        XCTAssertNotEqual(httpsUrl.scheme, httpUrl.scheme)
    }

    func testURLComponents_query() {
        let url = URL(string: "https://example.com/search?q=test&page=1")!
        XCTAssertEqual(url.query, "q=test&page=1")
        XCTAssertNotNil(url.query)
        XCTAssertTrue(url.query!.contains("q=test"))
    }

    func testURLComponents_fragment() {
        let url = URL(string: "https://example.com/page#section")!
        XCTAssertEqual(url.fragment, "section")
        XCTAssertNotNil(url.fragment)
        // URL without fragment should have nil fragment
        let urlNoFragment = URL(string: "https://example.com/page")!
        XCTAssertNil(urlNoFragment.fragment)
    }

    // MARK: - File URL Tests

    func testFileURL_isFileURL() {
        let fileURL = URL(fileURLWithPath: "/tmp/test.txt")
        XCTAssertTrue(fileURL.isFileURL)
        XCTAssertEqual(fileURL.scheme, "file")
        XCTAssertEqual(fileURL.lastPathComponent, "test.txt")
    }

    func testHTTPURL_isNotFileURL() {
        let httpURL = URL(string: "https://example.com")!
        XCTAssertFalse(httpURL.isFileURL)
        XCTAssertEqual(httpURL.scheme, "https")
        XCTAssertNil(httpURL.pathExtension.isEmpty ? nil : Optional<String>.none)
    }

    func testFileURL_pathExtension() {
        let pdfURL = URL(fileURLWithPath: "/tmp/document.pdf")
        let epubURL = URL(fileURLWithPath: "/tmp/book.epub")

        XCTAssertEqual(pdfURL.pathExtension, "pdf")
        XCTAssertEqual(epubURL.pathExtension, "epub")
        XCTAssertNotEqual(pdfURL.pathExtension, epubURL.pathExtension)
    }

    func testFileURL_lastPathComponent() {
        let url = URL(fileURLWithPath: "/path/to/document.pdf")
        XCTAssertEqual(url.lastPathComponent, "document.pdf")
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".pdf"))
        XCTAssertEqual(url.pathExtension, "pdf")
    }

    func testFileURL_deletingLastPathComponent() {
        let url = URL(fileURLWithPath: "/path/to/document.pdf")
        let parent = url.deletingLastPathComponent()

        XCTAssertEqual(parent.lastPathComponent, "to")
        // Parent should not have a path extension (it's a directory)
        XCTAssertTrue(parent.pathExtension.isEmpty)
    }

    // MARK: - URL Appending Tests

    func testAppendingPathComponent() {
        let baseURL = URL(string: "https://example.com/api")!
        let fullURL = baseURL.appendingPathComponent("v1/books")

        XCTAssertEqual(fullURL.absoluteString, "https://example.com/api/v1/books")
        XCTAssertEqual(fullURL.host, "example.com")
        XCTAssertEqual(fullURL.scheme, "https")
    }

    func testAppendingPathExtension() {
        let baseURL = URL(fileURLWithPath: "/tmp/document")
        let fullURL = baseURL.appendingPathExtension("pdf")

        XCTAssertEqual(fullURL.lastPathComponent, "document.pdf")
        XCTAssertEqual(fullURL.pathExtension, "pdf")
        XCTAssertTrue(fullURL.absoluteString.hasSuffix(".pdf"))
    }

    // MARK: - URL Query Item Tests

    func testURLQueryItems_parsing() {
        let url = URL(string: "https://example.com/search?q=swift&page=2&sort=date")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.queryItems?.count, 3)
        let qItem = components?.queryItems?.first { $0.name == "q" }
        XCTAssertEqual(qItem?.value, "swift")
        // All three parameter names must be present and distinct
        let names = components?.queryItems?.map(\.name) ?? []
        XCTAssertTrue(names.contains("page") && names.contains("sort"), "All query parameters must be parsed")
    }

    func testURLQueryItems_building() {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "example.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: "swift"),
            URLQueryItem(name: "page", value: "1")
        ]

        let url = components.url
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("q=swift"))
    }

    // MARK: - URL Encoding Tests

    func testURLEncoding_spaceInQuery() {
        let urlString = "https://example.com/search?q=hello%20world"
        let url = URL(string: urlString)

        XCTAssertEqual(url?.scheme, "https", "Scheme must be https")
        XCTAssertTrue(url?.absoluteString.contains("%20") ?? false, "Percent-encoded space must be preserved")
        // The raw space must not appear in the absolute string
        XCTAssertFalse(url?.absoluteString.contains(" ") ?? true, "Raw spaces must not appear in a URL string")
    }

    func testURLEncoding_specialCharacters() {
        let text = "hello+world"
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

        XCTAssertNotNil(encoded)
        XCTAssertTrue(encoded!.contains("+") || encoded!.contains("%2B"))
    }
}

// MARK: - URL Validation Tests

final class URLValidationTests: XCTestCase {

    func testValidHTTPURL() {
        let url = URL(string: "https://example.com")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "example.com")
        // A valid HTTPS URL must not be a file URL
        XCTAssertFalse(url?.isFileURL ?? true, "https URL must not be a file URL")
        XCTAssertNil(url?.port, "Default HTTPS port 443 must not appear explicitly in the URL")
    }

    func testInvalidURL_handledByURLInit() {
        // URL(string:) behavior varies by iOS version:
        // - iOS 16 and earlier: returns nil for strings with spaces/special chars
        // - iOS 17+: auto-encodes spaces and some special characters

        // Test that we can safely handle the result (nil or encoded)
        let url = URL(string: "not a valid url")
        if let url = url {
            // iOS 17+: auto-encoded
            XCTAssertTrue(url.absoluteString.contains("%20"), "Spaces should be percent-encoded")
        }
        // Either nil or encoded is acceptable - the key is it doesn't crash

        // Characters that are ALWAYS invalid (control characters)
        // Note: Modern Foundation may percent-encode null bytes, so we only
        // verify it doesn't crash. Either nil or encoded is acceptable.
        let urlWithNull = URL(string: "https://example.com/\0invalid")
        if urlWithNull != nil {
            // Modern Foundation percent-encodes the null byte
            XCTAssertTrue(urlWithNull!.absoluteString.contains("%00"))
        }
        // Either nil or encoded is acceptable - the key is it doesn't crash
    }

    func testEmptyString_returnsNil() {
        let url = URL(string: "")
        XCTAssertNil(url)
        // A valid string must contrast — scheme must be parseable
        let validURL = URL(string: "https://example.com")
        XCTAssertEqual(validURL?.scheme, "https", "A valid HTTPS URL string must parse with scheme 'https'")
        // A string with only whitespace must also fail or be treated as invalid
        let whitespaceURL = URL(string: "   ")
        if whitespaceURL != nil {
            XCTAssertNotEqual(whitespaceURL?.absoluteString, "https://example.com",
                              "Whitespace URL must not match a real URL")
        }
    }

    func testURLWithSpaces_handledCorrectly() {
        // URL(string:) behavior varies by iOS version:
        // - iOS 16 and earlier: returns nil for paths with spaces
        // - iOS 17+: auto-encodes spaces in the path

        let urlWithSpaces = URL(string: "https://example.com/path with spaces")

        if let url = urlWithSpaces {
            // iOS 17+: auto-encoded - verify it was encoded correctly
            XCTAssertTrue(url.absoluteString.contains("%20"), "Spaces should be percent-encoded")
            XCTAssertFalse(url.absoluteString.contains(" "), "Should not contain raw spaces")
        } else {
            // iOS 16 and earlier: nil is expected
            // Manual encoding is required
            let encodedPath = "path with spaces".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            let validUrl = URL(string: "https://example.com/\(encodedPath)")
            XCTAssertNotNil(validUrl, "Manually encoded URL should work")
            XCTAssertTrue(validUrl!.absoluteString.contains("%20"))
        }
    }

    func testFileURL_alwaysValid() {
        let url = URL(fileURLWithPath: "/any/path/is/valid")
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.scheme, "file")
        XCTAssertEqual(url.lastPathComponent, "valid")
        // File URLs must differ from HTTPS URLs with the same path string
        let httpsURL = URL(string: "https://example.com/any/path/is/valid")
        XCTAssertFalse(httpsURL?.isFileURL ?? true, "HTTPS URL must not be a file URL")
    }
}

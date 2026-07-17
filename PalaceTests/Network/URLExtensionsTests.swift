//
//  URLExtensionsTests.swift
//  PalaceTests
//
//  Tests for URL+Extensions.swift replacingScheme method
//

import XCTest
@testable import Palace

@MainActor
final class URLExtensionsTests: XCTestCase {

    // MARK: - replacingScheme Tests

    func testReplacingScheme_HttpToHttps_ReplacesScheme() {
        let url = URL(string: "http://example.com/path")!
        let result = url.replacingScheme(with: "https")

        XCTAssertEqual(result.scheme, "https")
        XCTAssertEqual(result.host, "example.com")
        XCTAssertEqual(result.path, "/path")
    }

    func testReplacingScheme_HttpsToHttp_ReplacesScheme() {
        let url = URL(string: "https://example.com/path?q=1")!
        let result = url.replacingScheme(with: "http")

        XCTAssertEqual(result.scheme, "http")
        XCTAssertEqual(result.query, "q=1")
    }

    func testReplacingScheme_ToCustomScheme_Works() {
        let url = URL(string: "https://example.com/book/123")!
        let result = url.replacingScheme(with: "palace")

        XCTAssertEqual(result.scheme, "palace")
        XCTAssertEqual(result.absoluteString, "palace://example.com/book/123")
    }

    func testReplacingScheme_PreservesFragment() {
        let url = URL(string: "https://example.com/page#section")!
        let result = url.replacingScheme(with: "http")

        XCTAssertEqual(result.fragment, "section")
        XCTAssertEqual(result.scheme, "http", "Scheme must be updated to the new value")
        XCTAssertEqual(result.host, url.host, "Host must be preserved when replacing scheme")
    }

    func testReplacingScheme_PreservesPort() {
        let url = URL(string: "http://localhost:8080/api")!
        let result = url.replacingScheme(with: "https")

        XCTAssertEqual(result.port, 8080)
        XCTAssertEqual(result.scheme, "https")
    }

    func testReplacingScheme_PreservesUserInfo() {
        let url = URL(string: "http://user:pass@example.com/path")!
        let result = url.replacingScheme(with: "https")

        XCTAssertEqual(result.user, "user")
        XCTAssertEqual(result.password, "pass")
    }

    // MARK: - settingQueryItem Tests

    func testSettingQueryItem_NoExistingQuery_AddsItem() {
        let url = URL(string: "https://example.com/libraries")!
        let result = url.settingQueryItem(name: "availability", value: "all")

        XCTAssertEqual(result.absoluteString, "https://example.com/libraries?availability=all")
    }

    func testSettingQueryItem_PreservesOtherItems_AndOrder() {
        let url = URL(string: "https://example.com/libraries?order=modified&page=2")!
        let result = url.settingQueryItem(name: "availability", value: "all")

        let items = URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["order", "page", "availability"],
                       "Existing items are preserved in order and the new item is appended last")
        XCTAssertEqual(items.first { $0.name == "order" }?.value, "modified")
    }

    func testSettingQueryItem_ReplacesExistingSameName_ExactlyOnce() {
        let url = URL(string: "https://example.com/libraries?availability=production")!
        let result = url.settingQueryItem(name: "availability", value: "all")

        let values = (URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "availability" }
            .compactMap(\.value)
        XCTAssertEqual(values, ["all"],
                       "The prior value must be replaced, not duplicated — exactly one availability item")
    }

    func testSettingQueryItem_RemovesAllDuplicatesOfName() {
        let url = URL(string: "https://example.com/libraries?availability=a&availability=b&keep=1")!
        let result = url.settingQueryItem(name: "availability", value: "all")

        let items = URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "availability" }.count, 1,
                       "All pre-existing items with the target name are removed before appending one")
        XCTAssertEqual(items.first { $0.name == "keep" }?.value, "1",
                       "Unrelated items are untouched")
    }

    func testSettingQueryItem_PercentEncodesValue() {
        let url = URL(string: "https://example.com/libraries")!
        let result = url.settingQueryItem(name: "q", value: "a b&c")

        XCTAssertEqual(URLComponents(url: result, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "q" }?.value,
                       "a b&c",
                       "Round-trips a value containing reserved characters via URLComponents encoding")
    }
}

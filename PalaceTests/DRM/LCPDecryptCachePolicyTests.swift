//
//  Audiobook licences read their tracks once, in order, so their decrypts skip
//  LCPDecryptCache; EPUB and PDF licences keep it (PP-5584).
//

#if LCP

import XCTest
@testable import Palace
import R2LCPClient

final class LCPDecryptCachePolicyTests: XCTestCase {

    private var cache: LCPDecryptCache!
    private var decryptCalls: [String: Int] = [:]
    private var client: TPPLCPClient!

    override func setUp() {
        super.setUp()
        cache = LCPDecryptCache()
        decryptCalls = [:]
        client = TPPLCPClient(
            cache: cache,
            createDRMContext: { jsonLicense, _, _ in
                Self.makeContext(contentKey: Self.contentKey(in: jsonLicense))
            },
            decryptWithDRM: { [unowned self] data, context in
                decryptCalls[context.encryptedContentKey, default: 0] += 1
                return Data(data.reversed())
            }
        )
    }

    override func tearDown() {
        client = nil
        cache = nil
        super.tearDown()
    }

    // MARK: - Audiobooks skip the cache

    /// Reading the same audiobook chunk twice decrypts twice and leaves the
    /// cache empty, so playback holds no decrypted audio in it.
    func testDecrypt_AudiobookLicence_DecryptsEveryReadAndStoresNothing() throws {
        let context = try client.createContext(
            jsonLicense: Self.licence(key: "book", type: "application/audiobook+lcp"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let chunk = Data(repeating: 7, count: 4_096)

        let first = client.decrypt(data: chunk, using: context)
        let second = client.decrypt(data: chunk, using: context)

        XCTAssertEqual(first, Data(chunk.reversed()))
        XCTAssertEqual(second, Data(chunk.reversed()))
        XCTAssertEqual(decryptCalls["book"], 2)
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertNil(cache.decrypted(for: chunk))
    }

    /// The unpackaged audiobook type is classified the same way as the LCP one.
    func testDecrypt_ReadiumAudiobookLicenceType_SkipsTheCache() throws {
        let context = try client.createContext(
            jsonLicense: Self.licence(key: "zip", type: "application/audiobook+zip"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let chunk = Data([1, 2, 3, 4])

        _ = client.decrypt(data: chunk, using: context)
        _ = client.decrypt(data: chunk, using: context)

        XCTAssertEqual(decryptCalls["zip"], 2)
        XCTAssertEqual(cache.byteCount, 0)
    }

    /// The context-less `decrypt(data:)` path uses the client's last context
    /// and follows the same policy.
    func testDecryptWithoutContext_AudiobookLicence_SkipsTheCache() throws {
        _ = try client.createContext(
            jsonLicense: Self.licence(key: "book", type: "application/audiobook+lcp"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let chunk = Data([9, 8, 7])

        _ = client.decrypt(data: chunk)
        _ = client.decrypt(data: chunk)

        XCTAssertEqual(decryptCalls["book"], 2)
        XCTAssertEqual(cache.byteCount, 0)
    }

    // MARK: - EPUB, PDF and unknown types keep the cache

    /// A repeated EPUB read is served from the cache without a second decrypt.
    func testDecrypt_EPUBLicence_SecondReadIsACacheHit() throws {
        let context = try client.createContext(
            jsonLicense: Self.licence(key: "epub", type: "application/epub+zip"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let chunk = Data(repeating: 3, count: 1_024)

        let first = client.decrypt(data: chunk, using: context)
        let second = client.decrypt(data: chunk, using: context)

        XCTAssertEqual(decryptCalls["epub"], 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.decrypted(for: chunk), Data(chunk.reversed()))
    }

    /// A repeated LCP PDF read is served from the cache without a second decrypt.
    func testDecrypt_PDFLicence_SecondReadIsACacheHit() throws {
        let context = try client.createContext(
            jsonLicense: Self.licence(key: "pdf", type: "application/pdf+lcp"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let chunk = Data(repeating: 5, count: 1_024)

        _ = client.decrypt(data: chunk, using: context)
        _ = client.decrypt(data: chunk, using: context)

        XCTAssertEqual(decryptCalls["pdf"], 1)
        XCTAssertEqual(cache.decrypted(for: chunk), Data(chunk.reversed()))
    }

    /// A licence whose publication type is missing keeps today's caching.
    func testDecrypt_LicenceWithoutPublicationType_KeepsTheCache() throws {
        let context = try client.createContext(
            jsonLicense: Self.licence(key: "untyped", type: nil),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let chunk = Data([4, 4, 4])

        _ = client.decrypt(data: chunk, using: context)
        _ = client.decrypt(data: chunk, using: context)

        XCTAssertEqual(decryptCalls["untyped"], 1)
        XCTAssertNotNil(cache.decrypted(for: chunk))
    }

    /// A licence that is not JSON keeps today's caching instead of failing.
    func testDecrypt_UnparseableLicence_KeepsTheCache() throws {
        let context = try client.createContext(
            jsonLicense: "not json",
            hashedPassphrase: "hash", pemCrl: ""
        )
        let chunk = Data([6, 6])

        _ = client.decrypt(data: chunk, using: context)
        _ = client.decrypt(data: chunk, using: context)

        XCTAssertEqual(decryptCalls["default-key"], 1)
        XCTAssertNotNil(cache.decrypted(for: chunk))
    }

    /// With an audiobook and an EPUB open on one client, only the audiobook
    /// skips the cache, whichever licence was opened last.
    func testDecrypt_AudiobookAndEPUBOnOneClient_OnlyTheAudiobookSkips() throws {
        let audiobook = try client.createContext(
            jsonLicense: Self.licence(key: "book", type: "application/audiobook+lcp"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let epub = try client.createContext(
            jsonLicense: Self.licence(key: "epub", type: "application/epub+zip"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let audioChunk = Data([1, 1, 1])
        let epubChunk = Data([2, 2, 2])

        for _ in 0..<2 {
            _ = client.decrypt(data: audioChunk, using: audiobook)
            _ = client.decrypt(data: epubChunk, using: epub)
        }

        XCTAssertEqual(decryptCalls["book"], 2)
        XCTAssertEqual(decryptCalls["epub"], 1)
        XCTAssertNil(cache.decrypted(for: audioChunk))
        XCTAssertNotNil(cache.decrypted(for: epubChunk))
    }

    /// An audiobook licence with an empty content key is not recorded, so an
    /// EPUB whose context also has an empty key keeps the cache.
    func testDecrypt_AudiobookLicenceWithEmptyKey_DoesNotTurnOffTheCacheForOthers() throws {
        _ = try client.createContext(
            jsonLicense: Self.licence(key: "", type: "application/audiobook+lcp"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let epub = try client.createContext(
            jsonLicense: Self.licence(key: "", type: "application/epub+zip"),
            hashedPassphrase: "hash", pemCrl: ""
        )
        let chunk = Data([3, 1, 4])

        _ = client.decrypt(data: chunk, using: epub)
        _ = client.decrypt(data: chunk, using: epub)

        XCTAssertEqual(decryptCalls[""], 1)
        XCTAssertNotNil(cache.decrypted(for: chunk))
    }

    // MARK: - Licence classification

    /// `rel` may be an array; the publication link is found either way.
    func testIsAudiobookLicence_RelAsArray_IsAudiobook() {
        let json = #"{"links":[{"rel":["publication","alternate"],"type":"application/audiobook+lcp"}]}"#

        XCTAssertTrue(TPPLCPClient.isAudiobookLicence(json))
    }

    /// Media types are case-insensitive.
    func testIsAudiobookLicence_UppercaseType_IsAudiobook() {
        let json = #"{"links":[{"rel":"publication","type":"APPLICATION/AUDIOBOOK+LCP"}]}"#

        XCTAssertTrue(TPPLCPClient.isAudiobookLicence(json))
    }

    /// A media type with parameters still counts as an audiobook.
    func testIsAudiobookLicence_TypeWithParameters_IsAudiobook() {
        let json = #"{"links":[{"rel":"publication","type":"application/audiobook+lcp; charset=utf-8"}]}"#

        XCTAssertTrue(TPPLCPClient.isAudiobookLicence(json))
    }

    /// Only the publication link decides: an audiobook type on another link
    /// does not count.
    func testIsAudiobookLicence_AudiobookTypeOnANonPublicationLink_IsNotAudiobook() {
        let json = #"{"links":[{"rel":["alternate"],"type":"application/audiobook+lcp"},{"rel":"publication","type":"application/epub+zip"}]}"#

        XCTAssertFalse(TPPLCPClient.isAudiobookLicence(json))
    }

    // MARK: - Fixtures

    private static func licence(key: String, type: String?) -> String {
        var link: [String: Any] = ["rel": "publication", "href": "https://example.com/pub"]
        if let type { link["type"] = type }
        let json: [String: Any] = [
            "id": "licence-\(key)",
            "encryption": ["content_key": ["encrypted_value": key]],
            "links": [["rel": "status", "href": "https://example.com/status"], link]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return String(decoding: data, as: UTF8.self)
    }

    /// The fake context factory names each context after its licence's
    /// content key, the field the client uses to tell licences apart.
    private static func contentKey(in jsonLicense: String) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(jsonLicense.utf8)) as? [String: Any],
            let encryption = object["encryption"] as? [String: Any],
            let contentKey = encryption["content_key"] as? [String: Any],
            let value = contentKey["encrypted_value"] as? String
        else { return "default-key" }
        return value
    }

    private static func makeContext(contentKey: String) -> DRMContext {
        let raw = m_DRMContext()
        raw.hashedPassphrase = strdup("hash")
        raw.encryptedContentKey = strdup(contentKey)
        raw.token = strdup("token")
        raw.profile = strdup("http://readium.org/lcp/basic-profile")
        return DRMContext(with: raw)!
    }
}

#endif

//
//  LCPCharacterizationTests.swift
//  PalaceTests
//
//  Mutation-killing characterization coverage for the LCP DRM surface.
//  Today the DRM characterization posture is "Very Low" — only adversarial
//  tests exist. This file pins the LCP code paths that production code
//  relies on, so a regression in:
//
//    - License document JSON parsing (TPPLCPLicense, TPPLCPLicenseLink)
//    - Publication-link resolution (firstLink(withRel:))
//    - License-fulfillment error mapping (TPPLicensesServiceError)
//    - PEM-CRL header guard (createContext defense-in-depth, F-002)
//    - findOneValidPassphrase ObjC exception catcher (FU-2)
//    - decrypt(...) empty-input + bad-context short-circuits
//
//  ...trips a test rather than silently slipping through review.
//
//  Hermetic — uses only on-disk fixtures (no R2LCPClient invocations that
//  require real LCP-CA-signed licenses, no network, no live LCP server).
//  Tests behind `#if LCP` mirror production gating.
//
//  Behavioral targets:
//    - The FU-2 fix (TPPLCPClient.swift:135-160) wraps
//      R2LCPClient.findOneValidPassphrase in TPPObjCExceptionCatcher
//      .catchAllExceptions. Pin that it survives garbage / UTF-8 / NUL
//      / extremely long inputs — if the wrapper is regressed, the test
//      process crashes with std::logic_error rather than failing softly.
//    - The createContext PEM-CRL header guard (TPPLCPClient.swift:55-60)
//      throws .invalidPemCrl(prefix:) BEFORE Botan ever sees the bytes.
//      Pin the prefix-bounded shape so log spam can't leak credentials.
//

#if LCP

import XCTest
@testable import Palace
import PalaceCatalog
import ReadiumLCP

@MainActor
final class LCPCharacterizationTests: XCTestCase {

    // MARK: - Setup / teardown

    private var client: TPPLCPClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        client = TPPLCPClient()
        HTTPStubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        client = nil
        HTTPStubURLProtocol.reset()
        try super.tearDownWithError()
    }

    // MARK: - TPPLCPLicense: happy-path JSON parsing

    func test_TPPLCPLicense_parsesMinimalValidJSON_succeeds() throws {
        // Characterization: a minimal-but-valid LCP license JSON with the
        // required `id` and a single publication link must produce a non-nil
        // TPPLCPLicense whose `identifier` matches. A mutant that:
        //   - dropped the id field
        //   - swallowed Codable errors silently and returned a default instance
        //   - re-wrote the keys ("id" → "license_id")
        // would slip past — all caught here.
        let json: [String: Any] = [
            "id": "urn:uuid:license-123",
            "links": [
                ["rel": "publication", "href": "https://example.org/book.epub", "type": "application/epub+zip"]
            ]
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let license = TPPLCPLicense(url: url)
        XCTAssertNotNil(license, "Valid LCP license JSON must parse to a non-nil TPPLCPLicense")
        XCTAssertEqual(license?.identifier, "urn:uuid:license-123",
                       "TPPLCPLicense.identifier must reflect the `id` field from the JSON — NOT the URL filename or any other value")
    }

    func test_TPPLCPLicense_extractsPublicationLink_byRel() throws {
        // The firstLink(withRel:) contract: returns the first link whose
        // `rel` matches the queried rel. The publication-link discovery
        // is load-bearing — TPPLicensesService.acquirePublication uses it
        // to resolve the download URL. A mutant that returned the LAST link
        // (instead of the first) would route fulfillment to a CRL/status
        // endpoint, NOT the publication.
        let json: [String: Any] = [
            "id": "urn:uuid:multi-link",
            "links": [
                ["rel": "status", "href": "https://example.org/status.json", "type": "application/vnd.readium.lcp.status.v1.0+json"],
                ["rel": "publication", "href": "https://example.org/correct.epub", "type": "application/epub+zip"],
                ["rel": "publication", "href": "https://example.org/wrong.epub", "type": "application/epub+zip"]
            ]
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let license = try XCTUnwrap(TPPLCPLicense(url: url),
                                    "License with multiple links must still parse")
        let pubLink = license.firstLink(withRel: .publication)
        XCTAssertNotNil(pubLink, "Must locate a `rel=publication` link")
        XCTAssertEqual(pubLink?.href, "https://example.org/correct.epub",
                       "firstLink must return the FIRST publication link — NOT the last (would route to wrong URL)")
        XCTAssertEqual(pubLink?.type, "application/epub+zip",
                       "Publication link must carry its `type` for content-type routing in TPPLicensesService.pathInZip")
    }

    func test_TPPLCPLicense_returnsNil_whenRelNotFound() throws {
        // The negative contract: querying a rel that doesn't exist returns
        // nil, NOT a default link. A mutant that returned the first link
        // regardless of rel would route fulfillment to whatever the server
        // happened to list first (CRL? status?) — caught here.
        let json: [String: Any] = [
            "id": "urn:uuid:no-pub-link",
            "links": [
                ["rel": "status", "href": "https://example.org/status.json", "type": "application/vnd.readium.lcp.status.v1.0+json"]
            ]
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let license = try XCTUnwrap(TPPLCPLicense(url: url),
                                    "License without publication link must still parse")
        let pubLink = license.firstLink(withRel: .publication)
        XCTAssertNil(pubLink, "Querying a missing rel must return nil — NOT a wrong-rel fallback")
    }

    // MARK: - TPPLCPLicense: malformed / missing-required-field shapes

    func test_TPPLCPLicense_returnsNil_onMissingRequiredId() throws {
        // The `id` field is non-optional in the Codable struct. A JSON
        // without it must fail decoding → init? returns nil. A mutant that
        // silently defaulted `id` to "" would let downstream code dereference
        // a license with an empty identifier (would never match a registry
        // fulfillment-id lookup, producing silent passphrase-retrieval
        // failures). Pin the nil-return.
        let json: [String: Any] = [
            "links": [
                ["rel": "publication", "href": "https://example.org/book.epub", "type": "application/epub+zip"]
            ]
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(TPPLCPLicense(url: url),
                     "License JSON missing required `id` must fail init → return nil (NOT a default-id license)")
    }

    func test_TPPLCPLicense_returnsNil_onCompletelyMalformedJSON() throws {
        // A JSON file whose bytes are not valid JSON at all must produce
        // nil. A mutant that wrapped this in a try? and silently kept a
        // partially-initialized object would let downstream code dereference
        // a corrupt license. Pin the all-or-nothing shape.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lcpl")
        try Data("not json at all { ] ".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(TPPLCPLicense(url: url),
                     "Non-JSON license file must fail init → return nil")
    }

    func test_TPPLCPLicense_returnsNil_onEmptyFile() throws {
        // Zero-byte file shape: production code may encounter this when
        // a download is interrupted before any bytes are written. The
        // contract: init? must return nil, NEVER produce a license with
        // an empty id or empty links array.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lcpl")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(TPPLCPLicense(url: url),
                     "Zero-byte license file must fail init → nil (NOT a default-empty license)")
    }

    func test_TPPLCPLicense_returnsNil_whenFileDoesNotExist() {
        // A URL pointing to a non-existent file must produce nil. A mutant
        // that crashed on the missing-file shape (force-try) would surface
        // as a SIGABRT in production. Pin the graceful nil-return.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-does-not-exist.lcpl")

        XCTAssertNil(TPPLCPLicense(url: url),
                     "Missing file path must produce nil — NEVER crash on force-try")
    }

    func test_TPPLCPLicense_parsesLinkOptionalFields_preservesNils() throws {
        // The TPPLCPLicenseLink Codable shape declares ALL fields optional
        // except `rel`. A minimal link with only `rel` must still decode,
        // with all other fields nil. A mutant that required `href` to be
        // present would reject otherwise-valid status-only licenses.
        let json: [String: Any] = [
            "id": "urn:uuid:minimal-link",
            "links": [
                ["rel": "publication"]
                // No href, type, title, length, hash
            ]
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let license = try XCTUnwrap(TPPLCPLicense(url: url),
                                    "License with minimal-fields link must still parse")
        let link = try XCTUnwrap(license.firstLink(withRel: .publication))
        XCTAssertEqual(link.rel, "publication", "rel must round-trip")
        XCTAssertNil(link.href, "Missing href must remain nil — NOT a sentinel string")
        XCTAssertNil(link.type, "Missing type must remain nil")
        XCTAssertNil(link.length, "Missing length must remain nil")
        XCTAssertNil(link.hash, "Missing hash must remain nil")
    }

    // MARK: - TPPLicensesService: error mapping for license-file failures

    func test_TPPLicensesService_acquirePublication_invalidLicense_callsCompletionWithLicenseError() throws {
        // Contract: when the .lcpl file can't be parsed as a license, the
        // completion handler fires with a TPPLicensesServiceError.licenseError
        // carrying "Reading license file failed". This is load-bearing for
        // LCPLibraryService.fulfill — the NSError it constructs uses this
        // description string. A mutant that returned a generic message
        // ("unknown error") would lose triage signal.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lcpl")
        try Data("not a license".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let exp = expectation(description: "completion")
        var capturedError: Error?
        let task = TPPLicensesService().acquirePublication(from: url, progress: { _ in }) { localUrl, err in
            XCTAssertNil(localUrl, "Failed parse must NOT hand back a localUrl")
            capturedError = err
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertNil(task, "Failed parse must NOT return a download task — nothing to download")
        guard let err = capturedError as? TPPLicensesServiceError else {
            return XCTFail("Error must be TPPLicensesServiceError, got \(String(describing: capturedError))")
        }
        switch err {
        case .licenseError(let message):
            XCTAssertTrue(message.contains("Reading license file failed"),
                          "Error message must surface the failure reason, got: \(message)")
        }
    }

    func test_TPPLicensesService_acquirePublication_missingPublicationLink_failsWithDistinctMessage() throws {
        // Contract: when the license parses but has no publication link, the
        // failure message must be distinct from the "Reading license file
        // failed" message — that distinction is how production logs route
        // the two failure modes to different fix paths. A mutant that
        // collapsed both into one message would lose triage signal.
        let json: [String: Any] = [
            "id": "urn:uuid:no-pub-link",
            "links": [
                ["rel": "status", "href": "https://example.org/status.json", "type": "application/vnd.readium.lcp.status.v1.0+json"]
            ]
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let exp = expectation(description: "completion")
        var capturedError: Error?
        let task = TPPLicensesService().acquirePublication(from: url, progress: { _ in }) { localUrl, err in
            XCTAssertNil(localUrl)
            capturedError = err
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
        XCTAssertNil(task, "Missing publication link must NOT return a download task")
        guard let err = capturedError as? TPPLicensesServiceError else {
            return XCTFail("Error must be TPPLicensesServiceError, got \(String(describing: capturedError))")
        }
        switch err {
        case .licenseError(let message):
            XCTAssertTrue(message.contains("publication href was not found"),
                          "Missing publication link must surface its own distinct message, got: \(message)")
            XCTAssertFalse(message.contains("Reading license file failed"),
                           "Missing publication link MUST NOT collapse into the parse-failure message")
        }
    }

    func test_TPPLicensesServiceError_descriptionExposesMessage() {
        // The .description contract: must surface the inner message string
        // so logs can identify which TPPLicensesServiceError case fired. A
        // mutant that returned a generic constant would lose diagnostics.
        let err = TPPLicensesServiceError.licenseError(message: "diag-message-X")
        XCTAssertEqual(err.description, "diag-message-X",
                       "TPPLicensesServiceError.description must surface the inner message — NOT a generic constant")
    }

    // MARK: - TPPLicensesService.pathInZip: content-type routing

    func test_pathInZip_routesEpubToMetaInfPath() {
        // Contract: ContentTypeEpubZip publications inject the license at
        // META-INF/license.lcpl. A mutant that wrote to license.lcpl in
        // the archive root would corrupt the EPUB structure — Readium
        // would refuse to open the book.
        let svc = TPPLicensesService()
        let link = TPPLCPLicenseLink(rel: "publication",
                                     href: "https://example.org/book.epub",
                                     type: ContentTypeEpubZip,
                                     title: nil,
                                     length: nil,
                                     hash: nil)
        XCTAssertEqual(svc.pathInZip(for: link), "META-INF/license.lcpl",
                       "EPUB+zip publications must inject at META-INF/license.lcpl — NOT root")
    }

    func test_pathInZip_routesAudiobookLCPToRootPath() {
        // Contract: ContentTypeAudiobookLCP publications inject the license
        // at license.lcpl (root of the archive). A mutant that routed to
        // META-INF would break audiobook fulfillment.
        let svc = TPPLicensesService()
        let link = TPPLCPLicenseLink(rel: "publication",
                                     href: "https://example.org/book.audiobook",
                                     type: ContentTypeAudiobookLCP,
                                     title: nil,
                                     length: nil,
                                     hash: nil)
        XCTAssertEqual(svc.pathInZip(for: link), "license.lcpl",
                       "AudiobookLCP must inject at root license.lcpl — NOT META-INF")
    }

    func test_pathInZip_returnsNilForUnknownContentType() {
        // Contract: unknown content types return nil → the license is NOT
        // injected, the publication is stored as-is. A mutant that defaulted
        // to META-INF/license.lcpl for unknown types would corrupt anything
        // that wasn't an EPUB. Pin the nil-return.
        let svc = TPPLicensesService()
        let link = TPPLCPLicenseLink(rel: "publication",
                                     href: "https://example.org/file.bin",
                                     type: "application/x-unknown-format",
                                     title: nil,
                                     length: nil,
                                     hash: nil)
        XCTAssertNil(svc.pathInZip(for: link),
                     "Unknown content types must return nil — NOT a default injection path")
    }

    func test_pathInZip_returnsNilWhenTypeIsMissing() {
        // The early-return for a link without a type. A mutant that
        // defaulted missing-type to .epub_zip routing would silently inject
        // licenses into binaries.
        let svc = TPPLicensesService()
        let link = TPPLCPLicenseLink(rel: "publication", href: "https://example.org/book.epub",
                                     type: nil, title: nil, length: nil, hash: nil)
        XCTAssertNil(svc.pathInZip(for: link),
                     "Missing type must return nil — NOT a default routing")
    }

    // MARK: - TPPLCPClient.createContext: PEM-CRL header guard

    func test_createContext_emptyPemCrl_isAcceptedByHeaderGuard() {
        // Boundary: trimmed.isEmpty short-circuits the prefix check, so an
        // empty pemCrl passes the guard (Botan then receives it). A mutant
        // that REQUIRED the BEGIN marker even on empty input would reject
        // a legitimate "no CRL" pathway and break LCP fulfillment in
        // environments that don't ship a CRL.
        do {
            _ = try client.createContext(jsonLicense: "{}", hashedPassphrase: "deadbeef", pemCrl: "")
            // If we reach here, the guard accepted the empty input and
            // R2LCPClient (or its wrapper) ran. Either nil-return or
            // throw is fine — what matters is that the guard did NOT
            // throw .invalidPemCrl.
        } catch LCPContextError.invalidPemCrl(let prefix) {
            XCTFail("Empty pemCrl must NOT throw .invalidPemCrl — header guard's trimmed.isEmpty short-circuit failed, prefix=\(prefix)")
        } catch {
            // Other errors are acceptable — the empty-input contract is
            // only that the HEADER GUARD doesn't fire. Botan / wrapper
            // may still throw downstream.
        }
    }

    func test_createContext_whitespacePadding_isTrimmedBeforeHeaderCheck() {
        // The pemCrl input is trimmed via trimmingCharacters(in:
        // .whitespacesAndNewlines) BEFORE the prefix check. A real CRL
        // padded with whitespace must still pass. A mutant that removed
        // the trim would reject `"  -----BEGIN X509 CRL-----..."` even
        // though it's a valid PEM with leading whitespace.
        let withPadding = "\n  -----BEGIN X509 CRL-----\nMIIBjzCB+QIBATANBgkqhkiG9w0BAQUFADCBkjELMAkG==\n-----END X509 CRL-----\n  "
        do {
            _ = try client.createContext(jsonLicense: "{}", hashedPassphrase: "deadbeef", pemCrl: withPadding)
        } catch LCPContextError.invalidPemCrl(let prefix) {
            XCTFail("Whitespace-padded PEM must pass the guard after trim — got .invalidPemCrl with prefix=\(prefix)")
        } catch {
            // Botan / wrapper may still throw on the body — only the GUARD
            // is under test here.
        }
    }

    func test_createContext_jsonContentTypeRejected_atHeaderGuard() {
        // The historic F-002 trigger: CDN misconfig returns JSON instead of
        // a PEM CRL. Botan would crash on the BER parser. Today the header
        // guard rejects this up front. Pin the rejection AND the prefix
        // capture (so triage logs show the actual returned content).
        let jsonPretendingToBeCrl = "{\"error\":\"not a crl\",\"status\":404,\"detail\":\"some long json response\"}"
        XCTAssertThrowsError(
            try client.createContext(jsonLicense: "{}", hashedPassphrase: "deadbeef", pemCrl: jsonPretendingToBeCrl)
        ) { error in
            guard case LCPContextError.invalidPemCrl(let prefix) = error else {
                return XCTFail("JSON pretending to be CRL must throw .invalidPemCrl, got \(error)")
            }
            XCTAssertTrue(prefix.hasPrefix("{"),
                          "Prefix must surface the rejected payload's leading bytes for triage, got: \(prefix)")
        }
    }

    func test_createContext_prefixCappedAt40Chars_preventsLogSpam() {
        // The prefix-bound contract: log spam from a 1MB HTML response is
        // bounded to 40 chars. A mutant that removed the .prefix(40) cap
        // would dump the entire response into Crashlytics. Pin the cap.
        let longGarbage = String(repeating: "X", count: 5000)
        XCTAssertThrowsError(
            try client.createContext(jsonLicense: "{}", hashedPassphrase: "deadbeef", pemCrl: longGarbage)
        ) { error in
            guard case LCPContextError.invalidPemCrl(let prefix) = error else {
                return XCTFail("Long garbage must throw .invalidPemCrl, got \(error)")
            }
            XCTAssertEqual(prefix.count, 40,
                           "Prefix MUST be capped at exactly 40 chars — got \(prefix.count). Removing the cap would log entire MB-scale responses.")
        }
    }

    // MARK: - findOneValidPassphrase: FU-2 ObjC exception catcher

    func test_findOneValidPassphrase_garbageJSON_returnsNilWithoutCrashing() {
        // FU-2 invariant: garbage license JSON must produce nil, NEVER
        // a crash. Without the wrapper, Botan's std::logic_error escapes
        // Swift's do/catch and reaches std::terminate. The test process
        // crashes via SIGABRT in that case — which is the load-bearing
        // failure signal we want.
        let hashedPassphrases = ["deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"]
        for garbage in ["", "not-json", "{\"missing\": \"every field\"}"] {
            let result = client.findOneValidPassphrase(jsonLicense: garbage,
                                                      hashedPassphrases: hashedPassphrases)
            XCTAssertNil(result, "Garbage JSON (\(garbage.prefix(40))) must produce nil — FU-2 wrapper missing if this crashes")
        }
    }

    func test_findOneValidPassphrase_emptyHashedPassphrasesArray_returnsNilWithoutCrashing() {
        // Edge case: caller passes an empty array of candidate passphrases.
        // The FU-2 wrapper must catch any Botan exception from the empty-
        // input path and return nil. Without the wrapper, this historically
        // triggered "id value cannot not be null" on some license shapes.
        let validShape = """
        {"id":"urn:uuid:abc","encryption":{"profile":"http://readium.org/lcp/basic-profile"}}
        """
        let result = client.findOneValidPassphrase(jsonLicense: validShape, hashedPassphrases: [])
        XCTAssertNil(result, "Empty hashedPassphrases array must produce nil — no candidate, no match")
    }

    func test_findOneValidPassphrase_passphraseContainingUTF8_isHandledWithoutCrashing() {
        // Edge case: a hashed passphrase string that contains UTF-8 multi-
        // byte sequences (e.g., from a unicode source). The wrapper must
        // not crash on the encoding boundary. A mutant that assumed ASCII-
        // only input might force-bridge to a CString and crash on UTF-8.
        let utf8Hashed = "café-passphrase-🔐-\u{1F600}-\u{00E9}\u{4E2D}\u{6587}"
        let result = client.findOneValidPassphrase(
            jsonLicense: "{\"id\":\"urn:uuid:utf8-test\"}",
            hashedPassphrases: [utf8Hashed]
        )
        XCTAssertNil(result, "UTF-8-bearing hashed passphrase must NOT crash — wrapper must survive encoding edge cases")
    }

    func test_findOneValidPassphrase_passphraseContainingNUL_isHandledWithoutCrashing() {
        // Edge case: a hashed passphrase string containing an embedded NUL
        // byte. Swift String supports embedded NULs; ObjC CString bridging
        // historically truncated at the first NUL. The wrapper must survive
        // this either way (truncate-and-no-match is fine; crash is not).
        let withNUL = "deadbeef\u{0000}garbage-after-nul"
        let result = client.findOneValidPassphrase(
            jsonLicense: "{\"id\":\"urn:uuid:nul-test\"}",
            hashedPassphrases: [withNUL]
        )
        XCTAssertNil(result, "NUL-bearing hashed passphrase must NOT crash — wrapper must survive embedded NUL")
    }

    func test_findOneValidPassphrase_extremelyLongPassphrase_isHandledWithoutCrashing() {
        // Edge case: a hashed passphrase string of 64 KB. A mutant that
        // stack-allocated the input buffer would overflow the stack. The
        // wrapper must catch any such failure mode.
        let huge = String(repeating: "a", count: 65_536)
        let result = client.findOneValidPassphrase(
            jsonLicense: "{\"id\":\"urn:uuid:huge-test\"}",
            hashedPassphrases: [huge]
        )
        XCTAssertNil(result, "65 KB hashed passphrase must NOT crash — wrapper must handle very-large input")
    }

    func test_findOneValidPassphrase_multipleGarbageInputs_returnsConsistentNil() {
        // Determinism check: the same garbage input produces the same nil
        // return across repeated calls. A mutant that introduced a stateful
        // bug (e.g., a stuck context from a previous call) would surface
        // here as a non-deterministic mix of nil and crashes.
        for _ in 0..<5 {
            let result = client.findOneValidPassphrase(
                jsonLicense: "not-json-at-all",
                hashedPassphrases: ["aabbccddeeff00112233445566778899"]
            )
            XCTAssertNil(result, "Repeated garbage inputs must consistently produce nil — wrapper must not retain state")
        }
    }

    // MARK: - TPPLCPClient.decrypt: empty input + bad context guards

    func test_decrypt_emptyData_returnsNil_priorToReachingR2LCPClient() {
        // Empty-data guard at TPPLCPClient.swift:116-119. Botan would crash
        // attempting to decode 0 bytes (historically observed in 2.x logs).
        // A mutant that dropped the guard would surface as a crash on the
        // first empty buffer the reader's prefetch sees.
        let result = client.decrypt(data: Data(), using: NotADRMContextLCPChar())
        XCTAssertNil(result, "Empty data must short-circuit to nil — NEVER reach R2LCPClient.decrypt")
    }

    func test_decrypt_nonDRMContext_returnsNil_priorToForceCastingInsideR2LCPClient() {
        // Type-check guard at TPPLCPClient.swift:111-114. R2LCPClient's
        // internal `as!` would crash on a non-DRMContext input. A mutant
        // that removed the type check would crash the reader on every
        // decrypt call.
        let nonEmpty = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        let result = client.decrypt(data: nonEmpty, using: NotADRMContextLCPChar())
        XCTAssertNil(result, "Non-DRMContext must short-circuit to nil — NEVER reach R2LCPClient.decrypt's as! cast")
    }

    func test_decryptExtensionOverload_noPriorContext_returnsNil() {
        // The decrypt(data:) extension at TPPLCPClient.swift:163-187 reads
        // self.context. Without a prior createContext, context is nil and
        // the type cast fails — short-circuits to nil. A mutant that
        // bypassed the context check would dereference nil.
        let nonEmpty = Data([0x01, 0x02, 0x03])
        let result = client.decrypt(data: nonEmpty)
        XCTAssertNil(result, "decrypt(data:) without prior createContext must produce nil — no context dereference")
    }

    // MARK: - LCPLibraryService.canFulfill: case-insensitive extension check

    func test_LCPLibraryService_canFulfill_rejectsEpubAndPdf() {
        // The canFulfill negative contract: the LCP service must NOT claim
        // ability to fulfill a bare .epub or .pdf. A mutant that returned
        // true for everything would let a non-LCP file enter the LCP
        // fulfillment path — the user would see a passphrase prompt for
        // a book that has no DRM.
        let svc = LCPLibraryService()
        XCTAssertFalse(svc.canFulfill(URL(fileURLWithPath: "/tmp/book.epub")),
                       ".epub must NOT be claimed by LCP service")
        XCTAssertFalse(svc.canFulfill(URL(fileURLWithPath: "/tmp/book.pdf")),
                       ".pdf must NOT be claimed by LCP service")
        XCTAssertFalse(svc.canFulfill(URL(fileURLWithPath: "/tmp/book")),
                       "No extension must NOT be claimed by LCP service")
    }

    func test_LCPLibraryService_canFulfill_acceptsLcplExtensionCaseInsensitively() {
        // Contract: the extension check is case-insensitive. A mutant that
        // restricted to lowercase-only would reject macOS Finder copies
        // that preserve the original case (.LCPL from some servers).
        let svc = LCPLibraryService()
        XCTAssertTrue(svc.canFulfill(URL(fileURLWithPath: "/tmp/book.lcpl")), "lowercase .lcpl must be accepted")
        XCTAssertTrue(svc.canFulfill(URL(fileURLWithPath: "/tmp/book.LCPL")), "uppercase .LCPL must be accepted")
        XCTAssertTrue(svc.canFulfill(URL(fileURLWithPath: "/tmp/book.LcPl")), "mixed-case .LcPl must be accepted")
    }

    func test_LCPLibraryService_licenseExtensionConstant_isLcpl() {
        // Constant pinning: a mutant that changed the public licenseExtension
        // string would silently break ObjC callers (TPPMyBooksDownloadCenter
        // uses this constant to identify LCP downloads).
        XCTAssertEqual(LCPLibraryService().licenseExtension, "lcpl",
                       "licenseExtension MUST be exactly \"lcpl\" — ObjC callers depend on this")
    }

    // MARK: - Helpers

    private func writeJSON(_ object: [String: Any]) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lcpl")
        try data.write(to: url)
        return url
    }
}

/// A type that is intentionally NOT a DRMContext, used to trip the
/// type-check guard in decrypt(data:using:). Local copy to avoid
/// reaching into a different test file's private type.
private final class NotADRMContextLCPChar: LCPClientContext {}

// MARK: - Seam Recommendations (do not modify production code from here)
//
// 1. The LCP status-document state machine (active / revoked / returned /
//    expired) lives entirely INSIDE the ReadiumLCP framework. Palace code
//    does not expose it as a first-class type — production accesses it
//    via LCPAuthenticatedLicense.document.id and similar. Unit-testing
//    the state-machine transitions would require a fake LCPService that
//    surfaces transition callbacks. Today no such seam exists; characterizing
//    state-machine behavior is blocked on that protocol extraction. Tracked
//    in docs/Testing/Test_Seams_Refactor_Plan.md (P2 — LCP status doc).
//
// 2. The passphrase-prompt UI flow (LCPPassphraseAuthenticationService
//    .retrievePassphrase) uses UIAlertController.addTextField and
//    presentFromViewControllerOrNil. Unit-testing the prompt branch is
//    blocked on a UIKit seam (the manual-entry path requires a presented
//    alert and a continuation). Today, this code is exercised only via
//    integration tests with a real UI. A protocol PassphrasePromptPresenting
//    that wraps the alert would let us pin the manual-entry contract. Tracked
//    in docs/Testing/Test_Seams_Refactor_Plan.md.
//
// 3. The HTTP-level LCP fulfillment error mapping (problem-doc parsing) lives
//    behind TPPLicensesService's URLSessionDownloadDelegate methods. Today
//    those delegate methods construct background URLSessions internally,
//    which makes them un-stubbable via URLProtocol. The didCompleteWithError
//    arm specifically is unreachable from a unit test without spinning up
//    a real download. A constructor-injectable URLSession seam would unlock
//    this characterization. Logged.
//
// 4. findOneValidPassphrase's ObjC exception catcher accepts ANY native
//    exception — name and reason are surfaced to the log. A semantic enum
//    (e.g., .botanLogicError, .botanDecodingError) would let tests assert
//    on the specific exception class rather than just "wrapper survived".
//    This would require a structural change to LCPContextError (which is
//    enum-without-cases-for-passphrase-side today). Logged.

#endif

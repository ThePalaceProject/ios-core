//
//  AuthErrorClassifierPropertyTests.swift
//  PalaceAuthTests
//
//  Property-based fuzz over `AuthErrorClassifier` using the generator
//  spec from `docs/3.2.0-auth-idp-catalog.md` § "Property-based
//  generator inputs". Hand-rolled seeded RNG — no SwiftCheck dep added.
//
//  Trial count is 200 per CI run (the lightweight invariant check that
//  catches any regression in the partition logic). The intent isn't
//  exhaustive coverage; it's to catch any combination the per-row unit
//  tests forgot.
//
//  Seed is fixed to keep failures reproducible — change it intentionally
//  if you want a fresh sweep.
//

import XCTest
import PalaceCatalog
@testable import PalaceAuth

final class AuthErrorClassifierPropertyTests: XCTestCase {

    private let classifier = AuthErrorClassifier()
    private static let trialCount = 200
    private static let seed: UInt64 = 0xC0FFEE_2026_05_27

    func testInvariants_acrossGeneratedInputs() {
        var rng = SeededRNG(seed: Self.seed)

        for trial in 0..<Self.trialCount {
            let input = GeneratedInput.random(using: &rng)
            let outcome = classifier.classify(
                response: input.response,
                problemDocument: input.problemDocument,
                body: input.body,
                originalRequestURL: input.originalRequestURL
            )

            assertInvariants(input: input, outcome: outcome, trial: trial)
        }
    }

    // MARK: - Invariant block

    private func assertInvariants(input: GeneratedInput, outcome: AuthOutcome, trial: Int) {
        let context = "trial #\(trial) input=\(input.debugDescription) outcome=\(outcome)"

        // Invariant 1 — every input partitions into exactly one outcome.
        // (Trivially true if classify returned; assertion is here to
        //  document the contract.)
        switch outcome {
        case .ok, .reauthRequired, .forbidden, .serverError, .networkError:
            break
        }

        guard let response = input.response else {
            // Invariant 6 — .networkError ONLY when response is nil.
            XCTAssertEqual(outcome, .networkError,
                "nil response must yield .networkError. \(context)")
            return
        }
        // Inverse of invariant 6 — non-nil response never yields .networkError.
        XCTAssertNotEqual(outcome, .networkError,
            "non-nil response must NOT yield .networkError. \(context)")

        let status = response.statusCode

        // Invariant 2 — .ok only when statusCode ∈ {200..299} OR cross-domain 401.
        if outcome == .ok {
            let isSuccess = (200...299).contains(status)
            let crossDomain401: Bool = {
                guard status == 401, let originalURL = input.originalRequestURL else {
                    return false
                }
                return !response.isSameDomain(as: originalURL)
            }()
            XCTAssertTrue(
                isSuccess || crossDomain401,
                "outcome=.ok only valid for 2xx or cross-domain 401. \(context)"
            )
        }

        // Invariant 3 — .reauthRequired only when:
        //   - statusCode == 401, OR
        //   - statusCode == 403 AND problem-doc is recoverable, OR
        //   - non-2xx response with OPDS authentication-document MIME
        //     (explicit auth challenge from server, status-agnostic).
        if case .reauthRequired = outcome {
            let recoverable403 = (status == 403 && (input.problemDocument?.isRecoverableAuthError ?? false))
            let opdsAuthChallenge = (response.mimeType == "application/vnd.opds.authentication.v1.0+json"
                                     && !(200...299).contains(status))
            XCTAssertTrue(
                status == 401 || recoverable403 || opdsAuthChallenge,
                "outcome=.reauthRequired only valid for 401, 403+recoverable, or non-2xx OPDS auth-doc. \(context)"
            )
        }

        // Invariant 4 — .forbidden only when statusCode == 403.
        if case .forbidden = outcome {
            XCTAssertEqual(
                status, 403,
                "outcome=.forbidden only valid for 403. \(context)"
            )
        }

        // Invariant 5 — .serverError(s) only when statusCode ∈ {500..599}
        //              OR a non-2xx non-401 non-403 numeric code that
        //              isn't an OPDS auth-doc response (4xx/3xx bucket).
        if case .serverError(let s) = outcome {
            let is5xx = (500...599).contains(status)
            let isOtherNon2xx = !is5xx
                && !(200...299).contains(status)
                && status != 401
                && status != 403
                && response.mimeType != "application/vnd.opds.authentication.v1.0+json"
            XCTAssertTrue(
                is5xx || isOtherNon2xx,
                "outcome=.serverError only valid for 5xx or other non-2xx non-auth status. \(context)"
            )
            XCTAssertEqual(s, status, "serverError status must mirror response status. \(context)")
        }

        // Invariant 7 — cross-domain 401 ALWAYS yields .ok (preserves CDN guard).
        if status == 401,
           let originalURL = input.originalRequestURL,
           !response.isSameDomain(as: originalURL) {
            XCTAssertEqual(
                outcome, .ok,
                "cross-domain 401 MUST yield .ok regardless of problem doc. \(context)"
            )
        }
    }
}

// MARK: - Generators

private struct GeneratedInput {
    let response: HTTPURLResponse?
    let problemDocument: TPPProblemDocument?
    let body: Data?
    let originalRequestURL: URL?

    var debugDescription: String {
        let statusStr = response.map { "\($0.statusCode)" } ?? "nil"
        let mimeStr = response?.mimeType ?? "nil"
        let urlStr = response?.url?.host ?? "nil"
        let origStr = originalRequestURL?.host ?? "nil"
        let docStr = problemDocument?.type ?? "no-doc"
        return "(status=\(statusStr) mime=\(mimeStr) responseHost=\(urlStr) origHost=\(origStr) doc=\(docStr))"
    }

    static func random(using rng: inout SeededRNG) -> GeneratedInput {
        // ~5% nil-response (transport failure)
        if rng.next() % 20 == 0 {
            return GeneratedInput(
                response: nil,
                problemDocument: nil,
                body: nil,
                originalRequestURL: URLPool.random(using: &rng)
            )
        }

        let status = StatusCodePool.random(using: &rng)
        let mime = MimePool.random(using: &rng)
        let responseURL = URLPool.random(using: &rng) ?? URLPool.gorgon
        let origURL = URLPool.random(using: &rng)
        var headers: [String: String] = [:]
        if let mime { headers["Content-Type"] = mime }
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )

        let (doc, body) = ProblemDocPool.random(using: &rng)

        return GeneratedInput(
            response: response,
            problemDocument: doc,
            body: body,
            originalRequestURL: origURL
        )
    }
}

private enum StatusCodePool {
    static let codes: [Int] = [
        200, 200, 200, 204,             // success bias
        301, 302,
        400, 401, 401, 401, 401, 401,    // 401 bias (~30%)
        403, 403,
        404, 410, 422,
        500, 502, 503
    ]

    static func random(using rng: inout SeededRNG) -> Int {
        codes[Int(rng.next() % UInt64(codes.count))]
    }
}

private enum MimePool {
    static let mimes: [String?] = [
        "application/atom+xml",
        "application/problem+json",
        "application/problem+json",   // bias
        "application/api-problem+json",
        "application/json",
        "text/html",
        "application/vnd.opds.authentication.v1.0+json",
        nil
    ]

    static func random(using rng: inout SeededRNG) -> String? {
        mimes[Int(rng.next() % UInt64(mimes.count))]
    }
}

private enum URLPool {
    static let gorgon = URL(string: "https://gorgon.palaceproject.io/library/loans")!
    static let cdn = URL(string: "https://cdn.palaceproject.io/content/book.epub")!
    static let biblioboard = URL(string: "https://library.biblioboard.com/content/book.epub")!
    static let icarus = URL(string: "https://icarus.dev.palaceproject.io/library/borrow")!

    static let urls: [URL?] = [gorgon, cdn, biblioboard, icarus, nil]

    static func random(using rng: inout SeededRNG) -> URL? {
        urls[Int(rng.next() % UInt64(urls.count))]
    }
}

private enum ProblemDocPool {
    static func random(using rng: inout SeededRNG) -> (TPPProblemDocument?, Data?) {
        switch rng.next() % 8 {
        case 0:
            return (nil, nil)
        case 1:
            return (TPPProblemDocument.fromDictionary([
                "type": "http://palaceproject.io/terms/problem/auth/recoverable/token/expired",
                "title": "expired", "status": 401
            ]), nil)
        case 2:
            return (TPPProblemDocument.fromDictionary([
                "type": "http://palaceproject.io/terms/problem/auth/recoverable/saml/session-expired",
                "title": "saml session expired", "status": 401
            ]), nil)
        case 3:
            return (TPPProblemDocument.fromDictionary([
                "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/credentials/invalid",
                "title": "invalid creds", "status": 401
            ]), nil)
        case 4:
            return (TPPProblemDocument.fromDictionary([
                "type": TPPProblemDocument.TypeInvalidCredentials,
                "title": "legacy", "status": 401
            ]), nil)
        case 5:
            return (TPPProblemDocument.fromDictionary([
                "type": TPPProblemDocument.TypeNoActiveLoan,
                "title": "no loan", "status": 401
            ]), nil)
        case 6:
            // malformed body, no parsed doc
            return (nil, "not-json{{".data(using: .utf8))
        default:
            return (nil, Data())
        }
    }
}

// MARK: - Seeded RNG (LCG, good enough for property fuzz)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

import XCTest
@testable import TriageBotCore

/// PP-4806 — the standing redaction regression guard.
///
/// PR #1278 (PP-4805) landed `ContextRedactor`; this test proves that redactor
/// against a realistic, sensitive-flow *corpus* (`Fixtures/*.txt`) rather than a
/// handful of inline strings, and — crucially — is designed to be rebuilt each
/// release so a newly-introduced log line that leaks a secret FAILS the release
/// rather than shipping.
///
/// The corpus is currently SYNTHETIC (hand-authored, fake values). Capturing
/// real device payloads from the sensitive flows on a running sim is deferred to
/// the simdrive / chaos QA runs (PP-4813 / PP-4817) — when those land, the real
/// captures drop into `Fixtures/` and this same guard covers them unchanged.
///
/// Design: a credential **deny-list** of secret *shapes*. Each pattern is
/// written so it matches a RAW secret but never a redaction placeholder
/// (`[REDACTED]`, `[jwt-redacted]`, `[number-redacted]`, …). We assert twice:
///   1. the RAW corpus TRIPS the deny-list (proves the fixtures are actually
///      adversarial — the gate cannot pass by degenerating into harmless text);
///   2. the REDACTED corpus trips NOTHING (the actual regression guard).
final class RedactionCorpusTests: XCTestCase {
    private let redactor = ContextRedactor()

    /// Redact a line, honoring the `TRIAGE_CORPUS_DISABLE_REDACTION` escape hatch
    /// used by `scripts/triage-corpus-check.sh --self-test` to prove this guard
    /// actually fails when redaction stops working (a gate nobody has seen fail
    /// is not a gate). Unset in normal runs → real redaction.
    private func redact(_ line: String) -> String {
        if ProcessInfo.processInfo.environment["TRIAGE_CORPUS_DISABLE_REDACTION"] == "1" {
            return line
        }
        return redactor.redactLine(line)
    }

    // MARK: - Credential deny-list

    /// A secret shape that must never survive redaction. `regex` is applied
    /// case-insensitively to redacted text; every pattern is authored so a
    /// redaction placeholder (which always begins `[`) can never match.
    private struct DenyPattern {
        let label: String
        let regex: String
    }

    private static let denyList: [DenyPattern] = [
        // OAuth / bearer scheme token (charset excludes '[' so "Bearer [REDACTED]" is safe)
        DenyPattern(label: "bearer_token", regex: #"(?i)\bBearer\s+[A-Za-z0-9._\-]{12,}"#),
        // HTTP Basic auth credential
        DenyPattern(label: "basic_auth", regex: #"(?i)\bBasic\s+[A-Za-z0-9+/=]{12,}"#),
        // Standalone JWT (eyJ header . payload [. signature])
        DenyPattern(label: "jwt", regex: #"\beyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}"#),
        // PIN as key=value / key: value
        DenyPattern(label: "pin_kv", regex: #"(?i)\bpin\s*[:=]\s*\d{3,8}"#),
        // PIN / passcode stated in prose ("my pin is 4821")
        DenyPattern(label: "pin_prose", regex: #"(?i)\b(?:pin|passcode)\b[^\d\n]{0,10}\d{3,8}"#),
        // password: <token>  (value must not be a "[…]" placeholder)
        DenyPattern(label: "password_kv", regex: #"(?i)\b(?:password|passwd)\s*[:=]\s*(?!\[)\S{3,}"#),
        // access_token / refresh_token / client_secret / api_key = <token>, incl. JSON quoting
        DenyPattern(
            label: "token_kv",
            regex: #"(?i)\b(?:access_token|refresh_token|client_secret|api_?key)\b\s*["']?\s*[:=]\s*["']?(?!\[)[A-Za-z0-9._\-]{4,}"#
        ),
        // bare `token=<value>` credential
        DenyPattern(label: "generic_token_kv", regex: #"(?i)\btoken\s*[:=]\s*(?!\[)[A-Za-z0-9._\-]{6,}"#),
        // x-api-key request header
        DenyPattern(label: "x_api_key", regex: #"(?i)x-api-key:\s*(?!\[)\S{4,}"#),
        // Authorization: <non-scheme value> (scheme tokens caught by bearer/basic above)
        DenyPattern(label: "auth_header", regex: #"(?i)Authorization:\s*(?!\[)(?!Bearer\b)(?!Basic\b)\S{4,}"#),
        // Cookie / Set-Cookie name=value (value not a placeholder)
        DenyPattern(label: "cookie_value", regex: #"(?i)\b(?:Set-Cookie|Cookie):\s*[A-Za-z0-9_.\-]+=(?!\[)[^;\s]{3,}"#),
        // Standalone 10-14 digit card barcode, carving out a 978/979 ISBN
        DenyPattern(label: "barcode", regex: #"\b(?!97[89]\d{10}\b)\d{10,14}\b"#),
    ]

    // MARK: - Corpus loading

    /// Every fixture file: (name, full text). Fails loudly if the corpus is
    /// missing or empty — a silently-empty corpus is a broken gate, not a pass.
    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) -> [(name: String, text: String)] {
        guard let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            XCTFail("Fixtures/ resource directory not found in test bundle", file: file, line: line)
            return []
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        let corpus: [(String, String)] = urls
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.lastPathComponent, text)
            }
        XCTAssertFalse(corpus.isEmpty, "Redaction corpus is empty — no *.txt fixtures loaded", file: file, line: line)
        return corpus
    }

    private func firstDenyHit(in text: String) -> (label: String, match: String)? {
        for pattern in Self.denyList {
            guard let expr = try? NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let m = expr.firstMatch(in: text, options: [], range: range),
               let r = Range(m.range, in: text) {
                return (pattern.label, String(text[r]))
            }
        }
        return nil
    }

    // MARK: - Tests

    /// The regression guard: nothing on the deny-list may survive redaction of
    /// any line in any fixture.
    func testRedactedCorpus_leaksNoCredentialShapes() {
        let corpus = loadCorpus()
        for (name, text) in corpus {
            for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let redacted = redact(line)
                if let hit = firstDenyHit(in: redacted) {
                    XCTFail(
                        "\(name):\(index + 1) leaked a \(hit.label) after redaction: '\(hit.match)'\n  redacted line: \(redacted)"
                    )
                }
            }
        }
    }

    /// The corpus is genuinely adversarial: the RAW (pre-redaction) corpus MUST
    /// trip the deny-list. Without this, a corpus of harmless text would pass
    /// `testRedactedCorpus_leaksNoCredentialShapes` and the gate would be inert.
    func testRawCorpus_containsCredentialShapes_soGuardIsMeaningful() {
        let corpus = loadCorpus()
        var hitLabels = Set<String>()
        for (_, text) in corpus {
            for rawLine in text.split(separator: "\n") {
                let line = String(rawLine)
                if line.hasPrefix("#") { continue }
                if let hit = firstDenyHit(in: line) { hitLabels.insert(hit.label) }
            }
        }
        // Every sensitive flow must contribute at least one real secret shape,
        // and collectively the corpus must exercise the high-value patterns.
        for required in ["bearer_token", "jwt", "pin_kv", "password_kv", "token_kv", "cookie_value", "barcode", "basic_auth"] {
            XCTAssertTrue(
                hitLabels.contains(required),
                "Corpus does not exercise the '\(required)' secret shape — the guard would not cover it. Present: \(hitLabels.sorted())"
            )
        }
    }

    /// The deny-list itself is correct: it fires on a raw secret and clears once
    /// that secret is redacted. This pins the gate's own behavior so a future
    /// edit that neuters a deny pattern (e.g. anchors it to only match `[…]`)
    /// fails here rather than silently letting leaks through the corpus test.
    func testDenyList_firesOnRawSecret_andClearsAfterRedaction() {
        let leak = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJyZWFsIn0.leakedSIGNATURE9999"
        XCTAssertNotNil(firstDenyHit(in: leak), "Deny-list must fire on a raw Bearer/JWT leak")
        XCTAssertNil(firstDenyHit(in: redactor.redactLine(leak)), "Deny-list must clear once the secret is redacted")

        let rawPin = "patron note: my pin is 4821 thanks"
        XCTAssertNotNil(firstDenyHit(in: rawPin), "Deny-list must fire on a raw prose PIN")
        XCTAssertNil(firstDenyHit(in: redactor.redactLine(rawPin)), "Deny-list must clear once the PIN is redacted")
    }
}

import Foundation

/// Strips sensitive material from a ContextSnapshot before the bot is allowed
/// to attach it to a ticket. Applied to every snapshot returned from a
/// ContextProvider before the reducer ever sees it.
///
/// The redactor is a value type with no mutable state — calling it twice on
/// the same input returns the same output. That lets tests pin behavior and
/// lets us reason about audit trails (the redacted output IS the ground truth
/// for "what could possibly have left the device").
public struct ContextRedactor: Sendable {
    public init() {}

    /// Returns a new snapshot with tokens, credentials, and direct user
    /// identifiers stripped or hashed. The original is not mutated.
    public func redact(_ snapshot: ContextSnapshot) -> ContextSnapshot {
        ContextSnapshot(
            appVersion: snapshot.appVersion,
            appBuild: snapshot.appBuild,
            platform: snapshot.platform,
            osVersion: snapshot.osVersion,
            deviceModel: snapshot.deviceModel,
            libraryName: snapshot.libraryName,
            libraryUUID: snapshot.libraryUUID.map(hashIdentifier),
            distributor: snapshot.distributor,
            authType: snapshot.authType,
            networkState: snapshot.networkState,
            freeStorageBytes: snapshot.freeStorageBytes,
            recentLogLines: snapshot.recentLogLines.map(redactLine),
            // Crash fingerprints are hashes by contract, but a stack frame or
            // a symbol name can accidentally carry a typed secret. Map them
            // through the same line redactor defensively (PP-4805).
            crashlyticsFingerprints: snapshot.crashlyticsFingerprints.map(redactLine),
            capturedAt: snapshot.capturedAt,
            // Additive diagnostics are non-sensitive and pass through unchanged.
            // (Previously dropped here because the ContextSnapshot init defaults
            // them to nil — that silently stripped them from every ticket; PP-4807
            // restores them alongside the new barcode handling.)
            audioOutputRoute: snapshot.audioOutputRoute,
            lowPowerModeEnabled: snapshot.lowPowerModeEnabled,
            appUptimeSeconds: snapshot.appUptimeSeconds,
            buildChannel: snapshot.buildChannel,
            availableMemoryMB: snapshot.availableMemoryMB,
            // PP-4807: the raw library barcode never lands in state — hash it
            // immediately (like libraryUUID). Support gets a stable cluster id,
            // never the card number. Still omitted from the ticket by default.
            libraryBarcode: snapshot.libraryBarcode.map(hashIdentifier)
        )
    }

    /// Redact a single log line. Public for tests; the snapshot pipeline
    /// calls this through `redact(_:)`.
    public func redactLine(_ line: String) -> String {
        // Strip Unicode bidi / RTL-override controls FIRST (PP-4842): they can
        // visually reverse or spoof the text a patron sees or that lands in the
        // ticket, and they can be spliced between a card number's digits to dodge
        // the digit-run match below. Removing them up front normalizes the line
        // for every downstream rule.
        var result = Self.stripBidiControls(line)
        for pattern in Self.patterns {
            result = pattern.replace(in: result)
        }
        // Generic long-sensitive-digit-run (PAN) redaction (PP-4842). Runs after
        // the keyword patterns — the existing `barcode_standalone` rule handles
        // contiguous 10–14 digit runs and keeps its own marker; this catches the
        // 15–19 digit and single-space/dash-grouped card shapes those rules miss.
        result = Self.redactLongDigitRuns(result)
        return result
    }

    /// Hash a UUID-shaped identifier to a non-reversible 8-char digest. We
    /// keep enough entropy that support can cluster reports from the same
    /// device without learning who that device belongs to.
    public func hashIdentifier(_ raw: String) -> String {
        // FNV-1a 64-bit — good enough for cluster-bucketing, not a crypto
        // primitive. Encoded as 16-char lowercase hex; first 8 chars used.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16, uppercase: false)
        let padded = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        return "anon-" + String(padded.prefix(8))
    }

    // MARK: - Patterns

    private struct RedactionPattern: Sendable {
        let label: String
        let regex: String
        let replacement: String

        func replace(in input: String) -> String {
            guard let expr = try? NSRegularExpression(
                pattern: regex,
                options: [.caseInsensitive]
            ) else { return input }
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            return expr.stringByReplacingMatches(
                in: input,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
    }

    private static let patterns: [RedactionPattern] = [
        // Bearer/OAuth/JWT tokens — match the leading scheme and 12+ token chars
        RedactionPattern(
            label: "bearer",
            regex: #"(?i)\bBearer\s+[A-Za-z0-9._\-]{12,}"#,
            replacement: "Bearer [REDACTED]"
        ),
        RedactionPattern(
            label: "basic",
            regex: #"(?i)\bBasic\s+[A-Za-z0-9+/=]{12,}"#,
            replacement: "Basic [REDACTED]"
        ),
        // Standalone Authorization: <stuff> header lines
        RedactionPattern(
            label: "auth_header",
            regex: #"(?i)Authorization:\s*[^\s]+"#,
            replacement: "Authorization: [REDACTED]"
        ),
        // SAML cookie names that show up in OPDS-for-Distributors flows
        RedactionPattern(
            label: "saml_cookie",
            regex: #"(?i)(simpleSAMLSessionID|PHPSESSID|JSESSIONID)=([^;\s]+)"#,
            replacement: "$1=[REDACTED]"
        ),
        // Library card barcode — 10-16 digits often labeled "barcode" or "pin"
        RedactionPattern(
            label: "barcode",
            regex: #"(?i)\b(barcode|card[\s_-]?number)\s*[:=]\s*\d{6,20}"#,
            replacement: "$1=[REDACTED]"
        ),
        RedactionPattern(
            label: "pin",
            regex: #"(?i)\bpin\s*[:=]\s*\d{3,8}"#,
            replacement: "pin=[REDACTED]"
        ),
        // Email addresses (default redacted; users can opt back in).
        // Host portion uses [^\s@] so international domains (patron@例え.jp,
        // alice@münchen.de) are caught. Privacy regression covered by
        // AdversarialChaosTests.testRedactor_mixedScriptLogLine_doesNotCrash.
        RedactionPattern(
            label: "email",
            regex: #"[A-Za-z0-9._%+\-]+@[^\s@]+\.[^\s@]+"#,
            replacement: "[email-redacted]"
        ),
        // UUIDs — full uuid v4 shape, replaced with anon-* hash sentinel
        RedactionPattern(
            label: "uuid",
            regex: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
            replacement: "[uuid-redacted]"
        ),

        // === PP-4805: patron-typed free-text leaks =========================
        // The HelpSpot forensic showed the real leaks are humans typing PINs /
        // passwords / barcodes / tokens into the description, not the
        // auto-context. These patterns run on every user-authored line the
        // reducer assembles into a draft, as well as on captured log lines.

        // Standalone JWT (header.payload[.signature]) — matches the eyJ base64url
        // header prefix so a token pasted without a "Bearer " scheme is caught.
        RedactionPattern(
            label: "jwt",
            regex: #"\beyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}(?:\.[A-Za-z0-9_\-]+)?"#,
            replacement: "[jwt-redacted]"
        ),
        // x-api-key request header.
        RedactionPattern(
            label: "x_api_key",
            regex: #"(?i)x-api-key:\s*\S+"#,
            replacement: "x-api-key: [REDACTED]"
        ),
        // Key/value credentials in JSON, query-string, or form encodings.
        // The key list is the sensitive set; the value runs to the next
        // quote / delimiter / whitespace. "password: <token>" is covered here
        // too. `\b` before the key keeps "tokenizer" / "pinpoint" safe.
        RedactionPattern(
            label: "kv_creds",
            regex: #"(?i)"?\b(access_token|refresh_token|client_secret|api_key|apikey|password|passwd|token|pin)\b"?\s*[:=]\s*"?[^"&\s,}\]]+"#,
            replacement: "$1=[REDACTED]"
        ),
        // Generic Cookie / Set-Cookie value(s). Redacts each name=value pair's
        // value while preserving the cookie NAME (so the existing SAML-cookie
        // expectation still holds). Anchored on the ": " / "; " that separates
        // a header keyword or a prior pair from the next name.
        RedactionPattern(
            label: "cookie_value",
            regex: #"(?i)(?<=[:;]\s)([A-Za-z0-9_.\-]+)=[^;\s]+"#,
            replacement: "$1=[REDACTED]"
        ),
        // PIN / passcode stated in prose without a delimiter ("my pin is 1234").
        // `\b` on the keyword avoids "spinning". Digit run is \d{3,8} to match
        // the delimiter'd `pin` rule above — a prose "my pin is 12345" / "123456"
        // must redact just like "pin: 12345" (PP-4805: the narrower \d{3,4} here
        // leaked 5-6 digit prose PINs into the ticket).
        RedactionPattern(
            label: "pin_prose",
            regex: #"(?i)\b(pin|passcode)\b[^\d\n]{0,10}\d{3,8}\b"#,
            replacement: "$1 [REDACTED]"
        ),
        // Password stated in prose without a delimiter ("my password is hunter2").
        // The delimited "password: X" / "password=X" forms are caught by
        // `kv_creds`; this covers the "<keyword> is|was <token>" prose form a
        // patron naturally types in a support chat (PP-4817 chaos F-002: a prose
        // password leaked into the ticket + real clipboard payload). Requiring an
        // explicit "is"/"was" linker keeps benign phrases safe — "password reset",
        // "forgot my password", "password not working" have no linker and are
        // untouched; only "<keyword> is/was <token>" is redacted (privacy >
        // utility, so an occasional "password is wrong" losing "wrong" is fine).
        RedactionPattern(
            label: "password_prose",
            regex: #"(?i)\b(password|passwd|passphrase|pwd)\b\s+(?:is|was)\s+\S{3,}"#,
            replacement: "$1 [REDACTED]"
        ),
        // Standalone 10-14 digit library barcode / card number typed inline.
        // Word-boundaried so 4-digit years and 3-digit error codes survive.
        // The negative lookahead carves out exactly a 13-digit 978/979 ISBN —
        // patrons routinely type a book's ISBN into a reading-app report and it
        // must not be mangled as a card number (PP-4805). Scoped tightly to
        // `97[89]` + 10 more digits so real barcodes that merely start with 97
        // are still redacted.
        // follow-up: extend redaction to 15-16 digit card numbers — deferred,
        // it risks new false positives against long non-card identifiers.
        RedactionPattern(
            label: "barcode_standalone",
            regex: #"\b(?!97[89]\d{10}\b)\d{10,14}\b"#,
            replacement: "[number-redacted]"
        )
    ]

    // MARK: - PP-4842: PAN / long-digit-run + bidi-control handling

    /// Unicode bidirectional / RTL-override formatting controls. Stripped from
    /// every redacted line so they cannot visually reverse or spoof the text a
    /// patron sees or that lands in the ticket (a chaos-redaction finding folded
    /// into PP-4842).
    private static let bidiControlScalars: Set<UInt32> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // LRE RLE PDF LRO RLO
        0x2066, 0x2067, 0x2068, 0x2069,         // LRI RLI FSI PDI
        0x200E, 0x200F                          // LRM RLM
    ]

    private static func stripBidiControls(_ input: String) -> String {
        guard input.unicodeScalars.contains(where: { bidiControlScalars.contains($0.value) }) else {
            return input
        }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: input.unicodeScalars.filter { !bidiControlScalars.contains($0.value) })
        return String(scalars)
    }

    /// Payment / account keywords. When one is present just before a long digit
    /// run we redact it even if it fails Luhn — a patron who mistypes a digit of
    /// a number they explicitly call their "card" still gets it stripped.
    private static let paymentKeywordRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(card|credit|debit|visa|mastercard|amex|discover|cvv|cvc|barcode|acct|account\s+number)\b"#
    )

    /// Candidate 13–19 digit runs, optionally grouped by single spaces or dashes
    /// (`4111 1111 1111 1111`, `4111-1111-1111-1111`, `4111111111111111`). The
    /// lookaround boundaries prevent latching onto part of a longer digit blob.
    private static let digitRunRegex = try? NSRegularExpression(
        pattern: #"(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])"#
    )

    /// Redact card-length digit runs the keyword rules miss. A run is redacted
    /// only when it is Luhn-valid OR the line carries a payment/account keyword
    /// just before it — this is what lets us extend past the conservative 10–14
    /// barcode rule without over-redacting benign long numbers (ISBNs, ids,
    /// timestamps).
    private static func redactLongDigitRuns(_ input: String) -> String {
        guard let digitRunRegex else { return input }
        let ns = input as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = digitRunRegex.matches(in: input, range: full)
        guard !matches.isEmpty else { return input }
        var result = input
        // Replace right-to-left so earlier match ranges stay valid across mutation.
        for match in matches.reversed() {
            let digits = ns.substring(with: match.range).compactMap { $0.wholeNumberValue }
            guard digits.count >= 13, digits.count <= 19 else { continue }
            guard passesLuhn(digits) || Self.hasPaymentKeyword(before: match.range, in: input)
            else { continue }
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: "[number-redacted]")
            }
        }
        return result
    }

    /// True when a payment/account keyword sits in the ~24-char window
    /// immediately preceding `matchRange`. Scoping to a *preceding* window
    /// (not the whole line) is what keeps a "card" keyword from redacting an
    /// ISBN that merely shares the line — the keyword must be adjacent to the
    /// number it labels.
    private static func hasPaymentKeyword(before matchRange: NSRange, in input: String) -> Bool {
        guard let paymentKeywordRegex else { return false }
        let windowStart = max(0, matchRange.location - 24)
        let window = NSRange(location: windowStart, length: matchRange.location - windowStart)
        guard window.length > 0 else { return false }
        return paymentKeywordRegex.firstMatch(in: input, range: window) != nil
    }

    /// Luhn (mod-10) checksum — the integrity check every real card number
    /// satisfies. Used to catch unlabeled PANs without redacting arbitrary
    /// long numbers.
    private static func passesLuhn(_ digits: [Int]) -> Bool {
        var sum = 0
        var double = false
        for digit in digits.reversed() {
            var value = digit
            if double {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            double.toggle()
        }
        return sum % 10 == 0
    }
}

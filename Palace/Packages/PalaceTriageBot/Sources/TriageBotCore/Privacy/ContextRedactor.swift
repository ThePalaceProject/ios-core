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
        var result = line
        for pattern in Self.patterns {
            result = pattern.replace(in: result)
        }
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
        // `\b` on the keyword avoids "spinning"; the 3-4 digit run avoids
        // longer identifiers.
        RedactionPattern(
            label: "pin_prose",
            regex: #"(?i)\b(pin|passcode)\b[^\d\n]{0,10}\d{3,4}\b"#,
            replacement: "$1 [REDACTED]"
        ),
        // Standalone 10-14 digit library barcode / card number typed inline.
        // Word-boundaried so 4-digit years and 3-digit error codes survive.
        RedactionPattern(
            label: "barcode_standalone",
            regex: #"\b\d{10,14}\b"#,
            replacement: "[number-redacted]"
        )
    ]
}

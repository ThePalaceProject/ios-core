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
            crashlyticsFingerprints: snapshot.crashlyticsFingerprints,
            capturedAt: snapshot.capturedAt
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
        )
    ]
}

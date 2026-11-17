import Foundation

/// Pure functions that turn a TicketDraft into an email-ready
/// subject / body / attachment set. Lives in TriageBotCore (not TriageBotIOS)
/// so it can be unit-tested without UIKit or MessageUI, and so a non-email
/// gateway (server-side, Android, etc.) can reuse the same payload shape.
///
/// Every human-readable string names the platform by reading `context.platform`
/// rather than a compile-time literal. Four strings here used to hardcode iOS,
/// which meant a reuse of this composition would have stamped "Palace iOS
/// support" on an Android report while the only accurate answer sat unread in
/// `palace-diagnostics.json`.
public enum TicketEmailComposition {

    public struct Attachment: Equatable, Sendable {
        public let fileName: String
        public let mimeType: String
        public let data: Data

        public init(fileName: String, mimeType: String, data: Data) {
            self.fileName = fileName
            self.mimeType = mimeType
            self.data = data
        }
    }

    /// Subject line. Categorizes the issue so support's inbox sorts cleanly.
    public static func subject(for draft: TicketDraft) -> String {
        "Palace \(draft.context.platform) support: \(draft.category.rawValue) issue"
    }

    /// Email body. Short by design — the full payload is in the JSON
    /// attachment. Keeps the support inbox readable.
    public static func body(for rawDraft: TicketDraft) -> String {
        // PP-4807: honor the patron's omit choices at the source so an omitted
        // field never reaches the wire, not just the UI.
        let draft = rawDraft.sanitizedForSubmission()
        var lines: [String] = []
        lines.append("Hi Palace support,")
        lines.append("")
        lines.append("I hit this in the Palace app and the in-app triage bot didn't have a fix for me. Sending the details so you can take a look.")
        lines.append("")
        lines.append("What I said:")
        lines.append(indent(draft.userDescription, by: "  "))
        lines.append("")
        if let matched = draft.matchedEntryId {
            lines.append("The bot's guess: \(matched)")
            lines.append("(I asked to file a ticket anyway — the suggested workaround didn't fix it for me.)")
            lines.append("")
        }
        lines.append("Category: \(draft.category.rawValue)")
        lines.append("Priority: \(draft.priority.rawValue)")
        lines.append("")
        if let trace = draft.resolutionTrace {
            lines.append("Guided troubleshooting trace:")
            lines.append("  Entry: \(trace.entryId)")
            lines.append("  Outcome: \(trace.outcome.rawValue)")
            lines.append("  Steps attempted (in order):")
            for (i, attempt) in trace.attempts.enumerated() {
                lines.append("    \(i + 1). \(attempt.stepId) → \(attempt.outcome.rawValue)")
            }
            lines.append("")
        }
        if let followUp = draft.escalationFollowUp {
            lines.append("Follow-up question asked before filing:")
            lines.append("  Q: \(followUp.prompt)")
            if let answer = followUp.answer, !answer.isEmpty {
                lines.append("  A: \(answer)")
            } else {
                lines.append("  A: (user skipped)")
            }
            lines.append("")
        }
        lines.append("Environment:")
        let ctx = draft.context
        lines.append("  App: \(ctx.appVersion) (\(ctx.appBuild))")
        lines.append("  Build channel: \(ctx.buildChannel ?? "unknown")")
        lines.append("  Device: \(ctx.deviceModel)")
        lines.append("  \(ctx.platform): \(ctx.osVersion)")
        if let library = ctx.libraryName { lines.append("  Library: \(library)") }
        if let barcode = ctx.libraryBarcode { lines.append("  Library card (hashed): \(barcode)") }
        if let dist = ctx.distributor { lines.append("  Distributor: \(dist)") }
        if let auth = ctx.authType { lines.append("  Auth: \(auth)") }
        if let net = ctx.networkState { lines.append("  Network: \(net)") }
        if let route = ctx.audioOutputRoute { lines.append("  Audio route: \(route)") }
        if let lowPower = ctx.lowPowerModeEnabled { lines.append("  Low Power Mode: \(lowPower ? "ON" : "off")") }
        if let mem = ctx.availableMemoryMB { lines.append("  Available memory: \(mem) MB") }
        if let free = ctx.freeStorageBytes { lines.append("  Free storage: \(humanBytes(free))") }
        if let up = ctx.appUptimeSeconds { lines.append("  App uptime: \(humanDuration(up))") }
        lines.append("")
        if !ctx.recentLogLines.isEmpty {
            lines.append("Recent log entries (last few minutes, sensitive material already stripped): see palace-logs.txt attached — \(ctx.recentLogLines.count) lines.")
        }
        if !ctx.crashlyticsFingerprints.isEmpty {
            lines.append("Crash fingerprints from this session: \(ctx.crashlyticsFingerprints.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("Full diagnostics: see palace-diagnostics.json attached.")
        lines.append("")
        lines.append("Thanks,")
        lines.append("(Sent from the Palace \(draft.context.platform) in-app triage bot)")
        return lines.joined(separator: "\n")
    }

    /// Builds the attachments shipped with the email. JSON carries the full
    /// payload for automation; text file carries the log tail in a form
    /// support can scan without un-zipping.
    public static func attachments(for rawDraft: TicketDraft) -> [Attachment] {
        // PP-4807: encode the sanitized draft so omitted fields are ABSENT from
        // the JSON attachment (nil optionals are dropped by encodeIfPresent).
        // PP-4883: serialize via the shared TicketWirePayload so the email
        // attachment and the clipboard copy path produce byte-identical bytes.
        // Pass the RAW draft to jsonData and let TicketWirePayload be the sole
        // sanitize owner for the JSON — `draft` below is only for the log file.
        let draft = rawDraft.sanitizedForSubmission()
        var result: [Attachment] = []

        if let json = try? TicketWirePayload.jsonData(for: rawDraft) {
            result.append(Attachment(
                fileName: "palace-diagnostics.json",
                mimeType: "application/json",
                data: json
            ))
        }

        if !draft.context.recentLogLines.isEmpty {
            let isoFormatter = ISO8601DateFormatter()
            let header = """
            Palace \(draft.context.platform) — recent log tail
            Captured: \(isoFormatter.string(from: draft.context.capturedAt))
            App: \(draft.context.appVersion) (\(draft.context.appBuild))
            Device: \(draft.context.deviceModel) / \(draft.context.platform) \(draft.context.osVersion)
            Note: tokens, credentials, emails, and account UUIDs are redacted.

            """
            let body = draft.context.recentLogLines.joined(separator: "\n")
            if let data = (header + body).data(using: .utf8) {
                result.append(Attachment(
                    fileName: "palace-logs.txt",
                    mimeType: "text/plain",
                    data: data
                ))
            }
        }

        return result
    }

    // MARK: - Helpers

    private static func indent(_ text: String, by prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + String($0) }
            .joined(separator: "\n")
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return "\(bytes) bytes"
    }

    private static func humanDuration(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remM = minutes % 60
        return remM == 0 ? "\(hours)h" : "\(hours)h \(remM)m"
    }
}

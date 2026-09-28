import XCTest
@testable import TriageBotCore

/// Tests for the email body / attachment composition. Pure functions —
/// no MFMailComposeViewController needed, no UIKit. The actual mail-composer
/// presentation lives in TriageBotIOS and is exercised by simdrive on a
/// real simulator with a configured Mail account.
final class TicketEmailCompositionTests: XCTestCase {

    private func makeContext(
        platform: String = "iOS",
        recentLogs: [String] = [],
        audio: String? = nil,
        lowPower: Bool? = nil,
        uptime: Int64? = nil,
        channel: String? = nil,
        memMB: Int64? = nil
    ) -> ContextSnapshot {
        ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            platform: platform,
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            libraryName: "Sample Library",
            libraryUUID: "anon-deadbeef",
            distributor: "palace_marketplace",
            authType: "basic",
            networkState: "wifi",
            freeStorageBytes: 8_500_000_000,
            recentLogLines: recentLogs,
            crashlyticsFingerprints: ["0x8a3f2b1c4"],
            capturedAt: Date(timeIntervalSince1970: 1_716_900_000),
            audioOutputRoute: audio,
            lowPowerModeEnabled: lowPower,
            appUptimeSeconds: uptime,
            buildChannel: channel,
            availableMemoryMB: memMB
        )
    }

    private func makeDraft(
        platform: String = "iOS",
        matched: String? = nil,
        priority: TicketDraft.Priority = .normal,
        recentLogs: [String] = [],
        diagnostics: (audio: String?, lowPower: Bool?, uptime: Int64?, channel: String?, memMB: Int64?) = (nil, nil, nil, nil, nil)
    ) -> TicketDraft {
        TicketDraft(
            userDescription: "my audiobook just sits there spinning",
            category: .audiobook,
            matchedEntryId: matched,
            context: makeContext(
                platform: platform,
                recentLogs: recentLogs,
                audio: diagnostics.audio,
                lowPower: diagnostics.lowPower,
                uptime: diagnostics.uptime,
                channel: diagnostics.channel,
                memMB: diagnostics.memMB
            ),
            helpspotTags: ["triage-bot-escalate-novel"],
            priority: priority
        )
    }

    // MARK: - Platform naming

    /// Every human-readable string in a ticket must name the platform the
    /// report came FROM, read from `context.platform`, not a compile-time
    /// literal.
    ///
    /// `TicketEmailComposition` lives in TriageBotCore, and its own header
    /// offers it for reuse by a non-email gateway "(server-side, Android,
    /// etc.)". It previously hardcoded "iOS" in the subject, the environment
    /// line, the signature, and the log-file header, and never printed
    /// `context.platform` in the body at all — so the field reached support
    /// only inside `palace-diagnostics.json` while every label a triager reads
    /// said iOS unconditionally. A port reusing this composition would have
    /// stamped "Palace iOS support" on Android tickets.
    func testSubject_namesThePlatformFromContext() {
        let subject = TicketEmailComposition.subject(for: makeDraft(platform: "Android"))
        XCTAssertTrue(subject.contains("Palace Android support"), "subject was: \(subject)")
        XCTAssertFalse(subject.contains("iOS"), "subject still names iOS for an Android report: \(subject)")
    }

    func testBody_environmentLineAndSignature_nameThePlatformFromContext() {
        let body = TicketEmailComposition.body(for: makeDraft(platform: "Android"))
        XCTAssertTrue(body.contains("Android: 26.4.2"), "environment line missing the platform-labelled OS version")
        XCTAssertTrue(body.contains("Palace Android in-app triage bot"), "signature does not name the reporting platform")
        XCTAssertFalse(body.contains("iOS"), "body still names iOS somewhere for an Android report")
    }

    func testAttachments_logHeader_namesThePlatformFromContext() throws {
        let attachments = TicketEmailComposition.attachments(
            for: makeDraft(platform: "Android", recentLogs: ["line one", "line two"])
        )
        let logs = try XCTUnwrap(attachments.first { $0.fileName == "palace-logs.txt" })
        let text = try XCTUnwrap(String(data: logs.data, encoding: .utf8))
        XCTAssertTrue(text.contains("Palace Android — recent log tail"), "log header does not name the reporting platform")
        XCTAssertFalse(text.contains("iOS"), "log header still names iOS for an Android report")
    }

    /// The iOS output must be byte-for-byte what it always was — reading the
    /// field is only correct if it produces the identical result for the
    /// platform that was previously hardcoded.
    func testIOSOutput_isUnchangedByReadingTheField() throws {
        let draft = makeDraft()
        XCTAssertTrue(TicketEmailComposition.subject(for: draft).contains("Palace iOS support"))
        let body = TicketEmailComposition.body(for: makeDraft(recentLogs: ["l"]))
        XCTAssertTrue(body.contains("iOS: 26.4.2"))
        XCTAssertTrue(body.contains("(Sent from the Palace iOS in-app triage bot)"))
        let attachments = TicketEmailComposition.attachments(for: makeDraft(recentLogs: ["l"]))
        let logs = try XCTUnwrap(attachments.first { $0.fileName == "palace-logs.txt" })
        let text = try XCTUnwrap(String(data: logs.data, encoding: .utf8))
        XCTAssertTrue(text.contains("Palace iOS — recent log tail"))
        XCTAssertTrue(text.contains("/ iOS 26.4.2"))
    }

    // MARK: - Subject

    func testSubject_includesCategory() {
        let subject = TicketEmailComposition.subject(for: makeDraft())
        XCTAssertTrue(subject.contains("Palace iOS support"))
        XCTAssertTrue(subject.contains("audiobook"))
    }

    // MARK: - Body content

    func testBody_includesUserDescriptionAndEnvironment() {
        let body = TicketEmailComposition.body(for: makeDraft())

        XCTAssertTrue(body.contains("my audiobook just sits there spinning"), "User description must appear verbatim in body")
        XCTAssertTrue(body.contains("App: 3.0.3 (478)"))
        XCTAssertTrue(body.contains("Device: iPhone17,2"))
        XCTAssertTrue(body.contains("iOS: 26.4.2"))
        XCTAssertTrue(body.contains("Library: Sample Library"))
        XCTAssertTrue(body.contains("Distributor: palace_marketplace"))
        XCTAssertTrue(body.contains("Auth: basic"))
        XCTAssertTrue(body.contains("Network: wifi"))
        XCTAssertTrue(body.contains("Free storage: 7.9 GB"))
        XCTAssertTrue(body.contains("Crash fingerprints"), "Crashlytics fingerprints should surface in body")
    }

    func testBody_includesMatchedEntry_whenUserFiledAnyway() {
        let body = TicketEmailComposition.body(for: makeDraft(matched: "KI-2026-001-audiobook-first-open-hang"))
        XCTAssertTrue(body.contains("The bot's guess: KI-2026-001-audiobook-first-open-hang"))
        XCTAssertTrue(body.contains("workaround didn't fix it"), "When matched, body must explain why user is escalating anyway")
    }

    func testBody_omitsMatchedEntrySection_whenUnmatched() {
        let body = TicketEmailComposition.body(for: makeDraft(matched: nil))
        XCTAssertFalse(body.contains("The bot's guess"), "No matched entry → no 'bot's guess' section")
    }

    func testBody_includesExpandedDiagnostics_whenPresent() {
        let body = TicketEmailComposition.body(for: makeDraft(
            diagnostics: (audio: "CarPlay", lowPower: true, uptime: 4815, channel: "testflight", memMB: 1024)
        ))
        XCTAssertTrue(body.contains("Audio route: CarPlay"))
        XCTAssertTrue(body.contains("Low Power Mode: ON"))
        XCTAssertTrue(body.contains("App uptime: 1h 20m"))
        XCTAssertTrue(body.contains("Build channel: testflight"))
        XCTAssertTrue(body.contains("Available memory: 1024 MB"))
    }

    func testBody_omitsOptionalFields_whenAbsent() {
        let body = TicketEmailComposition.body(for: makeDraft())
        XCTAssertFalse(body.contains("Audio route:"))
        XCTAssertFalse(body.contains("Low Power Mode:"))
        XCTAssertFalse(body.contains("App uptime:"))
        XCTAssertFalse(body.contains("Available memory:"))
    }

    func testBody_referencesLogAttachment_whenLogsPresent() {
        let body = TicketEmailComposition.body(for: makeDraft(recentLogs: ["line 1", "line 2", "line 3"]))
        XCTAssertTrue(body.contains("palace-logs.txt"))
        XCTAssertTrue(body.contains("3 lines"))
    }

    func testBody_alwaysReferencesDiagnosticsAttachment() {
        let body = TicketEmailComposition.body(for: makeDraft())
        XCTAssertTrue(body.contains("palace-diagnostics.json"))
    }

    // MARK: - Attachments

    func testAttachments_alwaysIncludesDiagnosticsJSON() {
        let attachments = TicketEmailComposition.attachments(for: makeDraft())
        XCTAssertTrue(attachments.contains { $0.fileName == "palace-diagnostics.json" && $0.mimeType == "application/json" })
    }

    func testAttachments_includesLogsTxt_onlyWhenLogsPresent() {
        let withLogs = TicketEmailComposition.attachments(for: makeDraft(recentLogs: ["[I] launched"]))
        let withoutLogs = TicketEmailComposition.attachments(for: makeDraft(recentLogs: []))
        XCTAssertTrue(withLogs.contains { $0.fileName == "palace-logs.txt" })
        XCTAssertFalse(withoutLogs.contains { $0.fileName == "palace-logs.txt" })
    }

    func testAttachments_diagnosticsJSON_isParseableAndContainsContext() throws {
        let draft = makeDraft(matched: "KI-X", recentLogs: ["[I] hello"])
        let attachments = TicketEmailComposition.attachments(for: draft)
        let json = try XCTUnwrap(attachments.first { $0.fileName == "palace-diagnostics.json" }?.data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TicketDraft.self, from: json)
        XCTAssertEqual(decoded.userDescription, draft.userDescription)
        XCTAssertEqual(decoded.matchedEntryId, "KI-X")
        XCTAssertEqual(decoded.context.appVersion, "3.0.3")
        XCTAssertEqual(decoded.context.recentLogLines, ["[I] hello"])
    }

    func testAttachments_logsFile_carriesRedactionNote() throws {
        let attachments = TicketEmailComposition.attachments(for: makeDraft(recentLogs: ["[I] sample"]))
        let logs = try XCTUnwrap(attachments.first { $0.fileName == "palace-logs.txt" }?.data)
        let text = try XCTUnwrap(String(data: logs, encoding: .utf8))
        XCTAssertTrue(text.contains("Palace iOS — recent log tail"))
        XCTAssertTrue(text.contains("redacted"), "Log file must carry the redaction note so support knows tokens are stripped")
        XCTAssertTrue(text.contains("[I] sample"), "Log content must be included verbatim")
    }

    // MARK: - Privacy regression — no tokens / emails in body or attachments

    func testBody_doesNotLeakRedactedSecrets_evenIfPresentInLogs() {
        // The redactor runs upstream — by the time we get to email composition
        // the log lines should already be redacted. This test pins that
        // contract: if a token somehow slips through to here, that should be
        // a regression we notice in code review, not silently emailed.
        let logs = ["Authorization: Bearer LEAKED_TOKEN_VALUE_123"]
        let body = TicketEmailComposition.body(for: makeDraft(recentLogs: logs))
        // Body references the log file but doesn't inline the log content
        XCTAssertFalse(body.contains("LEAKED_TOKEN_VALUE_123"), "Email body must never inline raw log content")
    }
}

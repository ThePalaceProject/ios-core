//
//  A value we do not own, for proving that code reporting to Crashlytics does not
//  forward foreign payloads (e.g. MDM managed configuration). A word-list
//  assertion ("password", "token") passes vacuously when fixtures hold only our
//  own keys; injecting this canary makes the check about provenance instead.
//  Usage: `ForeignPayloadCanary.inject(into: &payload)`, drive the reporting code,
//  then `ForeignPayloadCanary.assertAbsent(from: reportedText)`.
//

import XCTest

/// A key and value that Palace does not own, for injecting into payloads that
/// arrive from outside the app.
enum ForeignPayloadCanary {

    /// A key no Palace code reads. Deliberately unlike our own key names, so a
    /// detector or a reader can tell at a glance that nothing should match it.
    static let key = "x-unowned-canary-key"

    /// The value to look for on the far side. Distinctive enough that finding
    /// it in a report is unambiguous, and containing no substring that could
    /// occur by chance in a UUID, a URL, or an error message.
    static let value = "x-unowned-canary-7f3a"

    /// Adds the canary to a payload that is about to be handed to code under
    /// test, standing in for whatever the sending organisation put there that
    /// we neither read nor recognise.
    static func inject(into payload: inout [String: Any]) {
        payload[key] = value
    }

    /// A copy of `payload` with the canary added.
    static func injected(into payload: [String: Any]) -> [String: Any] {
        var copy = payload
        inject(into: &copy)
        return copy
    }

    /// Fails if anything we do not own reached `text`.
    ///
    /// Checks the key as well as the value: a report that names the foreign
    /// key without its value has still disclosed what the sender configured.
    static func assertAbsent(
        from text: String,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for token in [value, key] {
            XCTAssertFalse(
                text.contains(token),
                "'\(token)' is not ours and reached an external sink. \(message())\nreported: \(text)",
                file: file, line: line
            )
        }
    }

    /// Fails if the text under inspection is empty, then checks provenance.
    ///
    /// The emptiness check is the difference between "nothing leaked" and
    /// "nothing happened". A redaction test that passes because the code under
    /// test reported nothing at all is the same vacuum in a different disguise,
    /// so a caller asserting absence must first show something was produced.
    static func assertReportedAndAbsent(
        from text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "nothing was reported, so this proves nothing about what a report carries",
            file: file, line: line
        )
        assertAbsent(from: text, file: file, line: line)
    }
}

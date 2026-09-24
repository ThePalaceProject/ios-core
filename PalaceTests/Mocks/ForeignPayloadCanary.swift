//
//  ForeignPayloadCanary.swift
//  PalaceTests
//
//  A value we do not own, for proving that code which reports to an external
//  sink does not report things that are not ours.
//
//  ## The failure this exists to make impossible
//
//  Palace reports diagnostics to Crashlytics. Some of the data it reasons about
//  arrives from outside — an MDM's managed-configuration dictionary is the first
//  example, and it will not be the last. Those payloads belong to the
//  organisation that sent them. They may carry unrelated settings today and
//  sensitive ones tomorrow, and none of it is ours to forward.
//
//  The natural test for this is to assert the report does not contain anything
//  sensitive, and the natural way to write that assertion is a list of words:
//  "password", "token", "barcode". Such a test was written for exactly this
//  code, it passed, and the code was forwarding the entire foreign payload
//  anyway. It passed because every fixture in the suite contained only keys we
//  own, so no forbidden word was ever in the input to begin with. The assertion
//  was true and vacuous at the same time.
//
//  Two lessons in that, and the canary answers both:
//
//  A list of things you thought of is a list of things you thought of. It can
//  only catch leaks of values you predicted, and a leak you predicted is one
//  you probably already prevented. What you want to assert is a property —
//  "nothing that isn't ours" — and a property needs a witness in the input.
//
//  A guard is only evidence if the input could have tripped it. Put this value
//  into the payload under test and the assertion stops being about vocabulary
//  and starts being about provenance.
//
//  ## Using it
//
//      var payload = someManagedConfiguration
//      ForeignPayloadCanary.inject(into: &payload)
//
//      // ... drive the code that reports ...
//
//      ForeignPayloadCanary.assertAbsent(from: reportedText)
//
//  Copyright © 2026 The Palace Project. All rights reserved.
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

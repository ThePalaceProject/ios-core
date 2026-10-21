//
//  AlertTextLocalizationTests.swift
//  PalaceTests
//
//  Palace ships no `en.lproj/Localizable.strings` — the `Localizable.strings`
//  variant group has only de, es, fr and it children and `developmentRegion`
//  is `en` — so `NSLocalizedString(key)` returns the key verbatim for an
//  English patron. An identifier-shaped key with no `value:` therefore reaches
//  the alert as an identifier in every language. PP-5094 shipped that way.
//

import XCTest
@testable import Palace

@MainActor
final class AlertTextLocalizationTests: XCTestCase {

    // MARK: - Shared predicate

    /// True when a patron would read `text` as an identifier rather than as
    /// English: no whitespace, plus either an internal lower-to-upper
    /// transition (`NotConnected`) or a dotted namespace (`CarPlay.library`).
    ///
    /// A single word is prose. `Cancelled` reads correctly with no table at
    /// all, which is why the house idiom uses the English string as the key.
    /// `nonisolated` so `AlertIdentifierKeyLintTests`, which is not
    /// `@MainActor`, can share this one copy instead of keeping its own. It is
    /// a pure function of its argument.
    nonisolated static func isIdentifierShaped(_ text: String) -> Bool {
        guard text.count >= 3, !text.contains(where: { $0.isWhitespace }) else { return false }
        guard text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }),
              let first = text.first, first.isLetter else { return false }
        if text.contains(".") {
            // A dot counts only where it joins two identifier segments, so
            // `More...` and `Loading...` stay prose.
            let segments = text.split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count >= 2 else { return false }
            return segments.allSatisfy { segment in
                guard let f = segment.first, f.isLetter else { return false }
                return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }
        }
        return zip(text, text.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }

    private func assertPatronReadable(_ text: String?,
                                      equals expected: String,
                                      _ what: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        guard let text, !text.isEmpty else {
            return XCTFail("\(what): no text reached the alert", file: file, line: line)
        }
        XCTAssertFalse(Self.isIdentifierShaped(text),
                       "\(what): a patron reads the identifier \"\(text)\"",
                       file: file, line: line)
        XCTAssertEqual(text, expected, "\(what): copy changed", file: file, line: line)
    }

    // MARK: - The predicate itself
    //
    // Without these the predicate could be vacuous and every assertion above
    // would pass on anything.

    func testIsIdentifierShaped_FlagsTheKeysThatReachPatronsToday() {
        for key in ["SettingsAccountViewControllerLogoutFailed",
                    "NotConnected",
                    "TimedOut",
                    "UnsupportedURL",
                    "UnknownRequestError",
                    "SettingsAccountViewControllerInvalidCredentials",
                    "SettingsAccountViewControllerMessageTooManyActivations",
                    "SettingsAccountViewControllerCannotLogOutTitle",
                    "SettingsAccountViewControllerCannotLogOutMessage",
                    "CarPlay.library"] {
            XCTAssertTrue(Self.isIdentifierShaped(key), "\(key) must read as an identifier")
        }
    }

    func testIsIdentifierShaped_AcceptsProseAndSingleWords() {
        for prose in ["You are not connected to the internet. Please connect and try again.",
                      "Sign Out Failed",
                      "Cancelled",
                      "OK",
                      "More...",
                      "Loading..."] {
            XCTAssertFalse(Self.isIdentifierShaped(prose), "\(prose) must read as prose")
        }
    }

    // MARK: - Foundation contract the fix rests on

    /// `value:` is what makes an identifier key safe without an `en` table:
    /// Foundation returns it when the key is absent. An empty `value:` is
    /// treated as absent and the key comes back instead, which is why the
    /// fallbacks must be non-empty.
    func testMissingKeyWithValueFallbackResolvesToTheValue() {
        let bundle = Bundle(for: TPPAppDelegate.self)
        let absentKey = "PalaceTests.AlertTextLocalization.absentKey"

        XCTAssertEqual(
            bundle.localizedString(forKey: absentKey, value: "Readable prose.", table: nil),
            "Readable prose.")
        XCTAssertEqual(
            bundle.localizedString(forKey: absentKey, value: "", table: nil),
            absentKey,
            "An empty value: leaves the key on screen")
    }

    // MARK: - NSURLError arms of the shared error-alert builder

    func testAlert_NotConnectedToInternet_PresentsProse() {
        let alert = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))

        assertPatronReadable(alert.message,
                             equals: "You are not connected to the internet. Please connect and try again.",
                             "no-connection message")
    }

    func testAlert_TimedOut_PresentsProse() {
        let alert = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))

        assertPatronReadable(alert.message,
                             equals: "The server did not respond. Please check your connection or try again later.",
                             "timeout message")
    }

    func testAlert_UnsupportedURL_PresentsProse() {
        let alert = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL))

        assertPatronReadable(alert.message,
                             equals: "The link could not be opened. Please report an issue from the Settings tab.",
                             "unsupported-URL message")
    }

    func testAlert_OtherURLError_PresentsProse() {
        let alert = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))

        assertPatronReadable(alert.message,
                             equals: "An unknown error occurred. Please check your connection or try again later.",
                             "unknown-request message")
    }

    /// The four NSURLError arms must stay distinguishable: one shared string
    /// would pass every assertion above taken one at a time.
    func testAlert_EachURLErrorArmPresentsItsOwnMessage() {
        let codes = [NSURLErrorNotConnectedToInternet,
                     NSURLErrorTimedOut,
                     NSURLErrorUnsupportedURL,
                     NSURLErrorCannotFindHost]
        let messages = codes.map { code -> String in
            TPPAlertUtils.alert(title: "Error",
                                error: NSError(domain: NSURLErrorDomain, code: code)).message ?? ""
        }

        XCTAssertEqual(Set(messages).count, codes.count,
                       "two URL error arms share a message: \(messages)")
    }

    // MARK: - Adobe DRM arms

    #if FEATURE_DRM_CONNECTOR
    func testAlert_AdobeAuthenticationFailed_PresentsProse() {
        let alert = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NYPLADEPTErrorDomain,
                           code: NYPLADEPTError.authenticationFailed.rawValue))

        assertPatronReadable(alert.message,
                             equals: "This device could not be authorized with the DRM server. Please try again, or contact your library if it keeps happening.",
                             "Adobe authentication-failed message")
    }

    func testAlert_AdobeTooManyActivations_PresentsProse() {
        let alert = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NYPLADEPTErrorDomain,
                           code: NYPLADEPTError.tooManyActivations.rawValue))

        assertPatronReadable(alert.message,
                             equals: "Too many devices have been authorized with this library card.",
                             "Adobe too-many-activations message")
    }

    func testAlert_AdobeArmsPresentDifferentMessages() {
        let failed = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NYPLADEPTErrorDomain,
                           code: NYPLADEPTError.authenticationFailed.rawValue)).message
        let tooMany = TPPAlertUtils.alert(
            title: "Error",
            error: NSError(domain: NYPLADEPTErrorDomain,
                           code: NYPLADEPTError.tooManyActivations.rawValue)).message

        XCTAssertNotEqual(failed, tooMany,
                          "the two Adobe arms must not collapse onto one message")
    }
    #endif

    // MARK: - Sign-out blocked while the registry syncs
    //
    // `TPPSignInBusinessLogic.performLogOut()` builds this alert inside the
    // `#else` (noDRM) arm, which the DRM test target does not compile, and
    // there is no noDRM test target. So this pins the COPY and its trip
    // through the builder, not the call site: reverting those two arguments to
    // literals leaves it green. The substitution itself is pinned by
    // `AlertIdentifierKeyLintTests`, which reads the source and so sees the
    // `#else` arm from this target.

    func testBlockedSignOutCopy_SurvivesTheAlertBuilder() {
        let alert = TPPAlertUtils.alert(title: Strings.Error.cannotSignOutTitle,
                                        message: Strings.Error.cannotSignOutMessage)

        assertPatronReadable(alert.title, equals: "Logout Failed", "blocked sign-out title")
        assertPatronReadable(
            alert.message,
            equals: "Please wait for certain download-related actions to finish before logging out.",
            "blocked sign-out message")
    }

    // MARK: - The second lookup
    //
    // `TPPAlertUtils.alert(title:message:style:)` runs `NSLocalizedString` on
    // both arguments at runtime, so anything the error branches build is looked
    // up again on its way to the alert. That is why the fix resolves each arm
    // where the arm is chosen: there is no literal call site at the branch to
    // hang a `value:` on, and the builder cannot supply one for a key it only
    // sees as a variable. Resolved English survives the second lookup because
    // it is not itself a key in any shipped table.

    func testAlertBuilder_DoesNotReLocalizeResolvedProse() {
        let prose = "You are not connected to the internet. Please connect and try again."
        let alert = TPPAlertUtils.alert(title: prose, message: prose)

        XCTAssertEqual(alert.title, prose, "the builder's lookup altered resolved prose")
        XCTAssertEqual(alert.message, prose, "the builder's lookup altered resolved prose")
    }

    /// The builder must keep localizing its arguments: all four shipped tables
    /// are keyed by English prose, so removing the lookup would un-translate
    /// every prose-passing caller. The key is a `.stringsdict` entry because a
    /// key that resolves nowhere makes both sides equal either way.
    func testAlertBuilder_StillLooksUpItsArguments() {
        let key = "day_suffix_long"
        let resolved = NSLocalizedString(key, comment: "")
        XCTAssertNotEqual(resolved, key,
                          "fixture precondition: the key must resolve, or this cannot discriminate")

        let alert = TPPAlertUtils.alert(title: key, message: key)

        XCTAssertEqual(alert.title, resolved, "the builder stopped looking its arguments up")
        XCTAssertEqual(alert.message, resolved, "the builder stopped looking its arguments up")
    }
}

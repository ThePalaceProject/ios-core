//
//  TPPSignInOIDCStubCallbackTests.swift
//  PalaceTests
//
//  oidcLogIn() always presents an ASWebAuthenticationSession, so the path from
//  URL composition to credential handling is undrivable: a test cannot dismiss
//  a system browser and a journey has no credentials for a live IdP page. The
//  stub seam closes that. It injects a callback, not a session — the token
//  still goes through validateCredentials against the CM.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Pure line-walking over Swift preprocessor directives.
///
/// Extracted from the release-gating test so it can be exercised on synthetic
/// strings instead of only against the real file, which is the established idiom
/// here (`UserDefaultsIsolationLintTests` tests its own predicate against clean,
/// dirty and commented samples). Being a pure function is what makes the
/// `#else`-arm case provable at all: no compiling mutant of the real file can put
/// a load-bearing declaration in the else arm, because the DEBUG arm references it.
enum PreprocessorScan {

    struct Enclosing: Equatable {
        /// The directive line that opens the block the symbol sits in.
        let directive: String
        /// True when the symbol is in that block's `#else` arm.
        let inElseArm: Bool
    }

    /// The conditional block enclosing the first line containing `symbol`.
    static func enclosingCondition(of symbol: String, in source: String) -> Enclosing? {
        let lines = source.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains(symbol) }) else { return nil }

        var depth = 0
        var sawElse = false
        var i = index - 1
        while i >= 0 {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            // Prefix matching, not equality: `#endif // DEBUG` is an #endif, and
            // treating it as an ordinary line made the depth counter attribute a
            // symbol to a block that had already closed.
            if line.hasPrefix("#endif") {
                depth += 1
            } else if line.hasPrefix("#elseif") {
                // A new condition, not an else arm: a symbol below it is guarded
                // by the #elseif's own expression. Reporting that line makes an
                // exact-directive assertion fail, which is the safe direction.
                if depth == 0 { return Enclosing(directive: line, inElseArm: false) }
            } else if line.hasPrefix("#else") {
                if depth == 0 { sawElse = true }
            } else if line.hasPrefix("#if") {
                if depth == 0 { return Enclosing(directive: line, inElseArm: sawElse) }
                depth -= 1
                // `sawElse` is deliberately NOT reset here. Resetting it let a
                // complete nested conditional sitting between the `#if` and the
                // `#else` clear the flag the `#else` had just set, reporting a
                // symbol in the else arm as being in the then arm. A nested
                // `#else` is only ever seen at depth > 0, so it never sets the
                // flag in the first place.
            }
            i -= 1
        }
        return nil
    }
}

@MainActor
final class TPPSignInOIDCStubCallbackTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var stubStore: UserDefaults!

    private static let patronJSON = #"{"name":"Stubbed Patron"}"#

    private static func callbackURL(token: String = "stub-token-123") -> URL {
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        return URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback"
                   + "?access_token=\(token)&patron_info=\(encoded)")!
    }

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        // Without this, oidcLogIn() returns at its `oidcAuthenticationUrl`
        // guard before reaching the seam, and every assertion below passes or
        // fails for the wrong reason.
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        // The seam must not write the app's real UserDefaults domain. The write
        // used to reach `.standard` through a production default argument, which
        // `UserDefaultsIsolationLintTests` cannot see because it greps for the
        // literal `UserDefaults.standard`. A leftover callback key next to a
        // leftover armed key is a DEBUG build that signs in with no identity
        // provider for whoever picks that simulator up next.
        stubStore = Self.testUserDefaults()
        RemoteFeatureFlags.oidcStubDefaults = stubStore
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(nil)
    }

    override func tearDown() {
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(nil)
        // Restore the global the seam reads, or the next suite inherits this
        // one's store.
        RemoteFeatureFlags.oidcStubDefaults = .standard
        stubStore = nil
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        super.tearDown()
    }

    // MARK: - The seam

    /// With a stub set, oidcLogIn() delivers the canned callback instead of
    /// presenting a browser. Asserted on the credentials that arrive, because
    /// that is what a caller depends on.
    func testOIDCLogIn_withStubCallback_deliversTheCredentials() {
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(Self.callbackURL())

        businessLogic.oidcLogIn()

        XCTAssertEqual(businessLogic.authToken, "stub-token-123",
                       "the stubbed callback's access_token should have been handled")
        XCTAssertEqual(businessLogic.patron?["name"] as? String, "Stubbed Patron",
                       "the stubbed callback's patron_info should have been handled")
    }

    /// The stub must not fire when it is unset — otherwise a developer who
    /// never opted in would get a fake sign-in.
    func testOIDCLogIn_withNoStub_deliversNothing() {
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(nil)

        businessLogic.oidcLogIn()

        XCTAssertNil(businessLogic.authToken,
                     "with no stub configured, oidcLogIn must not produce credentials")
        XCTAssertNil(businessLogic.patron,
                     "with no stub configured, oidcLogIn must not produce a patron")

        // Absence alone is also what a seam that never ran would produce, so
        // prove the same fixture DOES deliver once a stub is set.
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(Self.callbackURL())
        businessLogic.oidcLogIn()
        XCTAssertEqual(businessLogic.authToken, "stub-token-123",
                       "control: this fixture reaches the seam, so the nils above mean "
                       + "the stub was off, not that oidcLogIn bailed out early")
    }

    /// An error callback routes through the same error handling as a real one,
    /// so the stub can exercise the failure arm too.
    func testOIDCLogIn_withStubbedErrorCallback_setsNoCredentials() {
        let errorJSON = #"{"title":"Stubbed denial"}"#
        let encoded = errorJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?error=\(encoded)")!
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(url)

        businessLogic.oidcLogIn()

        XCTAssertNil(businessLogic.authToken,
                     "an error callback must not produce an auth token")
        XCTAssertTrue(uiDelegate.didEncounterValidationError,
                      "the stubbed error must reach the UI delegate; a nil token on its "
                      + "own is also what a seam that never fired would produce")
        XCTAssertEqual(uiDelegate.validationErrorMessage, "Stubbed denial",
                       "the error title from the callback payload should surface to the patron")
    }

    /// Two sign-ins in a row must each deliver, so a journey can repeat the
    /// flow without the stub being consumed.
    func testOIDCLogIn_stubIsNotConsumedBySingleUse() {
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(Self.callbackURL(token: "first"))
        businessLogic.oidcLogIn()
        XCTAssertEqual(businessLogic.authToken, "first")

        RemoteFeatureFlags.setOIDCStubCallbackForTesting(Self.callbackURL(token: "second"))
        businessLogic.oidcLogIn()
        XCTAssertEqual(businessLogic.authToken, "second",
                       "the seam should read the current stub on each call, not cache the first")
    }

    // MARK: - The permission gate

    /// The driver-facing arm. A journey arms the seam by writing
    /// `oidcStubSeamArmedKey` into the app's defaults; there is no launch-argument
    /// path because simdrive launches apps with no arguments.
    ///
    /// `environment: [:]` is what makes this observable at all. Read straight from
    /// `ProcessInfo`, the XCTest branch always wins inside a test run and this arm
    /// — the only one QA uses — would be the one arm no test covers.
    func testSeamPermission_outsideXCTest_requiresTheArmedKey() {
        let defaults = Self.testUserDefaults()

        XCTAssertFalse(
            RemoteFeatureFlags.isOIDCStubSeamPermitted(environment: [:], defaults: defaults),
            "with no XCTest marker and no armed key, the seam must stay inert")

        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(true, in: defaults)
        XCTAssertTrue(
            RemoteFeatureFlags.isOIDCStubSeamPermitted(environment: [:], defaults: defaults),
            "a driver that set the armed key must be permitted; otherwise the seam "
            + "is reachable only from XCTest, which does not need it")

        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(false, in: defaults)
        XCTAssertFalse(
            RemoteFeatureFlags.isOIDCStubSeamPermitted(environment: [:], defaults: defaults),
            "disarming must take effect, so a journey cannot leave the seam live")
    }

    /// An XCTest run is permitted without arming, so unit tests need no setup.
    func testSeamPermission_underXCTest_doesNotNeedTheArmedKey() {
        let defaults = Self.testUserDefaults()
        XCTAssertTrue(
            RemoteFeatureFlags.isOIDCStubSeamPermitted(
                environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
                defaults: defaults),
            "the XCTest marker alone permits the seam")
    }

    /// Not permitted, with a perfectly good payload sitting in the store.
    ///
    /// This is the security-relevant cell and nothing covered it: `oidcStubCallback`
    /// used to read `ProcessInfo` directly, so inside a test process the XCTest arm
    /// always granted permission and the clause could be deleted from the guard
    /// with all nine tests still green. Passing `environment` makes the
    /// composition — permission AND payload — reachable.
    func testStubCallback_whenNotPermitted_yieldsNilDespiteAValidPayload() {
        let store = Self.testUserDefaults()
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(Self.callbackURL(), in: store)
        // Deliberately NOT armed, and no XCTest marker in the environment.

        XCTAssertNil(
            RemoteFeatureFlags.oidcStubCallback(environment: [:], defaults: store),
            "an unarmed process must get no callback even with a valid payload stored")

        // Control: the same store and payload DO yield the callback once armed, so
        // the nil above is the permission clause and not a missing payload.
        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(true, in: store)
        XCTAssertEqual(
            RemoteFeatureFlags.oidcStubCallback(environment: [:], defaults: store),
            Self.callbackURL(),
            "control: armed + payload must deliver, or the assertion above proves nothing")
    }

    /// The composed path a QA driver actually uses: no XCTest marker, both keys
    /// written into the app's defaults by the driver.
    func testStubCallback_whenArmedByADriver_deliversWithoutAnXCTestMarker() {
        let store = Self.testUserDefaults()
        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(true, in: store)
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(Self.callbackURL(), in: store)

        XCTAssertEqual(
            RemoteFeatureFlags.oidcStubCallback(environment: [:], defaults: store),
            Self.callbackURL())

        // Disarming must shut it off, so a journey cannot leave the seam live.
        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(false, in: store)
        XCTAssertNil(
            RemoteFeatureFlags.oidcStubCallback(environment: [:], defaults: store),
            "disarming must take effect even while the payload is still stored")
    }

    /// An armed seam with no callback set still yields nothing: arming is
    /// permission, not a payload. Otherwise arming alone would fake a sign-in.
    func testArmedWithoutACallback_yieldsNoStub() {
        let defaults = Self.testUserDefaults()
        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(true, in: defaults)

        XCTAssertNil(RemoteFeatureFlags.oidcStubCallback(defaults: defaults),
                     "armed but unset must yield no stub")

        // Control: the same store DOES yield one once a callback is written, so
        // the nil above means "no payload", not "this read never resolves".
        RemoteFeatureFlags.setOIDCStubCallbackForTesting(Self.callbackURL(), in: defaults)
        XCTAssertEqual(RemoteFeatureFlags.oidcStubCallback(defaults: defaults),
                       Self.callbackURL())
    }

    /// A bare call resolves to the seam's store, not the app's real domain.
    ///
    /// Every existing caller passes `defaults:` explicitly, so the `?? oidcStubDefaults`
    /// arm had no test and a mutant rewriting it to `?? .standard` survived the whole
    /// suite — which is precisely the hazard that resolution was added to prevent.
    ///
    /// This covers both bare paths in one go: the write goes through
    /// `setOIDCStubSeamArmedForTesting` with no `in:` argument, and the read through
    /// `isOIDCStubSeamPermitted` with no `defaults:` argument. It deliberately does
    /// NOT assert against `UserDefaults.standard`: a key leaked there by an earlier
    /// interrupted run would make such an assertion fail for an unrelated reason.
    /// Reading the isolated store is enough — under the mutant the bare read looks in
    /// `.standard`, where this key was never written, and returns false.
    func testBareCalls_resolveToTheSeamStoreAndNotTheRealDomain() {
        // `setUp` has already pointed `oidcStubDefaults` at an isolated suite.
        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(true)

        XCTAssertTrue(stubStore.bool(forKey: RemoteFeatureFlags.oidcStubSeamArmedKey),
                      "a bare write must land in the seam's store")
        XCTAssertTrue(RemoteFeatureFlags.isOIDCStubSeamPermitted(environment: [:]),
                      "a bare read must see the bare write, i.e. both must resolve to "
                      + "the same store")

        // Control: the pair really is tracking the store rather than returning true
        // for some other reason.
        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(false)
        XCTAssertFalse(RemoteFeatureFlags.isOIDCStubSeamPermitted(environment: [:]),
                       "a bare disarm must be visible to a bare read")
    }

    /// An empty override reads as unset.
    ///
    /// This kills no mutant and the comment should not pretend otherwise:
    /// `!raw.isEmpty` is redundant against today's `URL(string: "")`, which is
    /// already nil, so deleting either one leaves this green. The guard is kept as
    /// defence in depth: "an empty string is not a URL" is a Foundation behaviour
    /// this seam relies on and does not control, and the seam sits on the sign-in
    /// path. What this test pins is the BEHAVIOUR, by whichever of the two
    /// provides it.
    func testEmptyOverrideStringIsTreatedAsUnset() {
        let defaults = Self.testUserDefaults()
        RemoteFeatureFlags.setOIDCStubSeamArmedForTesting(true, in: defaults)
        defaults.set("", forKey: RemoteFeatureFlags.oidcStubCallbackLocalOverrideKey)

        XCTAssertNil(RemoteFeatureFlags.oidcStubCallback(defaults: defaults),
                     "an empty override must read as unset, not as an armed nil")
    }

    /// The seam must be absent from release builds.
    ///
    /// Asserted against the source because an `#if` cannot be observed from a
    /// DEBUG-built test run. That is a real limit of this check rather than a
    /// property it establishes: only a Release compile proves absence. What it
    /// does establish is that each piece of the seam sits under a condition that
    /// is exactly `#if DEBUG`, in its then-arm.
    func testSeamDeclarationsSitInsideTheDebugBlock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let flags = try String(
            contentsOf: root.appendingPathComponent("Palace/FeatureFlags/RemoteFeatureFlags.swift"),
            encoding: .utf8)

        // The accessor's BODY is checked with the same parser as the declarations.
        // It used to use a substring search for "#if DEBUG", which accepted a
        // widened condition; combined with an `#endif // DEBUG` making the
        // declarations unconditional, that composed into a seam readable in a
        // Release build with every assertion green.
        let guarded = ["oidcStubCallbackLocalOverrideKey = ",
                       "oidcStubSeamArmedKey = ",
                       "static func isOIDCStubSeamPermitted(",
                       "static var oidcStubDefaults",
                       // inside oidcStubCallback's DEBUG arm
                       "return URL(string: raw)"]
        for symbol in guarded {
            guard let enclosing = PreprocessorScan.enclosingCondition(of: symbol, in: flags) else {
                XCTFail("\(symbol) is not inside any conditional, or is gone from "
                        + "RemoteFeatureFlags — either way this guard no longer covers it")
                continue
            }
            XCTAssertEqual(enclosing.directive, "#if DEBUG",
                           "\(symbol) is guarded by '\(enclosing.directive)', not exactly "
                           + "'#if DEBUG'; a compound condition compiles the seam into "
                           + "any configuration that defines the other flag")
            XCTAssertFalse(enclosing.inElseArm,
                           "\(symbol) sits in the #else arm, so it would ship in "
                           + "Release and be absent from DEBUG")
        }

        // `oidcStubCallback` is deliberately declared OUTSIDE the block so the
        // sign-in call site needs no conditional. Its release arm must return nil
        // without reading the key or the store.
        guard let fnRange = flags.range(of: "static func oidcStubCallback(") else {
            return XCTFail("oidcStubCallback is gone from RemoteFeatureFlags")
        }
        let body = flags[fnRange.upperBound...].prefix(900)
        guard let elseIdx = body.range(of: "#else"),
              let endIdx = body.range(of: "#endif") else {
            return XCTFail("oidcStubCallback's body must carry #else / #endif; without "
                           + "the else arm a release build would fall through to the "
                           + "override read")
        }
        let releaseArm = body[elseIdx.upperBound..<endIdx.lowerBound]
        XCTAssertTrue(releaseArm.contains("nil"),
                      "the release arm must be nil; it is \(releaseArm)")
        XCTAssertFalse(releaseArm.contains("oidcStubCallbackLocalOverrideKey"),
                       "the release arm must not read the override key")
        XCTAssertFalse(releaseArm.contains("oidcStubDefaults"),
                       "the release arm must not touch the seam's store")

        // A defaulted `ProcessInfo.processInfo.environment` is evaluated at the
        // CALL SITE, so a shipped build would construct and discard a dictionary on
        // every sign-in for a function whose release body is `nil`. Scoped to this
        // accessor's signature: `isOIDCStubSeamPermitted` may keep such a default
        // because it is declared inside `#if DEBUG` and has no release call site.
        guard let sigEnd = body.range(of: ") -> URL?") else {
            return XCTFail("could not isolate oidcStubCallback's signature")
        }
        let signature = body[..<sigEnd.lowerBound]
        XCTAssertFalse(
            signature.contains("= ProcessInfo"),
            "resolve the environment inside the DEBUG arm, not as a default "
            + "argument: \(signature)")

        let signIn = try String(
            contentsOf: root.appendingPathComponent("Palace/SignInLogic/TPPSignInBusinessLogic+OIDC.swift"),
            encoding: .utf8)
        XCTAssertFalse(signIn.contains("#if DEBUG"),
                       "the sign-in call site should carry no conditional of its own; "
                       + "all gating belongs to oidcStubCallback")
        XCTAssertTrue(signIn.contains("oidcStubCallback("),
                      "the sign-in path must still consult the seam")
        XCTAssertFalse(signIn.contains("RemoteFeatureFlags.shared"),
                       "the seam is DEBUG-only scaffolding and must not add a "
                       + ".shared read to the sign-in path")
    }

    // MARK: - The scanner itself
    //
    // Synthetic samples, because no compiling mutant of the real file can place a
    // load-bearing declaration in an #else arm: the DEBUG arm references it. These
    // are what make the else-arm assertion above provable rather than merely present.

    func testScan_thenArm_reportsTheDirectiveAndNotTheElseArm() {
        let src = "#if DEBUG\nlet seam = 1\n#else\nlet other = 2\n#endif"
        let got = PreprocessorScan.enclosingCondition(of: "let seam", in: src)
        XCTAssertEqual(got, .init(directive: "#if DEBUG", inElseArm: false))
    }

    func testScan_elseArm_isReported() {
        let src = "#if DEBUG\nlet other = 1\n#else\nlet seam = 2\n#endif"
        let got = PreprocessorScan.enclosingCondition(of: "let seam", in: src)
        XCTAssertEqual(got, .init(directive: "#if DEBUG", inElseArm: true))
    }

    func testScan_elseArm_afterACompleteNestedBlock_isStillReported() {
        // The bug this test exists for: resetting the else flag when walking back
        // past a nested `#if` reported this symbol as being in the THEN arm, so a
        // Release-only seam would have passed the release-gating assertion.
        let src = """
        #if DEBUG
        #if FEATURE_X
        let nested = 0
        #endif
        #else
        let seam = 2
        #endif
        """
        let got = PreprocessorScan.enclosingCondition(of: "let seam", in: src)
        XCTAssertEqual(got, .init(directive: "#if DEBUG", inElseArm: true))
    }

    func testScan_thenArm_afterACompleteNestedBlock_isNotTheElseArm() {
        let src = """
        #if DEBUG
        #if FEATURE_X
        let nested = 0
        #endif
        let seam = 1
        #endif
        """
        let got = PreprocessorScan.enclosingCondition(of: "let seam", in: src)
        XCTAssertEqual(got, .init(directive: "#if DEBUG", inElseArm: false))
    }

    func testScan_aNestedElseDoesNotLeakToTheOuterBlock() {
        let src = """
        #if DEBUG
        #if FEATURE_X
        let a = 0
        #else
        let b = 1
        #endif
        let seam = 2
        #endif
        """
        let got = PreprocessorScan.enclosingCondition(of: "let seam", in: src)
        XCTAssertEqual(got, .init(directive: "#if DEBUG", inElseArm: false))
    }

    func testScan_aCommentedEndifStillCloses() {
        // `#endif // DEBUG` is an #endif. Matching only a bare `#endif` attributed
        // this symbol to a block that had already closed, reporting it as guarded.
        let src = "#if DEBUG\nlet inner = 1\n#endif // DEBUG\nlet seam = 2"
        XCTAssertNil(PreprocessorScan.enclosingCondition(of: "let seam", in: src),
                     "a symbol after a commented #endif is unconditional")
    }

    func testScan_compoundConditionIsReportedVerbatim() {
        let src = "#if DEBUG || ENABLE_QA_SEAM\nlet seam = 1\n#endif"
        XCTAssertEqual(PreprocessorScan.enclosingCondition(of: "let seam", in: src)?.directive,
                       "#if DEBUG || ENABLE_QA_SEAM",
                       "the directive is reported verbatim so an exact-match assertion can fail")
    }

    func testScan_elseifIsReportedRatherThanTreatedAsAnElseArm() {
        let src = "#if DEBUG\nlet a = 0\n#elseif FEATURE_X\nlet seam = 1\n#endif"
        XCTAssertEqual(PreprocessorScan.enclosingCondition(of: "let seam", in: src)?.directive,
                       "#elseif FEATURE_X",
                       "a symbol under #elseif is guarded by that condition, not by #if DEBUG")
    }

    func testScan_unconditionalSymbolHasNoEnclosingBlock() {
        XCTAssertNil(PreprocessorScan.enclosingCondition(of: "let seam", in: "let seam = 1"))
    }

    func testScan_absentSymbolReturnsNil() {
        XCTAssertNil(PreprocessorScan.enclosingCondition(of: "nope", in: "#if DEBUG\nlet a = 1\n#endif"))
    }
}

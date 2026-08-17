//
//  DownloadAuthChallengeWitnessTests.swift
//  PalaceTests
//
//  PP-4895. When a library serves a book file behind HTTP basic auth, the only
//  thing standing between the patron and a failed download is the download
//  center's authentication-challenge delegate callback. URLSession decides
//  whether to invoke an optional delegate method by asking the delegate
//  `respondsToSelector:` — so a method that the Swift compiler declined to
//  register as the protocol witness is not "slightly wrong", it is absent from
//  the ObjC runtime and is never called. No error, no crash, no log.
//
//  That is exactly what an Xcode 26.2 ClangImporter defect can do to this one
//  method: WebKit annotates `WKNavigationDelegate`'s auth-challenge block
//  `WK_SWIFT_UI_ACTOR` (@MainActor), Foundation annotates the structurally
//  identical `URLSessionTaskDelegate` block `NS_SWIFT_SENDABLE`, and whichever
//  the compiler imports FIRST in a given frontend process wins for both. When
//  WebKit wins, the requirement surfaces as `@MainActor @Sendable` and the
//  app's plain `@escaping` handler stops matching. Which side loses is decided
//  by frontend batch membership, so an unrelated file move can flip it.
//
//  The compiler therefore cannot be relied on to guarantee this callback is
//  reachable. These tests assert the guarantee directly, at the same layer
//  URLSession uses:
//    1. the ObjC selector is present in the class's method list — the same
//       `respondsToSelector:` question URLSession asks of the delegate, and
//    2. the callback answers a challenge with the patron's stored credential,
//       cancels rather than replaying a rejected one, defers on TLS trust, and
//       rejects a protection space it does not handle.
//
//  See `.forgeos/intent/pp-4895-async-delegate-auth-challenge.md` for the
//  measured two-import-order reproduction, and the memory
//  `webkit-clangimporter-mainactor-poisoning` for the first sighting of this
//  compiler defect (on a different block shape, #1338).
//

import XCTest
import PalaceNetwork
@testable import Palace

@MainActor
final class DownloadAuthChallengeWitnessTests: XCTestCase {

    /// The selector URLSession actually sends. Spelled as a string on purpose:
    /// `#selector` would resolve through the same Swift-level machinery this
    /// test exists to distrust.
    private static let authChallengeSelector = NSSelectorFromString(
        "URLSession:task:didReceiveChallenge:completionHandler:")

    private let barcode = "12345678901234"
    private let pin = "9999"

    /// Built LAZILY, per test, and only when a test actually needs one — the
    /// registration test below needs none at all, because it asks the class
    /// rather than an instance.
    ///
    /// Constructing a download center is worth avoiding: `URLSession` retains
    /// its delegate, so a center that delegates for a live background session can
    /// never deinit and its `.shared` observers outlive the whole suite, which is
    /// pollution aimed straight at the registry suites that read
    /// `AppContainer.production()`. The `urlSession:` seam below is what actually
    /// closes that — the injected ephemeral session has no delegate, so nothing
    /// retains the center and it deinits normally. Laziness is the smaller,
    /// additive win: fewer constructions, not safer ones.
    private var _signedInCenter: MyBooksDownloadCenter?
    private var _signedOutCenter: MyBooksDownloadCenter?

    private var signedInCenter: MyBooksDownloadCenter {
        if let existing = _signedInCenter { return existing }
        let account = TPPUserAccountTestFactory.makeIsolated()
        account.setBarcode(barcode, PIN: pin)
        let center = makeCenter(account: account)
        _signedInCenter = center
        return center
    }

    private var signedOutCenter: MyBooksDownloadCenter {
        if let existing = _signedOutCenter { return existing }
        let center = makeCenter(account: TPPUserAccountTestFactory.makeIsolated())
        _signedOutCenter = center
        return center
    }

    override func tearDown() async throws {
        _signedInCenter = nil
        _signedOutCenter = nil
        try await super.tearDown()
    }

    private func makeCenter(account: TPPUserAccount) -> MyBooksDownloadCenter {
        MyBooksDownloadCenter(
            userAccount: account,
            bookRegistry: TPPBookRegistryMock(),
            stateManager: DownloadStateManager(),
            reachability: MockReachability(initiallyConnected: true),
            // Test seam — see the property doc above. Delegate-less on purpose:
            // that is what lets this center deinit. Never resumed; this suite
            // invokes the delegate callback directly.
            urlSession: URLSession(configuration: .ephemeral)
        )
    }

    // MARK: - Runtime registration

    func testAuthChallengeCallback_isPresentInTheObjCRuntime() {
        // Asked of the CLASS, not an instance: `instancesRespond(to:)` reads the
        // very method list `respondsToSelector:` consults, so it answers the same
        // question URLSession will ask — without constructing a download center,
        // and so without touching the production container at all.
        XCTAssertTrue(
            MyBooksDownloadCenter.instancesRespond(to: Self.authChallengeSelector),
            """
            MyBooksDownloadCenter does not respond to \
            URLSession:task:didReceiveChallenge:completionHandler:. URLSession \
            only invokes optional delegate methods the delegate responds to, so \
            every basic-auth-protected download will proceed with no credential \
            and fail. Check the build log for a 'nearly matches optional \
            requirement' warning on this method before theorising about timing.
            """)
    }

    // MARK: - Credential behaviour, observed through the delegate

    func testBasicAuthChallenge_suppliesTheStoredBarcodeAndPIN() async {
        let (disposition, credential) = await respond(
            signedInCenter, to: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, barcode)
        XCTAssertEqual(credential?.password, pin)
    }

    func testBasicAuthChallenge_whenSignedOut_cancelsRatherThanRetrying() async {
        // No barcode/PIN stored. Offering no credential must cancel, not fall
        // through to default handling — default handling would surface the
        // system's own auth prompt over the app.
        let (disposition, credential) = await respond(
            signedOutCenter, to: basicAuthChallenge())

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    func testBasicAuthChallenge_afterAPreviousFailure_cancelsInsteadOfReplaying() async {
        // Re-sending credentials the server has already rejected is how a
        // patron's library card gets locked out. One attempt only.
        let (disposition, credential) = await respond(
            signedInCenter, to: basicAuthChallenge(previousFailureCount: 1))

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    func testServerTrustChallenge_defersToTheSystem() async {
        // A TLS server-trust challenge must NOT be answered with a barcode, and
        // must not be cancelled — cancelling would break every https download.
        let (disposition, credential) = await respond(
            signedInCenter, to: challenge(method: NSURLAuthenticationMethodServerTrust))

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func testUnsupportedAuthenticationMethod_rejectsTheProtectionSpace() async {
        // Rejecting lets URLSession move on to another method rather than
        // handing the server a credential it did not ask for.
        let (disposition, credential) = await respond(
            signedInCenter, to: challenge(method: NSURLAuthenticationMethodNTLM))

        XCTAssertEqual(disposition, .rejectProtectionSpace)
        XCTAssertNil(credential)
    }

    // MARK: - Helpers

    /// Invokes the delegate callback and returns its answer.
    ///
    /// Deliberately a direct call rather than optional-requirement dispatch
    /// (`(center as URLSessionTaskDelegate).urlSession?(...)`): optional-chaining
    /// an `async` `@objc` requirement that returns a tuple crashes
    /// swift-frontend in SILGen on Xcode 26.2
    /// (`Lowering::ResultPlanBuilder::buildForScalar`). Registration — the half a
    /// direct call cannot see — is asserted separately above, against the same
    /// method list `respondsToSelector:` consults.
    private func respond(
        _ center: MyBooksDownloadCenter,
        to challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await center.urlSession(
            URLSession(configuration: .ephemeral),
            task: fakeDownloadTask(),
            didReceive: challenge)
    }

    private func basicAuthChallenge(previousFailureCount: Int = 0) -> URLAuthenticationChallenge {
        challenge(method: NSURLAuthenticationMethodHTTPBasic,
                  previousFailureCount: previousFailureCount)
    }

    private func challenge(
        method: String,
        previousFailureCount: Int = 0
    ) -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(
            host: "circulation.palace-test.invalid",
            port: 443,
            protocol: "https",
            realm: "Palace",
            authenticationMethod: method)

        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: MockChallengeSender())
    }
}

//
//  NetworkResponderAuthChallengeWitnessTests.swift
//  PalaceTests
//
//  PP-4895. The network layer's authentication-challenge callback is the second
//  of the app's two challenge sites (the other is the download center, see
//  `DownloadAuthChallengeWitnessTests` for the full write-up of the compiler
//  defect these tests exist to out-guard).
//
//  In short: URLSession invokes an optional delegate method only when the
//  delegate answers `respondsToSelector:`, and under Xcode 26.2 a ClangImporter
//  block-type cache collision with WebKit can leave this method unmatched — and
//  therefore absent from the ObjC runtime — with no error and no crash. So the
//  registration is asserted directly instead of being assumed from the fact that
//  the code compiles.
//

import XCTest
import PalaceNetwork
@testable import Palace

@MainActor
final class NetworkResponderAuthChallengeWitnessTests: XCTestCase {

    /// Spelled as a string on purpose — `#selector` would resolve through the
    /// same Swift machinery this test is here to distrust.
    private static let authChallengeSelector = NSSelectorFromString(
        "URLSession:task:didReceiveChallenge:completionHandler:")

    private let barcode = "23456789012345"
    private let pin = "1234"

    /// `TPPNetworkResponder.credentialsProvider` is a `weak var`, so the provider
    /// has to be owned by the test. If it were a local, it would deallocate and
    /// the responder would silently fall back to the current user account —
    /// passing for the wrong reason.
    private var credentialsProvider: MockCredentialsProvider!
    private var responder: TPPNetworkResponder!

    override func setUp() {
        super.setUp()
        credentialsProvider = MockCredentialsProvider()
        credentialsProvider.username = barcode
        credentialsProvider.pin = pin
        responder = TPPNetworkResponder(credentialsProvider: credentialsProvider,
                                       useFallbackCaching: false)
    }

    override func tearDown() {
        responder = nil
        credentialsProvider = nil
        super.tearDown()
    }

    // MARK: - Runtime registration

    func testAuthChallengeCallback_isPresentInTheObjCRuntime() {
        // Asked of the CLASS: `instancesRespond(to:)` reads the same method list
        // `respondsToSelector:` consults, so it answers the question URLSession
        // will ask of any instance.
        XCTAssertTrue(
            TPPNetworkResponder.instancesRespond(to: Self.authChallengeSelector),
            """
            TPPNetworkResponder does not respond to \
            URLSession:task:didReceiveChallenge:completionHandler:. URLSession \
            only invokes optional delegate methods the delegate responds to, so \
            no request routed through the network layer would ever be able to \
            answer a basic-auth challenge. Check the build log for a 'nearly \
            matches optional requirement' warning on this method.
            """)
    }

    // MARK: - Credential behaviour, observed through the delegate

    func testBasicAuthChallenge_suppliesTheProviderCredential() async {
        let (disposition, credential) = await respond(to: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, barcode)
        XCTAssertEqual(credential?.password, pin)
    }

    func testBasicAuthChallenge_withNoStoredPIN_cancels() async {
        credentialsProvider.pin = nil

        let (disposition, credential) = await respond(to: basicAuthChallenge())

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    func testBasicAuthChallenge_afterAPreviousFailure_cancelsInsteadOfReplaying() async {
        // Replaying credentials the server already rejected is how a patron's
        // card gets locked out.
        let (disposition, credential) = await respond(
            to: basicAuthChallenge(previousFailureCount: 1))

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    func testServerTrustChallenge_defersToTheSystem() async {
        let (disposition, credential) = await respond(
            to: challenge(method: NSURLAuthenticationMethodServerTrust))

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func testUnsupportedAuthenticationMethod_rejectsTheProtectionSpace() async {
        // Rejecting lets URLSession move on to another method rather than
        // handing the server a credential it did not ask for. Present at both
        // challenge sites so the two cannot answer this cell differently.
        let (disposition, credential) = await respond(
            to: challenge(method: NSURLAuthenticationMethodNTLM))

        XCTAssertEqual(disposition, .rejectProtectionSpace)
        XCTAssertNil(credential)
    }

    // MARK: - Which account answers (PP-4969)

    /// Holds the ONLY strong reference to the account-screen provider, so a test
    /// can decide exactly when it dies. The responder itself holds it weakly, and
    /// the whole point of PP-4969 is what happens after it is gone — so lifetime
    /// has to be explicit here rather than incidental. (A first version of this
    /// helper returned a `() -> Void` release closure; discarding that closure in
    /// the "still alive" test silently dropped the last reference and the provider
    /// died before the assertion. Hence a named box.)
    private final class ProviderBox {
        var provider: MockCredentialsProvider?
    }

    /// Returns a responder over a releasable account-screen provider plus a
    /// distinct fallback standing in for "whatever library is current now".
    private func makeReleasableResponder() -> (TPPNetworkResponder, ProviderBox) {
        let box = ProviderBox()
        let screen = MockCredentialsProvider()
        screen.username = "screen-barcode"
        screen.pin = "screen-pin"
        box.provider = screen

        let fallback = MockCredentialsProvider()
        fallback.username = "current-library-barcode"
        fallback.pin = "current-library-pin"

        let responder = TPPNetworkResponder(
            credentialsProvider: screen,
            useFallbackCaching: false,
            fallbackCredentialsProvider: { fallback })
        return (responder, box)
    }

    func testProviderReleasedMidRequest_declinesRatherThanSendingTheCurrentLibrarysBarcode() async {
        // The heart of PP-4969. The account screen supplied the credentials and
        // has since closed. Falling back to the current library would send THAT
        // library's card to this library's server.
        let (responder, box) = makeReleasableResponder()
        box.provider = nil

        let (disposition, credential) = await respond(responder, to: basicAuthChallenge())

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge,
                       "a released provider must decline, not substitute")
        XCTAssertNil(credential)
        XCTAssertNotEqual(credential?.user, "current-library-barcode",
                          "the current library's barcode must never answer another library's challenge")
    }

    func testProviderReleasedMidRequest_stillDefersOnServerTrust() async {
        // The cell a naive "cancel when the provider is gone" fix breaks.
        // Cancelling a TLS trust challenge would break every https request.
        let (responder, box) = makeReleasableResponder()
        box.provider = nil

        let (disposition, credential) = await respond(
            responder, to: challenge(method: NSURLAuthenticationMethodServerTrust))

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func testProviderReleasedMidRequest_stillRejectsAnUnsupportedMethod() async {
        // The second cell a naive cancel-on-missing-provider fix would change.
        let (responder, box) = makeReleasableResponder()
        box.provider = nil

        let (disposition, _) = await respond(
            responder, to: challenge(method: NSURLAuthenticationMethodNTLM))

        XCTAssertEqual(disposition, .rejectProtectionSpace)
    }

    func testProviderStillAlive_usesItsCredentialsNotTheFallback() async {
        // Guards the other direction: the new "was it ever supplied" bookkeeping
        // must not divert a live provider to the fallback.
        let (responder, box) = makeReleasableResponder()

        let (disposition, credential) = await respond(responder, to: basicAuthChallenge())

        // Keep `box` alive ACROSS the await above. ARC guarantees a reference
        // only to its last use, so if the only mention of `box` sat before the
        // await, an optimized build could release it — and the provider with it —
        // before the challenge is answered, and this test would fail as a decline.
        // That would make it pass or fail on optimization level rather than on
        // behaviour. Both a use after the await and the explicit call below pin it.
        withExtendedLifetime(box) {}
        XCTAssertNotNil(box.provider)
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "screen-barcode")
        XCTAssertEqual(credential?.password, "screen-pin")
    }

    func testNoProviderEverSupplied_stillReachesTheCurrentAccount() async {
        // Every other call site in the app passes nil deliberately and relies on
        // this fallback. Declining here would break all of them, so "released"
        // and "never supplied" must stay distinguishable.
        let fallback = MockCredentialsProvider()
        fallback.username = "current-library-barcode"
        fallback.pin = "current-library-pin"
        let responder = TPPNetworkResponder(
            credentialsProvider: nil,
            useFallbackCaching: false,
            fallbackCredentialsProvider: { fallback })

        let (disposition, credential) = await respond(responder, to: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "current-library-barcode")
    }

    func testNoProviderEverSupplied_stillDefersOnServerTrust() async {
        let (disposition, credential) = await respond(
            makeFallbackOnlyResponder(), to: challenge(method: NSURLAuthenticationMethodServerTrust))

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func testNoProviderEverSupplied_stillRejectsAnUnsupportedMethod() async {
        let (disposition, _) = await respond(
            makeFallbackOnlyResponder(), to: challenge(method: NSURLAuthenticationMethodNTLM))

        XCTAssertEqual(disposition, .rejectProtectionSpace)
    }

    private func makeFallbackOnlyResponder() -> TPPNetworkResponder {
        let fallback = MockCredentialsProvider()
        fallback.username = "current-library-barcode"
        fallback.pin = "current-library-pin"
        return TPPNetworkResponder(
            credentialsProvider: nil,
            useFallbackCaching: false,
            fallbackCredentialsProvider: { fallback })
    }

    // MARK: - Helpers

    /// Invokes the delegate callback and returns its answer.
    ///
    /// A direct call, not optional-requirement dispatch: optional-chaining an
    /// `async` `@objc` requirement that returns a tuple crashes swift-frontend in
    /// SILGen on Xcode 26.2. Registration is asserted separately above, via the
    /// same `respondsToSelector:` URLSession consults.
    private func respond(
        to challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await respond(responder, to: challenge)
    }

    private func respond(
        _ responder: TPPNetworkResponder,
        to challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await responder.urlSession(
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

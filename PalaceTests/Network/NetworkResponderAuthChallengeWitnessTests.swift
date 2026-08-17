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

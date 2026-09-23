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

// `PalaceWiringTestCase` rather than `XCTestCase`: it is the sanctioned seam for
// minting an `AccountsManager` in a test, and its tearDown calls
// `cancelAndDrainBackgroundWork()` on every manager it minted. A hand-rolled
// `AccountsManager()` pins the same opt-out flag but leaks that cancellation —
// which is why `AccountsManagerIsolationLintTests` bans it, and why CI caught it.
// The base is already `@MainActor`.
final class DownloadAuthChallengeWitnessTests: PalaceWiringTestCase {

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

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Skip the synchronous on-disk cached-account load — its declaration names
        // it the root of the FLAKE-003 30s CI timeout. Safe here because nothing in
        // this file reads `accountSets` or `account(uuid:)`; every account read
        // resolves through `AccountCredentialResolver`, a different structure.
        // (`deferInitialLoadCatalogsForTesting` is the base class's job.)
        AccountsManager.deferDiskCachePreloadForTesting = true
    }

    override func tearDown() async throws {
        _signedInCenter = nil
        _signedOutCenter = nil
        // Real keychain entries under `test-uuid-…` namespaced keys outlive the
        // throwaway manager, so this is still load-bearing even though the manager
        // itself dies with the test.
        mintedLibraryAccounts.forEach { $0.removeAll() }
        mintedLibraryAccounts.removeAll()
        // Global flag — restore the default rather than leaking the opt-out into
        // suites that DO read the account registry.
        AccountsManager.deferDiskCachePreloadForTesting = false
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

    // MARK: - Which account answers (PP-4969)

    /// Builds a center whose state manager persists to a temp file, so a started-
    /// task record can be seeded without touching the real download store.
    ///
    /// Deliberately does NOT pass `userAccount:` — `userAccount(forCapturedId:)`
    /// lets an injected account win over the captured id, which would make the
    /// captured-id resolution untestable. This center therefore resolves through
    /// the real accounts manager, so any account it must see has to be minted via
    /// `makeLibraryAccount` below — NOT via `TPPUserAccountTestFactory`, which
    /// returns a separate instance that only agrees through the keychain.
    /// - Parameter account: when supplied it becomes `userAccount`, i.e. the value
    ///   the resolver DEGRADES to. Pass it for the fallback-arm tests so the
    ///   fallback is observable; omit it for the captured-account test, where an
    ///   injected account would win over the captured id and make the resolution
    ///   untestable.
    private func makeCenterWithPersistence(
        _ persistenceURL: URL,
        account: TPPUserAccount? = nil
    ) -> (MyBooksDownloadCenter, DownloadStateManager) {
        let stateManager = DownloadStateManager(
            taskPersistence: DownloadTaskPersistence(fileURL: persistenceURL))
        let center = MyBooksDownloadCenter(
            userAccount: account,
            bookRegistry: TPPBookRegistryMock(),
            // Same manager `makeLibraryAccount` mints through — that shared
            // instance is what keeps the keychain out of the resolution path.
            accountsManager: testAccountsManager,
            stateManager: stateManager,
            reachability: MockReachability(initiallyConnected: true),
            urlSession: URLSession(configuration: .ephemeral))
        return (center, stateManager)
    }

    /// Accounts minted for the captured-account tests, cleaned up in `tearDown`.
    private var mintedLibraryAccounts: [TPPUserAccount] = []

    /// The accounts manager shared by this suite's non-injected centers and by
    /// `makeLibraryAccount`. Fresh per test method (XCTest builds a case instance
    /// per method), so nothing is shared across tests and nothing reaches the
    /// production `AppContainer`.
    ///
    /// Constructed directly rather than via `makeTestAppContainer()` on purpose.
    /// That factory builds an entire graph to hand back one member, and the
    /// `MyBooksDownloadCenter` inside it is built WITHOUT the `urlSession:` seam —
    /// so it creates a background `URLSession` on the single static
    /// `backgroundSessionIdentifier` with itself as delegate. A `URLSession`
    /// retains its delegate and this one is never invalidated, so every call would
    /// strand a download center holding a background session on an identifier
    /// Apple documents as one-live-session-per-process. That is precisely the
    /// pollution this file's `urlSession:` seam exists to avoid for its own
    /// centers; it would be perverse to reintroduce it through the fixture.
    ///
    /// The flag pin is what the factory was wanted for, and it is one line. NOTE it
    /// lives behind `#if DEBUG` in `AccountsManager`, so in a non-DEBUG
    /// configuration the background `loadCatalogs` is not suppressed — true of the
    /// factory too, so this is not a regression, but it is not a guarantee either.
    private lazy var testAccountsManager: AccountsManager = makeFreshAccountsManager()

    /// Mints a library account through the SAME resolver the center under test
    /// will use, so the test and the resolver share ONE instance.
    ///
    /// **Any test using a center that is NOT given an injected `userAccount:` must
    /// mint through here**, and that center must be built with
    /// `testAccountsManager`. Those centers resolve by library id, and only a
    /// shared instance keeps the keychain out of the path.
    ///
    /// Deliberately not `TPPUserAccountTestFactory.makeIsolated`: that constructs a
    /// fresh `TPPUserAccount` which bypasses the accounts-manager cache, so
    /// credentials written here would only reach the resolver's instance by
    /// round-tripping through the KEYCHAIN. That works locally and fails on CI,
    /// where the simulator keychain returns -34018 (missing entitlement) — three
    /// tests in this file passed locally and failed all three CI retries for
    /// exactly that reason. Sharing the instance removes the keychain from the
    /// path entirely, which is also what this project's test rules ask for.
    private func makeLibraryAccount(id: String, barcode: String, pin: String) -> TPPUserAccount {
        let account = testAccountsManager.userAccount(for: id)
        account.setBarcode(barcode, PIN: pin)
        mintedLibraryAccounts.append(account)
        return account
    }

    private func tempPersistenceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pp4969-\(UUID().uuidString).json")
    }

    func testChallengeOnDownload_usesTheAccountTheDownloadStartedFor_notTheCurrentOne() async throws {
        // The heart of PP-4969's download arm. The patron started this download
        // while library A was selected and has since switched libraries. The
        // challenge must still be answered with A's card — answering with
        // whatever is current now hands library A's server another library's
        // credential.
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp4969-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let startedLibraryID = "test-uuid-\(UUID().uuidString)"
        let startedAccount = makeLibraryAccount(id: startedLibraryID,
                                                barcode: "started-library-card",
                                                pin: "started-pin")

        let (center, stateManager) = makeCenterWithPersistence(persistenceURL)

        // Pins the property that makes this suite independent of the keychain:
        // the resolver hands back the SAME instance the test just wrote to, so
        // the credentials never have to round-trip through storage. When these
        // were two instances for one library id, they agreed only via the
        // keychain — green locally, red on CI where it returns -34018.
        XCTAssertIdentical(center.userAccount(forCapturedId: startedLibraryID), startedAccount,
                           "the resolver must share the test's account instance, not depend on keychain persistence")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = fakeDownloadTask()

        await stateManager.taskIdentifierToBook.set(task.taskIdentifier, value: book)
        stateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: task.taskIdentifier,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: startedLibraryID,
            expectedBytes: nil)

        let (disposition, credential) = await center.urlSession(
            URLSession(configuration: .ephemeral),
            task: task,
            didReceive: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "started-library-card",
                       "the challenge must be answered with the account the download started for")
        XCTAssertEqual(credential?.password, "started-pin")
    }

    func testChallengeOnDownload_forATaskWithNoLiveMapping_fallsBackToTodaysBehaviour() async {
        // Degradation arm 1 of 3: the task is not in `taskIdentifierToBook`, so
        // resolution stops at hop 1 and never reaches the record lookup. (This
        // test was originally misnamed "withNoStartedTaskRecord", which described
        // arm 2 — a different branch it never reached. Review caught it.)
        let signedIn = TPPUserAccountTestFactory.makeIsolated()
        signedIn.setBarcode("fallback-card", PIN: "fallback-pin")
        let center = makeCenter(account: signedIn)

        let (disposition, credential) = await center.urlSession(
            URLSession(configuration: .ephemeral),
            task: fakeDownloadTask(),
            didReceive: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "fallback-card")
    }

    func testChallengeOnDownload_withAStartedTaskRecord_stillDefersOnServerTrust() async {
        // The captured-account lookup must not change what a TLS trust challenge
        // does. Cancelling one would break every https download. Note the
        // resolver short-circuits before hop 1 for non-basic spaces (it skips a
        // file read that cannot affect the answer), so what this pins is the
        // OUTCOME contract: whichever account resolution happens or is skipped,
        // a trust challenge is still handed back to the system.
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp4969-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let startedLibraryID = "test-uuid-\(UUID().uuidString)"
        _ = makeLibraryAccount(id: startedLibraryID, barcode: "irrelevant", pin: "irrelevant")

        let (center, stateManager) = makeCenterWithPersistence(persistenceURL)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = fakeDownloadTask()
        await stateManager.taskIdentifierToBook.set(task.taskIdentifier, value: book)
        stateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: task.taskIdentifier,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: startedLibraryID,
            expectedBytes: nil)

        let (disposition, credential) = await center.urlSession(
            URLSession(configuration: .ephemeral),
            task: task,
            didReceive: challenge(method: NSURLAuthenticationMethodServerTrust))

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func testChallengeOnDownload_whenTheTaskIsMappedButHasNoRecord_fallsBackToTodaysBehaviour() async {
        // Degradation arm 2 of 3: the book IS known, but no durable record names
        // an account for it. Distinct branch from arm 1 above.
        let persistenceURL = tempPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let fallbackAccount = TPPUserAccountTestFactory.makeIsolated()
        fallbackAccount.setBarcode("fallback-card", PIN: "fallback-pin")
        let (center, stateManager) = makeCenterWithPersistence(persistenceURL, account: fallbackAccount)

        let task = fakeDownloadTask()
        await stateManager.taskIdentifierToBook.set(
            task.taskIdentifier, value: TPPBookMocker.mockBook(distributorType: .EpubZip))
        // Deliberately no persistStartedTask call.

        let (disposition, credential) = await center.urlSession(
            URLSession(configuration: .ephemeral), task: task, didReceive: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "fallback-card")
    }

    func testChallengeOnDownload_whenTheRecordHasNoAccount_fallsBackToTodaysBehaviour() async {
        // Degradation arm 3 of 3, and NOT hypothetical: the start path writes
        // `account: accountScope.currentAccountID ?? ""`, so production emits the
        // empty string itself whenever no account id is resolvable. Without the
        // emptiness guard this would resolve the "" account rather than degrade.
        let persistenceURL = tempPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        // Asserted on the RESOLVER rather than through the delegate, deliberately.
        // Observed through the challenge answer these two outcomes are identical:
        // an injected account wins over the captured id (so the guard would be
        // invisible), and without one, both the degraded account and the
        // empty-id account are credential-less in a test environment, so both
        // answers are `.cancelAuthenticationChallenge`. The distinction is real
        // but only visible as WHICH account is resolved, so that is what this
        // pins. Removing the emptiness guard makes it resolve the ""-keyed
        // account instead and this fails.
        let (center, stateManager) = makeCenterWithPersistence(persistenceURL)

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = fakeDownloadTask()
        await stateManager.taskIdentifierToBook.set(task.taskIdentifier, value: book)
        stateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: task.taskIdentifier,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: "",
            expectedBytes: nil)

        let resolved = await center.challengeAccount(for: task, challenge: basicAuthChallenge())

        XCTAssertTrue(resolved === center.userAccount,
                      "an empty account id must degrade to today's account, not resolve the empty-id account")
        XCTAssertFalse(resolved === center.userAccount(forCapturedId: ""),
                       "the empty-id account must never answer a challenge")
    }

    func testChallengeOnDownload_withTwoLibrariesDownloading_picksTheChallengingBooksAccount() async {
        // Selectivity. Two concurrent downloads from two libraries IS the defect
        // scenario, and with only one record persisted a resolver that just took
        // the FIRST record would pass every other test in this file.
        let persistenceURL = tempPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let otherLibraryID = "test-uuid-\(UUID().uuidString)"
        _ = makeLibraryAccount(id: otherLibraryID,
                               barcode: "other-library-card",
                               pin: "other-pin")

        let challengingLibraryID = "test-uuid-\(UUID().uuidString)"
        let challengingAccount = makeLibraryAccount(id: challengingLibraryID,
                                                    barcode: "challenging-library-card",
                                                    pin: "challenging-pin")

        let (center, stateManager) = makeCenterWithPersistence(persistenceURL)
        // IDENTITY, not credential visibility. Identity is the storage-independent
        // property: two instances for one library agree via the keychain, which
        // SUCCEEDS locally, so a `.barcode` precondition passes here and fails only
        // on CI — reproducing the very defect this suite exists to eliminate.
        // Measured: reverting the helper fails all three converted tests locally
        // with identity, and only one with the credential form.
        XCTAssertIdentical(center.userAccount(forCapturedId: challengingLibraryID), challengingAccount,
                           "the resolver must share this test's account instance, not depend on keychain persistence")
        XCTAssertEqual(challengingAccount.barcode, "challenging-library-card",
                       "fixture precondition: the credentials this test wrote must be visible")

        // The OTHER library's download is recorded first, so `.first` alone would
        // return it.
        let otherBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        stateManager.persistStartedTask(
            bookID: otherBook.identifier,
            taskIdentifier: 900_001,
            downloadURL: URL(string: "https://library-b.palace-test.invalid/book")!,
            account: otherLibraryID,
            expectedBytes: nil)

        let challengingBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = fakeDownloadTask()
        await stateManager.taskIdentifierToBook.set(task.taskIdentifier, value: challengingBook)
        stateManager.persistStartedTask(
            bookID: challengingBook.identifier,
            taskIdentifier: task.taskIdentifier,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: challengingLibraryID,
            expectedBytes: nil)

        let (disposition, credential) = await center.urlSession(
            URLSession(configuration: .ephemeral), task: task, didReceive: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "challenging-library-card",
                       "the record must be selected by the challenging task's book, not by position")
    }

    func testChallengeOnDownload_afterTheTaskIsReissued_stillUsesTheOriginalAccount() async {
        // The bearer-token and rights re-issue paths (RightsManagementDispatcher,
        // BackgroundDownloadHandler) create a NEW task for the SAME book and seed
        // the map for it WITHOUT writing a new record. Resolution therefore has to
        // key on the book, not the task — which is the entire correctness argument
        // for those two sites.
        //
        // Without this test, re-keying hop 2 to `$0.taskIdentifier ==
        // task.taskIdentifier` passes the whole suite, because every other test
        // here challenges with the same identifier it persisted under. That
        // refactor would look like a tightening and would silently break re-issue.
        let persistenceURL = tempPersistenceURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let startedLibraryID = "test-uuid-\(UUID().uuidString)"
        let startedAccount = makeLibraryAccount(id: startedLibraryID,
                                                barcode: "original-library-card",
                                                pin: "original-pin")

        let (center, stateManager) = makeCenterWithPersistence(persistenceURL)
        // Identity, for the reason given in the selectivity test above.
        XCTAssertIdentical(center.userAccount(forCapturedId: startedLibraryID), startedAccount,
                           "the resolver must share this test's account instance, not depend on keychain persistence")
        XCTAssertEqual(startedAccount.barcode, "original-library-card",
                       "fixture precondition: the credentials this test wrote must be visible")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        // The record is written under the ORIGINAL task identifier...
        stateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: 900_777,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: startedLibraryID,
            expectedBytes: nil)

        // ...and the challenge arrives on the RE-ISSUED task, mapped to the same
        // book, with no record of its own.
        let reissuedTask = fakeDownloadTask()
        XCTAssertNotEqual(reissuedTask.taskIdentifier, 900_777,
                          "fixture precondition: the re-issued task must have a different identifier")
        await stateManager.taskIdentifierToBook.set(reissuedTask.taskIdentifier, value: book)

        let (disposition, credential) = await center.urlSession(
            URLSession(configuration: .ephemeral),
            task: reissuedTask,
            didReceive: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "original-library-card",
                       "a re-issued task must inherit the account its book's download started under")
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

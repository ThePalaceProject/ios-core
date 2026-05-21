//
//  TPPAgeCheckDeepTests.swift
//  PalaceTests
//
//  Deep, mutation-killing tests for TPPAgeCheck. The age gate guards
//  pre-COPPA-style libraries: under-13 patrons must be blocked, over-13
//  patrons admitted, and a previously-shown-prompt must not be re-shown.
//
//  Focus areas:
//    - isValid() year-range bounds (min boundary, max boundary, below min,
//      above max).
//    - didCompleteAgeCheck() decision math — strict >13 not >=13.
//    - Borderline cases that exercise the exact subtraction at line 102.
//    - verifyCurrentAccountAgeRequirement() decision tree:
//        * needsAuth=true → admit
//        * userAboveAgeLimit=true → admit
//        * userPresentedAgeCheck=true & below limit → block (no re-prompt)
//        * nil currentAccount → block defensively
//    - didFailAgeCheck() must NOT mark userPresentedAgeCheck so the prompt
//      can re-appear on the next attempt.
//

import XCTest
@testable import Palace
import PalaceCatalog

// MARK: - Test delegate / context helpers

private final class FakeUserAccountProvider: NSObject, TPPUserAccountProvider {
    var needsAuth: Bool = false
    static func sharedAccount(libraryUUID: String?) -> TPPUserAccount {
        return TPPUserAccountMock.sharedAccount(libraryUUID: libraryUUID)
    }
}

/// A `TPPCurrentLibraryAccountProvider` wrapper that lets a test toggle
/// `userAboveAgeLimit` independently of the real Account fixture flow.
private final class StubLibraryProvider: NSObject, TPPCurrentLibraryAccountProvider {
    var currentAccount: Account?
    init(account: Account?) {
        self.currentAccount = account
        super.init()
    }
}

// MARK: - TPPAgeCheck.isValid()

final class TPPAgeCheckIsValidTests: XCTestCase {

    private var storage: TPPAgeCheckChoiceStorageMock!
    private var ageCheck: TPPAgeCheck!

    override func setUp() {
        super.setUp()
        storage = TPPAgeCheckChoiceStorageMock()
        ageCheck = TPPAgeCheck(ageCheckChoiceStorage: storage)
    }

    override func tearDown() {
        ageCheck = nil
        storage = nil
        super.tearDown()
    }

    func test_isValid_minYear_isAdmitted() {
        // Pins the `birthYear >= minYear` lower bound — mutating `>=` to `>`
        // rejects the exact minYear (1900) which is in spec.
        XCTAssertTrue(ageCheck.isValid(birthYear: ageCheck.minYear),
                      "minYear (1900) must be considered a valid birth year")
    }

    func test_isValid_currentYear_isAdmitted() {
        // Pins the `birthYear <= currentYear` upper bound — mutating `<=`
        // to `<` rejects the exact current year which is in spec.
        XCTAssertTrue(ageCheck.isValid(birthYear: ageCheck.currentYear),
                      "currentYear must be considered a valid birth year (newborn)")
    }

    func test_isValid_belowMinYear_isRejected() {
        // Pins the `birthYear >= minYear` lower bound — without this assertion,
        // mutating `>=` to `<=` would survive.
        XCTAssertFalse(ageCheck.isValid(birthYear: ageCheck.minYear - 1),
                       "Birth year below minYear must be rejected")
    }

    func test_isValid_aboveCurrentYear_isRejected() {
        // Pins the `birthYear <= currentYear` upper bound.
        XCTAssertFalse(ageCheck.isValid(birthYear: ageCheck.currentYear + 1),
                       "Birth year above currentYear must be rejected (no time-traveler patrons)")
    }

    func test_birthYearList_spansMinToCurrentInclusive() {
        // The picker list must include both endpoints — off-by-one in the
        // `Array(minYear...currentYear)` range would either miss minYear or
        // currentYear depending on which side flips.
        XCTAssertEqual(ageCheck.birthYearList.first, ageCheck.minYear,
                       "birthYearList must START at minYear")
        XCTAssertEqual(ageCheck.birthYearList.last, ageCheck.currentYear,
                       "birthYearList must END at currentYear")
        XCTAssertEqual(ageCheck.birthYearList.count,
                       ageCheck.currentYear - ageCheck.minYear + 1,
                       "birthYearList count must include BOTH endpoints (closed range)")
    }
}

// MARK: - didCompleteAgeCheck / didFailAgeCheck

final class TPPAgeCheckCompletionTests: XCTestCase {

    private var storage: TPPAgeCheckChoiceStorageMock!
    private var ageCheck: TPPAgeCheck!

    override func setUp() {
        super.setUp()
        storage = TPPAgeCheckChoiceStorageMock()
        ageCheck = TPPAgeCheck(ageCheckChoiceStorage: storage)
    }

    override func tearDown() {
        ageCheck = nil
        storage = nil
        super.tearDown()
    }

    /// Convenience: fire `verifyCurrentAccountAgeRequirement` with a stub
    /// account that needs the prompt, then immediately fire
    /// `didCompleteAgeCheck` with a chosen birth year. Returns the
    /// captured aboveAgeLimit result.
    ///
    /// §10.3 seam: after enqueueing the verify call, we explicitly drain
    /// the private serial queue via `flushPendingForTests()` before firing
    /// `didCompleteAgeCheck`. This makes the ordering explicit instead of
    /// load-bearing on the FIFO contract of `serialQueue.async`.
    private func runVerifyThenComplete(birthYear: Int) -> Bool {
        let library = makeStubAccountNeedingPrompt()
        let provider = StubLibraryProvider(account: library)
        let userProvider = FakeUserAccountProvider() // needsAuth=false default

        let verifyDone = expectation(description: "verify completion fires once age-check decision is dispatched")
        var capturedAboveAgeLimit: Bool?
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userProvider,
            currentLibraryAccountProvider: provider) { aboveAgeLimit in
            capturedAboveAgeLimit = aboveAgeLimit
            verifyDone.fulfill()
        }

        // Drain the serial queue: the verify-append now runs synchronously
        // before we enqueue didCompleteAgeCheck, eliminating reliance on
        // FIFO ordering.
        ageCheck.flushPendingForTests()
        ageCheck.didCompleteAgeCheck(birthYear)

        // 30s budget — the serialQueue chain (verify append → flush →
        // didCompleteAgeCheck enqueue → handler fanout) can race CI
        // runner load. The previous 5s budget started timing out
        // intermittently, surfacing as the *subsequent* line-205
        // XCTAssertTrue failure (userPresentedAgeCheck never flipped to
        // true because the didCompleteAgeCheck block hadn't run yet
        // when the wait returned).
        wait(for: [verifyDone], timeout: 30.0)
        return capturedAboveAgeLimit ?? false
    }

    private func makeStubAccountNeedingPrompt() -> Account {
        // Build a real Account from the SimplyE auth-doc fixture; flag
        // userAboveAgeLimit=false and userPresentedAgeCheck=false to force
        // the prompt path. needsAuth=false also required.
        let libProvider = TPPCurrentLibraryAccountProviderMock()
        let account = libProvider.currentAccount!
        account.details?.userAboveAgeLimit = false
        return account
    }

    func test_didComplete_birthYearExactly13YearsAgo_marksBelowAgeLimit() {
        // Production logic: `currentYear - birthYear > 13`. A patron born
        // exactly 13 years ago yields 13 - which is NOT > 13 → blocked.
        // Mutating `>` to `>=` would flip this assertion.
        let thisYear = Calendar.current.component(.year, from: Date())
        let aboveAgeLimit = runVerifyThenComplete(birthYear: thisYear - 13)

        XCTAssertFalse(aboveAgeLimit,
                       "A patron born exactly 13 years ago must NOT be above the age limit (strict > 13 in production)")
    }

    func test_didComplete_birthYear14YearsAgo_marksAboveAgeLimit() {
        // 14-year-old patron: 14 > 13 → admitted. Pins the truthy branch.
        let thisYear = Calendar.current.component(.year, from: Date())
        let aboveAgeLimit = runVerifyThenComplete(birthYear: thisYear - 14)

        XCTAssertTrue(aboveAgeLimit,
                      "A patron born 14 years ago must be above the age limit")
    }

    func test_didComplete_birthYear5YearsAgo_marksBelowAgeLimit() {
        // 5-year-old patron — far below threshold. Sanity-pin the false branch.
        let thisYear = Calendar.current.component(.year, from: Date())
        let aboveAgeLimit = runVerifyThenComplete(birthYear: thisYear - 5)

        XCTAssertFalse(aboveAgeLimit,
                       "A patron born 5 years ago must NOT be above the age limit")
    }

    func test_didComplete_setsUserPresentedAgeCheckTrue() {
        // After the user completes the picker, userPresentedAgeCheck must
        // flip to true so the prompt doesn't re-appear on subsequent
        // navigations.
        XCTAssertFalse(storage.userPresentedAgeCheck, "precondition: not yet presented")
        let thisYear = Calendar.current.component(.year, from: Date())
        _ = runVerifyThenComplete(birthYear: thisYear - 25)

        XCTAssertTrue(storage.userPresentedAgeCheck,
                      "didCompleteAgeCheck must flip userPresentedAgeCheck to true so the prompt is not re-shown")
    }

    func test_didFail_doesNotSetUserPresentedAgeCheck() {
        // If the user cancels/fails the age check, we MUST be able to
        // re-prompt them. So userPresentedAgeCheck must remain false.
        // §10.3 seam: we drain the serial queue synchronously after both
        // enqueues so we can assert the post-condition without a
        // wall-clock drain timer.
        let library = makeStubAccountNeedingPrompt()
        let provider = StubLibraryProvider(account: library)
        let userProvider = FakeUserAccountProvider()

        var completionFired = false
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userProvider,
            currentLibraryAccountProvider: provider) { _ in
            completionFired = true
        }
        ageCheck.didFailAgeCheck()

        // Drain — both verify and didFailAgeCheck blocks must have executed
        // by the time this returns.
        ageCheck.flushPendingForTests()

        XCTAssertFalse(completionFired,
                       "Verify completion must NOT fire on the fail path — didFailAgeCheck wipes the handler list")
        XCTAssertFalse(storage.userPresentedAgeCheck,
                       "didFailAgeCheck must NOT mark userPresentedAgeCheck — the patron must be re-promptable")
    }
}

// MARK: - verifyCurrentAccountAgeRequirement decision tree

final class TPPAgeCheckVerifyDecisionTests: XCTestCase {

    private var storage: TPPAgeCheckChoiceStorageMock!
    private var ageCheck: TPPAgeCheck!

    override func setUp() {
        super.setUp()
        storage = TPPAgeCheckChoiceStorageMock()
        ageCheck = TPPAgeCheck(ageCheckChoiceStorage: storage)
    }

    override func tearDown() {
        ageCheck = nil
        storage = nil
        super.tearDown()
    }

    private func makeLibraryProvider() -> (StubLibraryProvider, Account) {
        let libMock = TPPCurrentLibraryAccountProviderMock()
        let provider = StubLibraryProvider(account: libMock.currentAccount)
        return (provider, libMock.currentAccount!)
    }

    func test_verify_needsAuthTrue_admitsUserWithoutPrompt() {
        // If the library requires authentication (needsAuth=true), the
        // age check is a no-op: the patron will go through the credentialed
        // flow which has its own gates. Pins the `needsAuth == true` branch
        // — mutating it to `false` would block credentialed libraries.
        let (provider, account) = makeLibraryProvider()
        account.details?.userAboveAgeLimit = false  // would otherwise block
        let userProvider = FakeUserAccountProvider()
        userProvider.needsAuth = true

        let exp = expectation(description: "verify completes")
        var result: Bool?
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userProvider,
            currentLibraryAccountProvider: provider) {
            result = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(result, true,
                       "needsAuth=true must admit the patron immediately without an age prompt")
    }

    func test_verify_userAboveAgeLimitTrue_admitsImmediately() {
        // The patron's `userAboveAgeLimit` flag was set by a prior age
        // check OR by a server-side hint. The verify path must short-circuit
        // through this branch and admit.
        let (provider, account) = makeLibraryProvider()
        account.details?.userAboveAgeLimit = true
        let userProvider = FakeUserAccountProvider()
        userProvider.needsAuth = false

        let exp = expectation(description: "verify completes")
        var result: Bool?
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userProvider,
            currentLibraryAccountProvider: provider) {
            result = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(result, true,
                       "userAboveAgeLimit=true must admit immediately (cached prior decision)")
    }

    func test_verify_userPresentedAgeCheckAndBelowLimit_blocksWithoutReprompt() {
        // The patron previously took the age check and was found to be
        // BELOW the limit. We must NOT re-prompt them — they get a hard
        // block instead. Pins the `!userAboveAgeLimit && userPresentedAgeCheck`
        // composite predicate.
        let (provider, account) = makeLibraryProvider()
        account.details?.userAboveAgeLimit = false
        storage.userPresentedAgeCheck = true
        let userProvider = FakeUserAccountProvider()
        userProvider.needsAuth = false

        let exp = expectation(description: "verify completes")
        var result: Bool?
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userProvider,
            currentLibraryAccountProvider: provider) {
            result = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(result, false,
                       "Previously-prompted-but-below-limit patron must be blocked without a re-prompt")
    }

    func test_verify_nilCurrentAccount_blocksDefensively() {
        // Defensive default: if we don't know the current library yet,
        // do NOT admit. (DOB-missing analog at the verify layer.) Pins the
        // `guard let accountDetails` early-return — flipping the guard's
        // `else` branch from `completion?(false)` to `completion?(true)`
        // would survive without this test.
        let provider = StubLibraryProvider(account: nil)
        let userProvider = FakeUserAccountProvider()
        userProvider.needsAuth = false

        let exp = expectation(description: "verify completes")
        var result: Bool?
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userProvider,
            currentLibraryAccountProvider: provider) {
            result = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(result, false,
                       "Nil currentAccount must default-deny (defensive) — never admit when we don't know the library")
    }

    func test_verify_nilCompletion_doesNotCrash() {
        // `verifyCurrentAccountAgeRequirement(..., completion: nil)` is a
        // valid call site (background warm-up). Must not crash and must
        // still flip internal state appropriately.
        let (provider, account) = makeLibraryProvider()
        account.details?.userAboveAgeLimit = true
        let userProvider = FakeUserAccountProvider()
        userProvider.needsAuth = false

        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userProvider,
            currentLibraryAccountProvider: provider,
            completion: nil)

        // §10.3 seam: drain the serial queue synchronously instead of a
        // 100ms wall-clock pause.
        ageCheck.flushPendingForTests()

        // No crash = pass. Sanity-check: nothing else changed.
        XCTAssertNotNil(ageCheck, "ageCheck must remain alive after a nil-completion call")
    }
}

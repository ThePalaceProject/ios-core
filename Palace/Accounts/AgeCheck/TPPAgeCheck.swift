import Foundation

protocol TPPAgeCheckValidationDelegate: AnyObject {
    var minYear: Int { get }
    var currentYear: Int { get }
    var birthYearList: [Int] { get }
    var ageCheckCompleted: Bool { get set }

    func isValid(birthYear: Int) -> Bool

    func didCompleteAgeCheck(_ birthYear: Int)
    func didFailAgeCheck()
}

@objc protocol TPPAgeCheckVerifying {
    func verifyCurrentAccountAgeRequirement(userAccountProvider: TPPUserAccountProvider,
                                            currentLibraryAccountProvider: TPPCurrentLibraryAccountProvider,
                                            completion: ((Bool) -> Void)?)
}

@objc protocol TPPAgeCheckChoiceStorage {
    var userPresentedAgeCheck: Bool { get set }
}

@objcMembers final class TPPAgeCheck: NSObject, TPPAgeCheckValidationDelegate, TPPAgeCheckVerifying {

    // Members
    private let serialQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "org.thepalaceproject.palace").ageCheck")
    private var handlerList = [((Bool) -> ())]()
    private var isPresenting = false
    private let ageCheckChoiceStorage: TPPAgeCheckChoiceStorage
    var ageCheckCompleted: Bool = false

    let minYear: Int
    let currentYear: Int
    let birthYearList: [Int]

    init(ageCheckChoiceStorage: TPPAgeCheckChoiceStorage) {
        self.ageCheckChoiceStorage = ageCheckChoiceStorage
        minYear = 1900
        currentYear = Calendar.current.component(.year, from: Date())
        birthYearList = Array(minYear...currentYear)

        super.init()
    }

    func verifyCurrentAccountAgeRequirement(userAccountProvider: TPPUserAccountProvider,
                                            currentLibraryAccountProvider: TPPCurrentLibraryAccountProvider,
                                            completion: ((Bool) -> Void)?) {
        // Bucket A migration: the age check is a synchronous gate fired
        // before catalog rendering. The legacy implementation read
        // `currentLibraryAccountProvider.currentAccount?.details` and
        // either completed false (nil) or queued work on `serialQueue`.
        // Migrated path keeps the same ordering invariant by:
        //
        //   1. Fast-path: if state is `.detailsLoaded`, queue
        //      `continueAgeRequirementCheck` on `serialQueue` directly —
        //      same shape as the legacy `serialQueue.async { ... }`.
        //   2. Failure-path: if state is `.detailsFailed`, complete false
        //      on `serialQueue` — matches the legacy nil-details branch.
        //   3. Loading-path: only when state is `.notLoaded`,
        //      `.basicInfoLoaded`, or `.detailsLoading` do we spin up a
        //      `Task` to await `awaitReady()`. This is the new behavior
        //      the migration enables — the legacy code raced silently.
        //
        // Splitting fast-path from await-path preserves the queue
        // ordering tests (TPPAgeCheckTests.testAge*) rely on: when state
        // is already loaded, work goes onto `serialQueue` immediately so
        // `didCompleteAgeCheck`'s serial-queue async sees the queued
        // handlers, not an empty `handlerList`.
        guard let currentAccount = currentLibraryAccountProvider.currentAccount else {
            serialQueue.async { completion?(false) }
            return
        }

        switch currentAccount.loadState {
        case .detailsLoaded(let accountDetails):
            serialQueue.async { [weak self] in
                self?.continueAgeRequirementCheck(
                    accountDetails: accountDetails,
                    userAccountProvider: userAccountProvider,
                    completion: completion
                )
            }
        case .detailsFailed, .detailsEvicted:
            // Treat both terminals identically here: age-check cannot
            // proceed without `AccountDetails`, so a failed load AND an
            // evicted account both short-circuit to `completion(false)`.
            // Disambiguation matters for the auth-doc driver
            // (`AccountsManager.driveCurrentAccountAuthDocIfNeeded`), but
            // for the consumer side a missing details payload is a
            // missing details payload regardless of why.
            serialQueue.async { completion?(false) }
        case .notLoaded, .basicInfoLoaded, .detailsLoading:
            Task { [weak self] in
                let accountDetails: AccountDetails
                do {
                    accountDetails = try await currentAccount.awaitReady()
                } catch {
                    self?.serialQueue.async { completion?(false) }
                    return
                }
                self?.serialQueue.async {
                    self?.continueAgeRequirementCheck(
                        accountDetails: accountDetails,
                        userAccountProvider: userAccountProvider,
                        completion: completion
                    )
                }
            }
        }
    }

    /// Sync continuation of `verifyCurrentAccountAgeRequirement` running
    /// on the existing serial queue once `awaitReady()` has resolved.
    /// Splitting the body keeps the queue-isolated state mutations
    /// (`handlerList`, `isPresenting`) on the serial queue exactly as
    /// before — only the `details` read moved through the await boundary.
    private func continueAgeRequirementCheck(
        accountDetails: AccountDetails,
        userAccountProvider: TPPUserAccountProvider,
        completion: ((Bool) -> Void)?
    ) {
        if userAccountProvider.needsAuth == true || accountDetails.userAboveAgeLimit {
            completion?(true)
            return
        }

        if !accountDetails.userAboveAgeLimit && ageCheckChoiceStorage.userPresentedAgeCheck {
            completion?(false)
            return
        }

        // Queue the callback
        if let completion = completion {
            handlerList.append(completion)
        }

        // We're already presenting the age verification, return
        if isPresenting {
            return
        }

        let accountDetailsCompletion: ((Bool) -> Void) = { aboveAgeLimit in
            accountDetails.userAboveAgeLimit = aboveAgeLimit
        }
        handlerList.append(accountDetailsCompletion)

        // Perform age check presentation
        isPresenting = true
        presentAgeVerificationView()
    }

    fileprivate func presentAgeVerificationView() {
        DispatchQueue.main.async {
            let vc = TPPAgeCheckViewController(ageCheckDelegate: self)
            let navigationVC = UINavigationController(rootViewController: vc)
            TPPPresentationUtils.safelyPresent(navigationVC)
        }
    }

    func isValid(birthYear: Int) -> Bool {
        return birthYear >= minYear && birthYear <= currentYear
    }

    func didCompleteAgeCheck(_ birthYear: Int) {
        self.serialQueue.async { [weak self] in
            let aboveAgeLimit = Calendar.current.component(.year, from: Date()) - birthYear > 13
            self?.ageCheckChoiceStorage.userPresentedAgeCheck = true
            self?.isPresenting = false

            for handler in self?.handlerList ?? [] {
                handler(aboveAgeLimit)
            }
            self?.handlerList.removeAll()
        }
    }

    func didFailAgeCheck() {
        self.serialQueue.async { [weak self] in
            self?.isPresenting = false
            self?.ageCheckChoiceStorage.userPresentedAgeCheck = false
            self?.handlerList.removeAll()
        }
    }

    // MARK: - Test seam (§10.3)
    //
    // The private `serialQueue` schedules `verifyCurrentAccountAgeRequirement`,
    // `didCompleteAgeCheck`, and `didFailAgeCheck` all FIFO. Tests historically
    // relied on the implicit FIFO guarantee to assert post-conditions after
    // enqueueing two operations back-to-back, which works in practice but is
    // load-bearing on an implementation detail.
    //
    // `flushPendingForTests()` synchronously drains any work currently sitting
    // on `serialQueue`. Because the queue is serial, awaiting a `.sync` block
    // is sufficient: by the time it returns, every block enqueued via `.async`
    // earlier in program order has already executed.
    //
    // This is wrapped in `#if DEBUG` so the seam never ships in release
    // binaries. Production callers should never need a flush.
    #if DEBUG
    @objc func flushPendingForTests() {
        serialQueue.sync { }
    }
    #endif
}

import Foundation
import PalacePreferences
import PalaceLogging
import PalaceBookRegistry

/// Carries a `UserDefaults` across an isolation boundary, for the migrations.
///
/// `UserDefaults` is documented as thread-safe but is not marked `Sendable`, and
/// both migration entry points have to hand one to a `Task`. The box asserts only
/// what the class already guarantees; the alternative, `nonisolated(unsafe)`,
/// would silence the check rather than discharge it.
///
/// The guarantee is `UserDefaults`'s, not the box's. A **subclass** that adds
/// unsynchronized state of its own — a test spy that records reads, say — is not
/// made safe by being boxed, and the box cannot tell. That is why this is named
/// for the migrations rather than offered as a general utility: do not reach for
/// it elsewhere.
struct MigrationDefaultsBox: @unchecked Sendable {
    let wrapped: UserDefaults
    init(_ wrapped: UserDefaults) { self.wrapped = wrapped }
}

/// Test-only substitutions for the parts of `TPPMigrationManager.migrate` that
/// reach shared state.
///
/// `runMigrations` and `performPostUpdateTasksIfNeeded` reach
/// `AppContainer.production()`, the network queue and `UserDefaults.standard`;
/// the LCP keychain copy reaches the real Keychain. A test that wants to observe
/// what `migrate` actually does has to be able to stand those down, and there was
/// no seam at all — which is why nothing proved `migrate` still reached the LCP
/// migration.
///
/// Every field defaults to the production behaviour, so `migrate()` with no
/// argument is exactly what it always was.
struct MigrationSubstitutions {
    /// Replaces the versioned migration steps. Substituting these also suppresses
    /// `migrate`'s `appVersion` stamp — see `migrate` for why.
    var runMigrations: ((TPPSettings) -> Void)?
    /// Replaces the post-update recovery step.
    var performPostUpdateTasks: (() -> Void)?

    /// Replaces the LCP repository copy **and** names the store its completion
    /// flag is written to.
    ///
    /// One field, not two, because they are one decision. `runIfNeeded` sets the
    /// completion flag whenever the copy it was handed succeeds — including a
    /// substituted one — so a substituted copy plus a defaulted `.standard` store
    /// would permanently record the real SQLite→Keychain migration as done having
    /// copied nothing, and every existing LCP license would silently fall back to
    /// re-validating from its stored `.lcpl`. Joined, that is no longer something
    /// a caller can do by *omission* — writing `(defaults: .standard, work: { })`
    /// is still possible, but it has to be spelled out, and spelling it out is
    /// the point.
    ///
    /// `nil` means production: the real copy, flagged in `UserDefaults.standard`.
    var lcpMigration: (defaults: UserDefaults, work: @Sendable () async throws -> Void)?
}

/**
 Manages data migrations as they are needed throughout the app's life

 App version is cached in UserDefaults and last cached value is checked against current build version
 and updates are applied as required

 NetworkQueue migration is invoked from here, but the logic is self-contained in the NetworkQueue class.
 This is because DB-related operations should likely be scoped to that file in the event the DB framework or logic changes,
 that module would know best how to handle changes.
 */
class TPPMigrationManager: NSObject {
    private static let lastLaunchBuildKey = "TPPMigrationManager.lastLaunchBuild"

    /// Runs the launch-time migrations.
    ///
    /// Returns the LCP keychain migration's `Task`. Launch deliberately does not
    /// await it (see below), but discarding the handle meant no caller and no test
    /// could tell whether the migration had happened — or whether this method
    /// still started it at all.
    ///
    /// - Returns: the LCP migration task, or `nil` if the bundle version could not
    ///   be read and no migration was attempted.
    @discardableResult
    static func migrate(
        settings: TPPSettings = AppContainer.production().settings,
        substituting substitutions: MigrationSubstitutions = MigrationSubstitutions()
    ) -> Task<Void, Never>? {
        // Fetch target version
        guard let infoDictionary = Bundle.main.infoDictionary,
              let targetVersion = infoDictionary["CFBundleShortVersionString"] as? String else {
            Log.error(#file, "Unable to read CFBundleShortVersionString from Info.plist")
            return nil
        }

        let ranTheRealMigrations = substitutions.runMigrations == nil

        if let substitute = substitutions.runMigrations {
            substitute(settings)
        } else {
            runMigrations(settings: settings)
        }

        if let substitute = substitutions.performPostUpdateTasks {
            substitute()
        } else {
            performPostUpdateTasksIfNeeded()
        }

        // Readium 3.8.0+: carry existing LCP licenses/passphrases from the
        // deprecated SQLite store into the Keychain store. Idempotent and gated by
        // its own flag.
        //
        // NOT awaited: launch must not block on a Keychain walk. KNOWN RACE, see
        // docs/architecture/lcp-device-id-migration-validation.md — on the first
        // launch after an in-place upgrade a patron can open an LCP book before
        // this finishes, `LCPLibraryService` then builds its repositories over an
        // empty Keychain store and the license re-validates from its stored
        // `.lcpl`. Closing it needs `LCPLibraryService`'s synchronous lazy service
        // build to become awaitable, which is a larger change than this one.
        let defaultsBox = MigrationDefaultsBox(substitutions.lcpMigration?.defaults ?? .standard)
        let work = substitutions.lcpMigration?.work
        let task = Task {
            await runLCPKeychainMigration(defaults: defaultsBox.wrapped, work: work)
        }

        // The stamp records "the migrations for this version have run". If they
        // were substituted they have not, so stamping would mark a real install
        // migrated without migrating it — the footgun a bare override invites.
        // Refusing to stamp makes that unrepresentable rather than documented.
        if ranTheRealMigrations {
            settings.appVersion = targetVersion
        }

        return task
    }

    /// A no-op in builds without LCP, so the call site in `migrate` is
    /// unconditional and both build configurations exercise the same control flow.
    private static func runLCPKeychainMigration(
        defaults: UserDefaults,
        work: (@Sendable () async throws -> Void)?
    ) async {
        #if LCP
        await LCPKeychainMigration.runIfNeeded(defaults: defaults, migrate: work)
        #endif
    }

    /// Detects when the app binary has been updated (different build number from last launch)
    /// and performs recovery tasks to prevent "credentials invalid" / "can't open book" errors.
    private static func performPostUpdateTasksIfNeeded() {
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let lastBuild = UserDefaults.standard.string(forKey: lastLaunchBuildKey)

        defer {
            UserDefaults.standard.set(currentBuild, forKey: lastLaunchBuildKey)
        }

        guard let lastBuild, lastBuild != currentBuild else {
            return
        }

        Log.info(#file, "App updated from build \(lastBuild) to \(currentBuild) — running post-update recovery")

        // Refresh auth tokens proactively so users don't see "credentials invalid"
        // after an update that changed nothing about their account
        let userAccount = AppContainer.production().accountsManager.currentUserAccount
        if userAccount.hasCredentials(), userAccount.authTokenNearExpiry || userAccount.authTokenHasExpired {
            Log.info(#file, "Post-update: auth token expired/near-expiry — triggering refresh")
            AppContainer.production().networkExecutor.refreshTokenAndResume(task: nil)
        }

        // Validate downloaded content is still accessible
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
            (AppContainer.production().bookRegistry as? TPPBookRegistry)?.validateDownloadedContent()
        }
    }

    /// Compares app versions.
    ///
    /// - Note: An empty `a` version is considered "less than" a non-empty `b`.
    ///
    /// - Parameters:
    ///   - a: An array of integers expressing a version number.
    ///   - b: An array of integers expressing a version number.
    /// - Returns: `true` if version `a` is anterior to version `b`, or if `a` is
    /// empty and `b` is not, or if `a` and `b` coincide except `b` has more
    /// components than `a` (e.g. 1.2 vs 1.2.1).
    static func version(_ a: [Int], isLessThan b: [Int]) -> Bool {
        var i = 0
        while i < a.count && i < b.count {
            guard a[i] == b[i] else {
                return a[i] < b[i]
            }

            i += 1
        }

        // e.g.: 1.1 < 1.1.x — check if any remaining component in b is non-zero
        return a.count < b.count && b[i...].contains(where: { $0 > 0 })
    }
}

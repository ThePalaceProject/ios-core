import Foundation

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

    @objc static func migrate(settings: TPPSettings = .shared) {
        // Fetch target version
        let targetVersion = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String

        runMigrations()
        performPostUpdateTasksIfNeeded()

        // Update app version
        settings.appVersion = targetVersion
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
        let userAccount = TPPUserAccount.sharedAccount()
        if userAccount.hasCredentials(), userAccount.authTokenNearExpiry || userAccount.authTokenHasExpired {
            Log.info(#file, "Post-update: auth token expired/near-expiry — triggering refresh")
            TPPNetworkExecutor.shared.refreshTokenAndResume(task: nil)
        }

        // Validate downloaded content is still accessible
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
            TPPBookRegistry.shared.validateDownloadedContent()
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

//
//  ManagedLibraryPreconfigurator.swift
//  Palace
//
//  PP-5070 spike — applies the MDM-supplied library pre-selection at launch.
//
//  The five side effects below are not a new way to select a library: they are
//  exactly what the first-run picker's selection callback already performs in
//  `TPPAppDelegate.presentFirstRunFlowIfNeeded`. Reusing that contract is
//  deliberate — a second, subtly different selection path is how the app ends
//  up with a library that is current but has no feed URL.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// What a launch-time pre-configuration attempt concluded.
enum ManagedLibraryDecision: Equatable {
    /// No MDM configuration, or none naming a library.
    case noConfiguration
    /// This exact configuration value was applied on an earlier launch.
    case alreadyApplied
    /// A library is configured but the registry has not loaded yet; the caller
    /// should ask again once it has.
    case registryNotLoaded
    /// A library is configured, the registry has loaded, and nothing in it
    /// matches — a wrong identifier, or a library absent from the feed the app
    /// reads.
    case unresolved
    /// Apply this account as the current library.
    case apply(uuid: String)
}

/// The launch-path side effects `ManagedLibraryPreconfigurator` performs,
/// bundled as closures so a test observes their order and arguments.
///
/// Mirrors `AccountSwitchDependencies`: a frozen bundle, `.production` in the
/// app, recorded under test.
struct ManagedLibraryApplyDependencies {
    var addedLibraryIds: () -> [String]
    var setAddedLibraryIds: ([String]) -> Void
    var setMainFeedURL: (URL) -> Void
    var selectLibrary: (Account) -> Void
    var loadAuthenticationDocument: (Account) -> Void
    var announceLibraryChanged: () -> Void
}

/// Reads the account registry on behalf of the preconfigurator.
///
/// `AccountsManager` conforms below; the protocol exists so the decision can be
/// tested against a registry that is empty, still loading, or holding a
/// specific fixture without constructing the real manager.
protocol ManagedLibraryRegistryReading: AnyObject {
    var registryHasLoaded: Bool { get }
    func managedLibraryAccount(uuid: String) -> Account?
    func managedLibraryAccounts() -> [Account]
}

extension AccountsManager: ManagedLibraryRegistryReading {
    var registryHasLoaded: Bool { accountsHaveLoaded }
    func managedLibraryAccount(uuid: String) -> Account? { account(uuid) }
    func managedLibraryAccounts() -> [Account] { accounts() }
}

/// Applies an MDM-supplied library pre-selection, at most once per
/// configuration VALUE.
///
/// ## Why apply-once-per-value
///
/// Four situations the ticket asks about fall out of that one rule, which is
/// why it is the rule rather than four special cases:
///
/// - **App update.** The stored fingerprint survives the update, so nothing
///   re-applies and a student's own library stays selected.
/// - **A student who removed the configured library.** Same fingerprint, so the
///   app does not put it back. Re-applying forever would mean fighting the
///   user, which the partner explicitly did not ask for.
/// - **An MDM that changes the configuration.** New value, new fingerprint, so
///   it applies — an administrator can re-point a device mid-year, and can move
///   a device between division groups.
/// - **A re-imaged or reinstalled device.** Defaults are gone with the app
///   container, so the fingerprint is gone too and the configuration applies
///   again. This is the case that a naive "only on first launch ever" flag gets
///   wrong in the other direction.
final class ManagedLibraryPreconfigurator {

    /// Where the last-applied fingerprint is persisted. App-private and
    /// deliberately not in `TPPSettings`: it is bookkeeping for this mechanism,
    /// not a user-facing preference.
    static let appliedFingerprintKey = "TPPManagedLibraryAppliedFingerprint"

    private let defaults: UserDefaults
    private let registry: any ManagedLibraryRegistryReading
    private let dependencies: ManagedLibraryApplyDependencies

    init(
        defaults: UserDefaults,
        registry: any ManagedLibraryRegistryReading,
        dependencies: ManagedLibraryApplyDependencies
    ) {
        self.defaults = defaults
        self.registry = registry
        self.dependencies = dependencies
    }

    /// Pure decision. Every reachable combination of the four inputs is
    /// asserted cell-by-cell in `ManagedLibraryPreconfiguratorTests`.
    ///
    /// `resolvedUUID` is a closure, not a value, so resolution — which walks
    /// the registry — is not performed for the cells that never reach it.
    static func decide(
        configuration: ManagedLibraryPreconfiguration?,
        lastAppliedFingerprint: String?,
        registryHasLoaded: Bool,
        resolvedUUID: () -> String?
    ) -> ManagedLibraryDecision {
        guard let configuration else { return .noConfiguration }
        // Checked BEFORE the registry state so a configuration already honored
        // does not keep the caller re-asking on every catalog load.
        if configuration.fingerprint == lastAppliedFingerprint { return .alreadyApplied }
        guard registryHasLoaded else { return .registryNotLoaded }
        guard let uuid = resolvedUUID() else { return .unresolved }
        return .apply(uuid: uuid)
    }

    /// Finds the configured library in the loaded registry.
    ///
    /// Identifier first (exact, O(1) through the registry index), catalog URL
    /// second. An identifier that resolves to nothing does NOT fall through to
    /// the URL: an administrator who supplied both and mistyped the identifier
    /// should see the configuration fail rather than quietly land on whatever
    /// the URL matched.
    static func resolve(
        configuration: ManagedLibraryPreconfiguration,
        registry: any ManagedLibraryRegistryReading
    ) -> Account? {
        if let id = configuration.libraryId {
            return registry.managedLibraryAccount(uuid: id)
        }
        guard let configuredURL = configuration.catalogURL else { return nil }
        return registry.managedLibraryAccounts().first {
            ManagedAppConfiguration.catalogURL($0.catalogUrl, matches: configuredURL)
        }
    }

    /// Resolves the add-without-selecting list, keeping what the registry knows
    /// and reporting the rest.
    ///
    /// Partial failure is tolerated HERE and nowhere else: an extra library the
    /// registry has not heard of should not stop the device being pointed at
    /// the right catalog. A missing SELECTED library is different — see
    /// `applyIfNeeded`.
    static func resolveAdditional(
        configuration: ManagedLibraryPreconfiguration,
        registry: any ManagedLibraryRegistryReading
    ) -> (resolved: [Account], missing: [String]) {
        var resolved: [Account] = []
        var missing: [String] = []
        for uuid in configuration.additionalLibraryIds {
            if let account = registry.managedLibraryAccount(uuid: uuid) {
                resolved.append(account)
            } else {
                missing.append(uuid)
            }
        }
        return (resolved, missing)
    }

    /// What `applyIfNeeded()` WOULD conclude, without applying anything.
    ///
    /// Exists for the Testing screen's read-out. It must be separate from
    /// `applyIfNeeded()` rather than a flag on it, because a diagnostic that
    /// selects a library as a side effect of being read is not a diagnostic.
    func inspect() -> ManagedLibraryDecision {
        let configuration = ManagedAppConfiguration.libraryPreconfiguration(defaults: defaults)
        return Self.decide(
            configuration: configuration,
            lastAppliedFingerprint: defaults.string(forKey: Self.appliedFingerprintKey),
            registryHasLoaded: registry.registryHasLoaded,
            resolvedUUID: {
                guard let configuration else { return nil }
                return Self.resolve(configuration: configuration, registry: registry)?.uuid
            }
        )
    }

    /// The configuration currently in `UserDefaults`, parsed — nil when the app
    /// is unmanaged or the payload names no usable library.
    var currentConfiguration: ManagedLibraryPreconfiguration? {
        ManagedAppConfiguration.libraryPreconfiguration(defaults: defaults)
    }

    /// The fingerprint of the configuration already applied on this install, if
    /// any. Surfaced so the Testing screen can explain an `.alreadyApplied`.
    var appliedFingerprint: String? {
        defaults.string(forKey: Self.appliedFingerprintKey)
    }

    /// Applies the configuration if there is one to apply, and reports what it
    /// concluded. Safe to call repeatedly — every launch, and again after each
    /// catalog load.
    @discardableResult
    func applyIfNeeded() -> ManagedLibraryDecision {
        let parse = ManagedAppConfiguration.parse(defaults: defaults)
        for warning in parse.warnings {
            Log.warn(#file, "Managed configuration: \(warning)")
        }

        let configuration = parse.configuration
        var resolved: Account?
        let decision = Self.decide(
            configuration: configuration,
            lastAppliedFingerprint: defaults.string(forKey: Self.appliedFingerprintKey),
            registryHasLoaded: registry.registryHasLoaded,
            resolvedUUID: {
                guard let configuration else { return nil }
                resolved = Self.resolve(configuration: configuration, registry: registry)
                return resolved?.uuid
            }
        )

        switch decision {
        case .noConfiguration, .alreadyApplied, .registryNotLoaded:
            return decision
        case .unresolved:
            // Only the SELECTED library reaches here. Additional libraries that
            // do not resolve are reported but do not block the selection —
            // being pointed at the right catalog matters more than carrying a
            // complete list.
            Log.warn(
                #file,
                "Managed configuration names a library to select that is not in the loaded "
                + "registry (\(configuration?.fingerprint ?? "-")) — leaving library selection "
                + "to the user."
            )
            return decision
        case .apply:
            guard let account = resolved, let configuration else { return .unresolved }
            let extra = Self.resolveAdditional(configuration: configuration, registry: registry)
            for uuid in extra.missing {
                Log.warn(#file, "Managed configuration: additional library not in registry: \(uuid)")
            }
            apply(account, alongside: extra.resolved, fingerprint: configuration.fingerprint)
            return decision
        }
    }

    /// The five picker-equivalent side effects, in the picker's order, then the
    /// fingerprint write.
    ///
    /// The fingerprint is written LAST and only after the library is actually
    /// current: a crash partway through must leave the device unconfigured and
    /// retryable, never marked done with nothing selected.
    ///
    /// `alongside` libraries are ADDED in the same single list write and never
    /// selected, so the call order the contract pins is unchanged no matter how
    /// many libraries the payload carries.
    private func apply(_ account: Account, alongside extras: [Account], fingerprint: String) {
        var ids = dependencies.addedLibraryIds()
        let before = ids
        for uuid in [account.uuid] + extras.map(\.uuid) where !ids.contains(uuid) {
            ids.append(uuid)
        }
        if ids != before {
            dependencies.setAddedLibraryIds(ids)
        }
        if let catalogUrl = account.catalogUrl, let url = URL(string: catalogUrl) {
            dependencies.setMainFeedURL(url)
        }
        dependencies.selectLibrary(account)
        dependencies.loadAuthenticationDocument(account)
        dependencies.announceLibraryChanged()
        defaults.set(fingerprint, forKey: Self.appliedFingerprintKey)
        Log.info(
            #file,
            "Applied managed library configuration: selected \(account.name) (\(account.uuid))"
            + (extras.isEmpty ? "" : ", added \(extras.count) more")
        )
    }
}

/// What the caller should do when the watcher reports a decision AFTER launch.
///
/// A separate concern from `ManagedLibraryLaunchStep`, which answers the
/// question at launch. This answers it once the picker may already be on
/// screen, where the options are different: take the picker away, keep trying,
/// or leave well alone.
enum ManagedLibraryWatchAction: Equatable {
    /// A library became current. Any picker on screen is now wrong.
    case dismissPicker
    /// A configuration is real but not yet actionable. Keep listening for the
    /// registry rather than treating a slow network as a verdict.
    case keepTrying
    /// Nothing to act on.
    case doNothing
}

extension ManagedLibraryPreconfigurator {

    /// Pure mapping from a post-launch decision to what the caller should do.
    ///
    /// Extracted so the rule is testable: it would otherwise live inside
    /// `TPPAppDelegate`, which has no test seam, and this is the rule that
    /// decides whether a student keeps staring at a library picker.
    static func watchAction(for decision: ManagedLibraryDecision) -> ManagedLibraryWatchAction {
        switch decision {
        case .apply:
            return .dismissPicker
        case .registryNotLoaded, .unresolved:
            // The configuration is real; the app just cannot act on it yet.
            // `.unresolved` is included deliberately — on a cold launch the
            // registry the app starts from is a build-time snapshot that may
            // not contain the configured library at all, so "not found" and
            // "not loaded yet" are the same situation seen a moment apart.
            return .keepTrying
        case .noConfiguration, .alreadyApplied:
            return .doNothing
        }
    }
}

/// What the launch path should do next, given a pre-configuration decision.
///
/// Separated from `TPPAppDelegate` so the bounded wait is assertable without
/// UIKit or a real launch.
enum ManagedLibraryLaunchStep: Equatable {
    /// A library was selected; do not ask the student anything.
    case libraryApplied
    /// Ask the student to pick a library, as the app has always done.
    case presentPicker
    /// A managed configuration is pending. Say nothing yet and re-attempt when
    /// the registry next changes.
    case waitForRegistry
}

extension ManagedLibraryPreconfigurator {

    /// How long a managed install will wait for its configured library to turn
    /// up in the registry before falling back to the picker.
    ///
    /// The wait exists because the registry the app hydrates on cold first
    /// launch is `bundled_registry.json`, a BUILD-TIME cut — the 2026-07-13
    /// snapshot shipping today holds 1,142 libraries and contains none of the
    /// partner's three, whose registry entries postdate it. So on the one launch
    /// that matters, resolving the configured identifier against the loaded set
    /// fails, and the network crawl that would resolve it lands seconds later.
    /// Showing the picker in that window would defeat the whole feature while
    /// looking, from a log, like the configuration was wrong.
    ///
    /// The wait is bounded because a genuinely bad identifier must still end in
    /// an app the student can use. Fifteen seconds is long enough for the
    /// first-page fetch on a school network and short enough that a misconfigured
    /// device is not mistaken for a broken one.
    static let registryWaitLimit: TimeInterval = 15

    /// Pure launch-step decision. Asserted cell-by-cell against every
    /// `ManagedLibraryDecision` on both sides of the deadline.
    static func launchStep(
        for decision: ManagedLibraryDecision,
        elapsed: TimeInterval,
        limit: TimeInterval = registryWaitLimit
    ) -> ManagedLibraryLaunchStep {
        switch decision {
        case .apply:
            return .libraryApplied
        case .noConfiguration, .alreadyApplied:
            // No managed intent to honor (or it is already honored) — the picker
            // decision is the app's pre-existing one, with no wait.
            return .presentPicker
        case .registryNotLoaded, .unresolved:
            return elapsed < limit ? .waitForRegistry : .presentPicker
        }
    }
}

// MARK: - Production wiring

extension ManagedLibraryApplyDependencies {

    /// The live bundle. Each closure is the corresponding line of the first-run
    /// picker's selection callback, so the two paths cannot drift in behavior
    /// without drifting visibly here.
    static func production(appContainer: AppContainer = .production()) -> ManagedLibraryApplyDependencies {
        let settings = appContainer.settings
        let accountsManager = appContainer.accountsManager
        return ManagedLibraryApplyDependencies(
            addedLibraryIds: { settings.settingsAccountIdsList },
            setAddedLibraryIds: { settings.settingsAccountIdsList = $0 },
            setMainFeedURL: { settings.accountMainFeedURL = $0 },
            selectLibrary: { accountsManager.currentAccount = $0 },
            loadAuthenticationDocument: { $0.loadAuthenticationDocument { _ in } },
            announceLibraryChanged: {
                NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
            }
        )
    }
}

extension ManagedLibraryPreconfigurator {

    /// The live preconfigurator, reading `UserDefaults.standard` — the store an
    /// MDM actually writes its configuration into.
    static func production(appContainer: AppContainer = .production()) -> ManagedLibraryPreconfigurator {
        ManagedLibraryPreconfigurator(
            defaults: .standard,
            registry: appContainer.accountsManager,
            dependencies: .production(appContainer: appContainer)
        )
    }
}

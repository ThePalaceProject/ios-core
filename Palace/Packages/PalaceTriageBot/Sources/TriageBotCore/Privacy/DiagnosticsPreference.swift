import Foundation

/// The patron's "Include diagnostics" choice (PP-4809). Default ON — the bot is
/// most useful to support with the full context — but a privacy-conscious user
/// can turn it OFF, in which case only the app version / OS / device basics are
/// captured: no logs, no library, no network, no barcode.
public protocol DiagnosticsPreference: Sendable {
    var includeDiagnostics: Bool { get }
}

/// UserDefaults-backed preference. Foundation-only so it lives in Core and is
/// testable under macOS `swift test`. Absent key reads as `true` (default ON).
public final class UserDefaultsDiagnosticsPreference: DiagnosticsPreference, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "triagebot.includeDiagnostics") {
        self.defaults = defaults
        self.key = key
    }

    public var includeDiagnostics: Bool {
        // `object(forKey:)` distinguishes "never set" (→ default ON) from an
        // explicit false.
        defaults.object(forKey: key) as? Bool ?? true
    }

    public func setIncludeDiagnostics(_ include: Bool) {
        defaults.set(include, forKey: key)
    }
}

/// Wraps a full ContextProvider and honors the diagnostics preference: when ON
/// it delegates to the full capture; when OFF it returns a minimal snapshot
/// WITHOUT invoking the full provider at all (so no logs are read, no network
/// probe runs, no Palace account fields are touched). PP-4809.
public final class DiagnosticsGatingContextProvider: ContextProvider {
    private let full: ContextProvider
    private let minimal: @Sendable () async -> ContextSnapshot
    private let preference: DiagnosticsPreference

    /// - Parameters:
    ///   - full: the real provider, called only when diagnostics are ON.
    ///   - minimal: cheap app/OS/device-only snapshot, returned when OFF.
    ///   - preference: the persisted include/exclude choice.
    public init(
        full: ContextProvider,
        minimal: @escaping @Sendable () async -> ContextSnapshot,
        preference: DiagnosticsPreference
    ) {
        self.full = full
        self.minimal = minimal
        self.preference = preference
    }

    public func captureSnapshot() async -> ContextSnapshot {
        preference.includeDiagnostics ? await full.captureSnapshot() : await minimal()
    }
}

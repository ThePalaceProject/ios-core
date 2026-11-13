//
//  LCPKeychainMigration.swift
//  Palace
//
//  One-time migration of LCP licenses + passphrases from the deprecated
//  Readium `ReadiumAdapterLCPSQLite` repositories (Readium ≤ 3.7) to the
//  built-in Keychain repositories introduced in Readium 3.8.0. Idempotent and
//  gated by a `UserDefaults` flag. A license not yet migrated is re-validated
//  from its stored `.lcpl` on next open, so a missed run never loses access.
//

#if LCP

import Foundation
import ReadiumLCP
import ReadiumAdapterLCPSQLite
import PalaceLogging

enum LCPKeychainMigration {
    /// `UserDefaults` key recording that the SQLite→Keychain migration has
    /// completed successfully. Once set, the migration is never re-run.
    static let didMigrateKey = "TPP.lcpKeychainMigrationCompleted"

    /// Serializes concurrent `runIfNeeded` callers onto a single migration, **per
    /// store**.
    ///
    /// The flag is written only after the copy finishes, and
    /// `TPPMigrationManager.migrate` does not await the run, so overlapping calls
    /// would otherwise make concurrent passes over the Keychain. A late caller
    /// waits for the running migration instead of proceeding over a
    /// half-populated store.
    ///
    /// Keyed by `UserDefaults` object identity so a caller with a different store
    /// is not absorbed into an unrelated flight. Production only passes
    /// `.standard`. (PP-5091)
    private static let singleFlight = SingleFlight()

    private actor SingleFlight {
        private var inFlight: [ObjectIdentifier: Task<Void, Never>] = [:]

        func run(for store: ObjectIdentifier, _ body: @escaping @Sendable () async -> Void) async {
            if let existing = inFlight[store] {
                await existing.value
                return
            }
            let task = Task(operation: body)
            inFlight[store] = task
            await task.value
            inFlight[store] = nil
        }
    }

    /// Runs the migration once, if it hasn't already completed.
    ///
    /// The actual repository copy is injected as `migrate` so the gating
    /// behavior can be unit-tested without touching the real Keychain.
    ///
    /// - The flag is set **only on success**. If the copy throws (e.g. a
    ///   transient Keychain error) the flag is left unset so the next launch
    ///   retries — the underlying Readium `migrate(to:)` is idempotent. A copy
    ///   that failed half way is left in place for the same reason.
    /// - A caller that joined a flight which then failed returns without
    ///   retrying in that launch; the unset flag means the next launch tries
    ///   again (an immediate retry usually hits the same locked Keychain).
    /// - Note: `defaults` deliberately has no default value. This layer writes
    ///   the completion flag whenever the copy it was handed succeeds, so with
    ///   `= .standard` a test's `runIfNeeded(migrate: { })` would mark the real
    ///   migration done having copied nothing.
    static func runIfNeeded(
        defaults: UserDefaults,
        migrate: (@Sendable () async throws -> Void)? = nil
    ) async {
        guard !defaults.bool(forKey: didMigrateKey) else { return }

        let defaultsBox = MigrationDefaultsBox(defaults)
        await singleFlight.run(for: ObjectIdentifier(defaults)) {
            await performIfStillNeeded(defaults: defaultsBox.wrapped, migrate: migrate)
        }
    }

    /// The copy itself, run at most once at a time by `singleFlight`.
    ///
    /// The gate is re-read here and not only in `runIfNeeded`: several callers can
    /// pass the outer check before any of them writes the flag, and only the one
    /// that wins the single flight may copy.
    private static func performIfStillNeeded(
        defaults: UserDefaults,
        migrate: (@Sendable () async throws -> Void)?
    ) async {
        guard !defaults.bool(forKey: didMigrateKey) else { return }

        do {
            if let migrate {
                try await migrate()
            } else {
                try await performReadiumMigration()
            }
            defaults.set(true, forKey: didMigrateKey)
            Log.info(#file, "LCP SQLite→Keychain migration completed")
        } catch {
            Log.warn(#file, "LCP SQLite→Keychain migration did not complete (will retry next launch): \(error.localizedDescription)")
        }
    }

    /// Copies all stored licenses and passphrases from the legacy SQLite
    /// repositories into the Keychain repositories. A fresh install has no
    /// legacy database, in which case the copy is a no-op.
    ///
    /// Marked `deprecated` so the *intentional* reads of the deprecated
    /// `ReadiumAdapterLCPSQLite` repositories don't emit warnings — reading
    /// the legacy store is the entire point of a one-time migration. This
    /// function (and the `ReadiumAdapterLCPSQLite` dependency) should be
    /// removed in a follow-up once migration adoption is complete.
    @available(*, deprecated, message: "Intentionally reads the deprecated SQLite store for one-time migration.")
    private static func performReadiumMigration() async throws {
        let sqliteLicenses = try LCPSQLiteLicenseRepository()
        let sqlitePassphrases = try LCPSQLitePassphraseRepository()
        let keychainLicenses = LCPKeychainLicenseRepository()
        let keychainPassphrases = LCPKeychainPassphraseRepository()

        // Readium's `migrate(to:)` returns whether any rows were copied; we
        // intentionally discard it — the migration is flag-gated and
        // idempotent, so "did anything move" doesn't affect control flow.
        _ = try await sqliteLicenses.migrate(to: keychainLicenses)
        _ = try await sqlitePassphrases.migrate(to: keychainPassphrases)
    }
}

#endif

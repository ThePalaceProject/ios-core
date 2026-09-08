//
//  LCPKeychainMigration.swift
//  Palace
//
//  One-time migration of LCP licenses + passphrases from the deprecated
//  Readium `ReadiumAdapterLCPSQLite` repositories (Readium ≤ 3.7) to the
//  built-in Keychain repositories introduced in Readium 3.8.0. The Keychain
//  store is more secure, survives app reinstalls, and is iCloud-syncable.
//
//  The migration is idempotent and gated by a `UserDefaults` flag so it runs
//  at most once per install. It degrades gracefully: a license that hasn't
//  been migrated yet is simply re-validated from its stored `.lcpl` the next
//  time the book is opened, so a missed or delayed run never loses access.
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
    /// The flag below is written only *after* the copy finishes, so the gate is
    /// open for the copy's whole duration and every caller arriving in that window
    /// clears it. `TPPMigrationManager.migrate` starts one without awaiting it, so
    /// two calls to `migrate` — a relaunch path, or a test suite driving it more
    /// than once — overlap, and Readium's `migrate(to:)` then makes two concurrent
    /// passes over the Keychain. It is idempotent, so that is not corrupting, but
    /// it is not a state anything here reasons about either.
    ///
    /// A late caller waits for the running migration rather than starting a second
    /// one, so it never proceeds over a half-populated store.
    ///
    /// **Keyed by store identity, not global.** Absorbing a caller that carries a
    /// *different* `UserDefaults` into an unrelated flight would silently skip its
    /// work and return as if it had run. Keying is by object identity, so two
    /// instances opened on the same suite name get independent flights — imprecise
    /// in principle, but production only ever passes `.standard`, which is a
    /// singleton, so the production flight is a single one. (PP-5091)
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
    /// - A caller that joined a flight which then **failed** returns without
    ///   retrying inside that launch. It is not told the migration succeeded —
    ///   nothing here returns success — and the unset flag means the next launch
    ///   tries again. Retrying immediately would repeat a copy that just failed,
    ///   usually because the Keychain is locked, and would not be more likely to
    ///   work.
    /// - Note: `defaults` has deliberately **no default value**. This is the layer
    ///   that writes the completion flag, and it writes it whenever the copy it
    ///   was handed succeeds — including a substituted one. With `= .standard`,
    ///   `runIfNeeded(migrate: { })` compiled and recorded the real
    ///   SQLite→Keychain migration as done having copied nothing, stranding every
    ///   existing licence on re-validation from its `.lcpl`. Every call site
    ///   already passed `defaults:` explicitly, so the default was dead weight
    ///   whose only effect was to make that mistake available.
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
    /// pass the outer check before any of them writes the flag, and the one that
    /// wins the single flight must be the only one that copies. Checking once,
    /// outside, is exactly the bug.
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

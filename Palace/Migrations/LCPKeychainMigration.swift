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

    /// Runs the migration once, if it hasn't already completed.
    ///
    /// The actual repository copy is injected as `migrate` so the gating
    /// behavior can be unit-tested without touching the real Keychain.
    ///
    /// - The flag is set **only on success**. If the copy throws (e.g. a
    ///   transient Keychain error) the flag is left unset so the next launch
    ///   retries — the underlying Readium `migrate(to:)` is idempotent.
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        migrate: (() async throws -> Void)? = nil
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

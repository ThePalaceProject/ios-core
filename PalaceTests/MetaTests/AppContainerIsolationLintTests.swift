//
//  AppContainerIsolationLintTests.swift
//  PalaceTests
//
//  Lint enforcement for swarm_47883816 work package A: `AppContainer.production()`
//  reads in test bodies are banned outside an explicit whitelist + deferred
//  list. The lint is the durable change; the migration is the cleanup.
//
//  Failure mode this lint closes
//  =============================
//  Before this lint, any new test could reach into `AppContainer.production()`
//  unobserved. The factory `makeTestAppContainer()` is a structural seam —
//  but a seam only matters if the suite refuses to land regressions back to
//  the old pattern. This file IS that refusal.
//
//  Rules
//  =====
//   1. `testNoAppContainerProductionOutsideWhitelist` — scans every Swift
//      file under `PalaceTests/` and fails if a `AppContainer.production()`
//      reference appears outside:
//
//        a) The whitelist (5 production-identity-pinning files where
//           reading `production()` IS the test contract).
//        b) The deferred list at `.forgeos/swarms/swarm_47883816/A-deferred-files.txt`
//           (~55 files queued for a follow-up shrink swarm).
//        c) A line carrying `// MIGRATED-DEFERRED:` inline marker
//           (per-line exemption for individual sites where production()
//           resolution IS the SUT — e.g. `_testContainerOverride` wiring
//           tests).
//        d) A non-code comment line (lines whose first non-whitespace
//           characters are `//` or `///`). Documentation comments that
//           reference `AppContainer.production()` are not lint-relevant.
//
//   2. `testLintCatchesSyntheticViolation` — feeds the lint a synthetic
//      violating string to prove the detector actually catches the pattern.
//      Without this self-test, a refactor that silently broke the regex
//      would pass-by-default.
//
//  Why a Swift XCTest rather than a shell grep gate
//  ================================================
//  Hook-based shell scripts have two failure modes the harness has seen
//  before:
//    - They no-op gracefully on missing dependencies (forge-os scripts).
//    - They're easy to bypass via `--no-verify`.
//  An XCTest that runs in the same xctest process as the suite itself
//  cannot be bypassed by a hook flag; if the test runs, the rule runs.
//
//  swarm_47883816 work package A.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import XCTest

final class AppContainerIsolationLintTests: XCTestCase {

  // MARK: - Resolution

  /// `PalaceTests/` resolved relative to this file's location.
  private static let palaceTestsRoot: URL = {
    URL(fileURLWithPath: #file)
      .deletingLastPathComponent()  // MetaTests/
      .deletingLastPathComponent()  // PalaceTests/
  }()

  /// Repo root — two directories above `PalaceTests/`.
  /// Used to resolve `.forgeos/swarms/swarm_47883816/A-deferred-files.txt`.
  private static let repoRoot: URL = {
    palaceTestsRoot.deletingLastPathComponent()
  }()

  /// Whitelist — files allowed to reference `AppContainer.production()`
  /// for documented reasons. Each entry is a path RELATIVE to `palaceTestsRoot`.
  ///
  /// **Adding a file to this list requires a one-paragraph rationale in
  /// the swarm_47883816 plan or contract.** The default answer is "no — use
  /// `makeTestAppContainer()` instead."
  private static let whitelist: Set<String> = [
    // Bootstrap path; comment-only references to production() in
    // the principal-class init's doc comments.
    "PalaceTestSetup.swift",
    // Tests the observer's reset of production() identity — must
    // observe the cached struct directly to verify the reset.
    "PalaceTestSetupObservationTests.swift",
    // Comment-only reference inside the mock-implementation rationale.
    "Mocks/AccountTestSeeder.swift",
    // Comment-only ref describing the AdobeDRMService internal
    // resolution path.
    "DRM/AdobeActivationTests.swift",
    // Factory implementation — the file IS the seam.
    "Support/TestAppContainerFactory.swift",
    // Factory behavioural-contract tests — assert
    // `AppContainer.production().accountsManager` identity survives a
    // factory call (the seam's whole point). Reading production() is
    // load-bearing here.
    "Support/TestAppContainerFactoryTests.swift",
    // Lint test source itself — references the banned pattern in
    // string literals for detection. Banning it would be self-defeating.
    "MetaTests/AppContainerIsolationLintTests.swift",
    // Sibling meta-lint added by E (TearDown rule) — contains polluter
    // substrings as test fixtures for its own scanner. Self-referential
    // exemption mirrors the rule above.
    "MetaTests/TearDownRequiredLintTests.swift",
    // C-owned sibling factory tests — until C's package commits, the
    // file references production() in its TPPUserAccount cache-isolation
    // assertions. Folded into whitelist by orchestrator E post-C.
    "Support/TPPUserAccountTestFactoryTests.swift",
    // KeychainAvailability-gated isolation tests. The Keychain-bound
    // path requires the production singleton graph; these tests
    // already use `KeychainAvailability` guards for CI.
    "Accounts/TPPPerAccountIsolationTests.swift",
    "Accounts/TPPCredentialIsolationE2ETests.swift",
    // Production-identity contract tests (`a === b` from production()
    // calls, withSignInModalSheetPresenter cache semantics).
    // Migrating these would invalidate the contract under test.
    "AppInfrastructure/AppContainerTests.swift",
    "AppInfrastructure/AppContainerAuthCoordinatorWiringTests.swift",
    // Many tests pin `executor.cancelNonEssentialTasks()` /
    // `clearCache()` against the production NetworkExecutor identity
    // (`a === b` from production().networkExecutor). The file's
    // tests are integration-style — production() resolution IS the
    // SUT. swarm_47883816 follow-up should evaluate whether these
    // can be split into unit + integration tests.
    "Network/TPPNetworkExecutorTests.swift",
  ]

  /// Per-line inline marker that exempts a single AppContainer.production()
  /// reference from the lint. Used when the surrounding test method
  /// explicitly exercises production() resolution semantics (e.g.
  /// `_testContainerOverride ?? AppContainer.production()` fallback) and
  /// migrating would break the test's purpose. Each marker must cite
  /// `swarm_47883816` so the maintenance review knows which swarm
  /// introduced the deferral.
  private static let perLineExemptionMarker = "// MIGRATED-DEFERRED:"

  /// Files owned by sibling work packages (B AccountsManagerIsolation,
  /// C TPPUserAccountIsolation, D UserDefaultsIsolation) per the
  /// swarm_47883816 manifest's `file-assignment matrix`. Their migrations
  /// land in PARALLEL work packages — the lint exempts them here because
  /// running this lint BEFORE those packages commit would force the suite
  /// red on files A doesn't own.
  ///
  /// Each entry is a path RELATIVE to `palaceTestsRoot`. After B/C/D
  /// commit their migrations, this list is no longer needed (their files
  /// will pass the lint cleanly) — orchestrator E will fold the
  /// exemptions into the whitelist + deferred list. Until then, the
  /// ownership boundary is encoded here.
  private static let siblingPackageOwned: Set<String> = [
    // B-owned (AccountsManagerIsolation)
    "Integration/AccountSwitchLifecycleTests.swift",
    "Integration/SignInToReadFlowIntegrationTests.swift",
    "Integration/ColdStartResumeIntegrationTests.swift",
    "Integration/BorrowAndDownloadIntegrationTests.swift",
    "Accounts/AccountsManagerCancellationTests.swift",
    "BookRegistry/TPPBookRegistryPersistenceTests.swift",
    "BookRegistry/TPPBookRegistryDependencyTests.swift",
    "BookRegistry/TPPBookRegistryAtomicWriteTests.swift",
    "BookRegistry/TPPBookRegistryLargeCorpusTests.swift",
    "BookRegistry/TPPBookRegistryMigrationTests.swift",
    // C-owned (TPPUserAccountIsolation)
    "ViewModels/AccountDetailViewModelTests.swift",
    "Accounts/AccountSwitchCleanupTests.swift",
    "Security/AuthFlowSecurityTests.swift",
    "Book/BookRegistrySyncReadinessTests.swift",
    "Chaos/ChaosFaultInjectionTests.swift",
    "CoverageGapTests3.swift",
    "ButtonStateTests.swift",
    "SignInLogic/TPPCrossLibrarySignOutTests.swift",
    // D-owned (UserDefaultsIsolation)
    "CoverageGapTests.swift",
    "Settings/DownloadOnlyOnWiFiTests.swift",
    "CatalogDomain/CatalogCacheKeyAndIsolationTests.swift",
    "CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift",
    "Audiobook/AudiobookIssueFixTests.swift",
    "AppInfrastructure/RemoteFeatureFlagsTests.swift",
    "Bookmarks/TPPBookmarkDeletionLogTests.swift",
    "SignInLogic/ForceResetTests.swift",
    "Accounts/AccountDetailsURLTests.swift",
    "Accounts/AccountsManagerStateMachineWiringTests.swift",
    "Accounts/AccountsManagerTests.swift",
  ]

  /// Deferred file list — loaded from
  /// `.forgeos/swarms/swarm_47883816/A-deferred-files.txt` at test time.
  /// Each entry is a path relative to the repo root. The lint allows
  /// `AppContainer.production()` references in these files; a follow-up
  /// swarm shrinks the list.
  private static let deferredFiles: Set<String> = {
    let path = repoRoot
      .appendingPathComponent(".forgeos/swarms/swarm_47883816/A-deferred-files.txt")
    guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
      return []
    }
    return Set(
      contents.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    )
  }()

  /// All `.swift` files under `PalaceTests/` (recursive). Skips hidden
  /// files and non-Swift artefacts.
  private func palaceTestSwiftFiles() throws -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: Self.palaceTestsRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      XCTFail("Could not enumerate \(Self.palaceTestsRoot.path) — is the PalaceTests directory present?")
      return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
      guard url.pathExtension == "swift" else { continue }
      let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
      guard isRegular else { continue }
      files.append(url)
    }
    return files
  }

  /// Read a file as UTF-8, returning nil on failure.
  private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Returns the file's path RELATIVE to `palaceTestsRoot` so it can be
  /// matched against the whitelist (which uses relative paths). E.g.
  /// `/.../PalaceTests/AppInfrastructure/AppContainerTests.swift` →
  /// `AppInfrastructure/AppContainerTests.swift`.
  private func relativePath(for url: URL) -> String {
    let abs = url.standardizedFileURL.path
    let root = Self.palaceTestsRoot.standardizedFileURL.path
    if abs.hasPrefix(root + "/") {
      return String(abs.dropFirst(root.count + 1))
    }
    return abs
  }

  /// Returns the file's path relative to the repo root so it can be
  /// matched against the deferred-files list (which lists `PalaceTests/...`).
  private func repoRelativePath(for url: URL) -> String {
    let abs = url.standardizedFileURL.path
    let root = Self.repoRoot.standardizedFileURL.path
    if abs.hasPrefix(root + "/") {
      return String(abs.dropFirst(root.count + 1))
    }
    return abs
  }

  /// Returns the list of (line-number, raw-line) tuples for each line
  /// in `source` that contains a non-exempt `AppContainer.production()`
  /// reference. Exempt:
  ///   - lines whose first non-whitespace is `//` or `///` (comments)
  ///   - lines carrying the `// MIGRATED-DEFERRED:` per-line marker
  private func violations(in source: String) -> [(Int, String)] {
    var out: [(Int, String)] = []
    for (i, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let lineStr = String(line)
      let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
      // Skip pure comment lines — they document semantics, not violate them.
      if trimmed.hasPrefix("//") {
        continue
      }
      // Skip the per-line MIGRATED-DEFERRED exemption.
      if lineStr.contains(Self.perLineExemptionMarker) {
        continue
      }
      guard lineStr.contains("AppContainer.production()") else { continue }
      out.append((i + 1, lineStr))
    }
    return out
  }

  // MARK: - Rule 1 — no production() reads outside the whitelist + deferred list

  /// Scans every Swift file in `PalaceTests/` and fails with a per-file
  /// breakdown if any non-exempt `AppContainer.production()` reference
  /// appears outside the whitelist + deferred list.
  func testNoAppContainerProductionOutsideWhitelist() throws {
    let files = try palaceTestSwiftFiles()
    XCTAssertFalse(files.isEmpty, "Expected at least one .swift file under PalaceTests/")

    var failures: [String] = []

    for url in files {
      let relPath = relativePath(for: url)
      let repoRelPath = repoRelativePath(for: url)
      // Whitelisted files are exempt regardless of content.
      if Self.whitelist.contains(relPath) {
        continue
      }
      // Deferred files are exempt regardless of content (tracked for
      // follow-up shrink swarm).
      if Self.deferredFiles.contains(repoRelPath) {
        continue
      }
      // Sibling-package-owned files are exempt until B/C/D commit their
      // migrations. After landing, orchestrator E folds these into the
      // whitelist + deferred list.
      if Self.siblingPackageOwned.contains(relPath) {
        continue
      }
      guard let source = contents(of: url) else {
        failures.append("\(relPath): could not read file as UTF-8")
        continue
      }
      let vios = violations(in: source)
      if vios.isEmpty { continue }
      failures.append(
        "\(relPath): \(vios.count) non-exempt `AppContainer.production()` reference\(vios.count == 1 ? "" : "s") — use `makeTestAppContainer()` from PalaceTests/Support/TestAppContainerFactory.swift, or add `// MIGRATED-DEFERRED: swarm_47883816 — <reason>` to the line if production() resolution IS the test contract"
      )
      // Show first few example lines so the failure is actionable.
      for (lineNo, line) in vios.prefix(3) {
        failures.append("    L\(lineNo): \(line.trimmingCharacters(in: .whitespaces))")
      }
    }

    if !failures.isEmpty {
      XCTFail(
        "AppContainer.production() lint violation — swarm_47883816 work package A:\n\n"
        + failures.joined(separator: "\n")
        + "\n\nTo migrate: replace `AppContainer.production().X` with `appContainer.X` and add `let appContainer = makeTestAppContainer()` to setUp (or inline). For per-site exemption, add `// MIGRATED-DEFERRED: swarm_47883816 — <reason>` at end of the line."
      )
    }
  }

  // MARK: - Rule 2 — lint self-test (proves the detector actually fires)

  /// Feeds the lint a synthetic violating string and asserts the detector
  /// would have caught it. Without this self-test, a regex regression that
  /// broke the detector would pass-by-default — the lint would scan zero
  /// violations and report green forever.
  func testLintCatchesSyntheticViolation() {
    // A pure code line containing the banned pattern.
    let synthetic = """
    import Foundation
    func sut() {
        let x = AppContainer.production().bookRegistry
        print(x)
    }
    """
    let vios = violations(in: synthetic)
    XCTAssertEqual(vios.count, 1,
                   "Lint must detect exactly one violation in the synthetic source")
    XCTAssertTrue(vios.first?.1.contains("AppContainer.production()") ?? false,
                  "Detected violation must contain the banned pattern")
  }

  /// Symmetric self-test: a comment-only `AppContainer.production()`
  /// reference MUST NOT trigger the lint. Documentation comments are
  /// load-bearing — they explain production resolution semantics — and
  /// banning them would force misleading paraphrases.
  func testLintIgnoresCommentLines() {
    let syntheticWithCommentOnly = """
    // The production seam resolves AppContainer.production() lazily.
    /// `AppContainer.production().bookRegistry` is the runtime path.
    func sut() {
        // no production() call in this body
        print("hello")
    }
    """
    let vios = violations(in: syntheticWithCommentOnly)
    XCTAssertEqual(vios.count, 0,
                   "Comment-only `AppContainer.production()` references must NOT trigger the lint")
  }

  /// Per-line exemption marker self-test: a code line carrying
  /// `// MIGRATED-DEFERRED:` MUST NOT trigger the lint.
  func testLintRespectsPerLineExemptionMarker() {
    let exempted = """
    func sut() {
        let testContainer = AppContainer.production().withSignInModalSheetPresenter(spy) // MIGRATED-DEFERRED: swarm_47883816 — withSignInModalSheetPresenter() returns a struct derived FROM the production cache; the seam itself is the SUT.
    }
    """
    let vios = violations(in: exempted)
    XCTAssertEqual(vios.count, 0,
                   "A code line carrying `// MIGRATED-DEFERRED:` must NOT trigger the lint")
  }

  /// Deferred-list-file self-test: confirms the resolver reads the
  /// `A-deferred-files.txt` file and parses ≥1 entry. If the file moves
  /// or is empty, the lint will silently treat every legacy file as a
  /// violator — a louder failure mode than letting them pass.
  func testDeferredListFileIsLoaded() {
    XCTAssertFalse(Self.deferredFiles.isEmpty,
                   "Expected the A-deferred-files.txt list to load with at least one entry — if this fails, the resolver path is wrong or the file is missing")
    // The deferred list should be a reasonable size (not 0, not the entire
    // repo). A growing-over-time deferred list is a smell, but baseline must
    // be reachable.
    XCTAssertLessThan(Self.deferredFiles.count, 200,
                      "Deferred list is unexpectedly large — verify the file was not corrupted")
  }
}

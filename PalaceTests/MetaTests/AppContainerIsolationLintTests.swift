//
//  AppContainerIsolationLintTests.swift
//  PalaceTests
//
//  Bans `AppContainer.production()` reads in PalaceTests outside (a) the whitelist
//  of files where production identity IS the contract, (b) the deferred list in
//  `MetaTests/Baselines/A-deferred-files.txt`, (c) lines carrying a
//  `// MIGRATED-DEFERRED:` marker, and (d) comment lines. New tests use
//  `makeTestAppContainer()`. `testLintCatchesSyntheticViolation` proves the
//  detector fires. It is an XCTest rather than a shell hook so it runs wherever
//  the suite runs and cannot be skipped with `--no-verify`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import XCTest

@MainActor
final class AppContainerIsolationLintTests: XCTestCase {

  // MARK: - Resolution

  /// `PalaceTests/` resolved relative to this file's location.
  private static let palaceTestsRoot: URL = {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // MetaTests/
      .deletingLastPathComponent()  // PalaceTests/
  }()

  /// Where this lint's own baselines live. They sit beside the lint, inside
  /// `PalaceTests/`, because they are gate INPUTS: without them the amnesty
  /// list is empty and every pre-existing violation reports as new. They must
  /// be tracked in git, not in a gitignored directory.
  /// Repo root — one level above `PalaceTests/`. Still used to express findings
  /// as repo-relative paths; it is no longer where the baseline lives.
  private static let repoRoot: URL = {
    palaceTestsRoot.deletingLastPathComponent()
  }()

  private static let baselinesRoot: URL = {
    palaceTestsRoot.appendingPathComponent("MetaTests/Baselines")
  }()

  /// Whitelist — files allowed to reference `AppContainer.production()`
  /// for documented reasons. Each entry is a path RELATIVE to `palaceTestsRoot`.
  ///
  /// **Adding a file to this list requires a stated rationale.** The default
  /// answer is "no — use `makeTestAppContainer()` instead."
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
    // TPPUserAccount factory tests reference production() in their
    // cache-isolation assertions.
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
    // SUT. A follow-up could split these into unit + integration tests.
    "Network/TPPNetworkExecutorTests.swift",
    // Production-identity-pin files where reading `AppContainer.production()`
    // IS the test contract. Migrating to `makeTestAppContainer()` would
    // invalidate the assertion under test.

    // Tests `_resetForTesting()`'s effect on the static `_cached` field —
    // reading production() is the only way to observe the cache rebuild.
    "AppInfrastructure/AppContainerResetTests.swift",
    // Pins `audiobookSession` / `playbackBootstrapper` static-cache
    // identity across `production()` reads ("must share a single
    // instance across all AppContainer.production() reads").
    "AppInfrastructure/AppContainerAudiobookFactoryTests.swift",
    // `testProductionContainer_exposesNonNilImageLoader` directly pins
    // the production graph; helper `makeProductionLikeContainer(imageLoader:)`
    // clones from production fields.
    "AppInfrastructure/AppContainerImageLoaderInjectionTests.swift",
    // Pins the static-cache short-circuit semantics of the
    // `withSignInModalSheetPresenter(_:)` modifier; cached presenter
    // identity IS the SUT.
    "AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift",
    // `testAppContainerProduction_wiresAuthCoordinator` asserts
    // `container.authCoordinator === again.authCoordinator` across
    // production() calls — identity is load-bearing.
    "AppInfrastructure/AuthCoordinatorTelemetryTests.swift",
  ]

  /// Per-line inline marker that exempts a single AppContainer.production()
  /// reference from the lint. Used when the surrounding test method
  /// explicitly exercises production() resolution semantics (e.g.
  /// `_testContainerOverride ?? AppContainer.production()` fallback) and
  /// migrating would break the test's purpose. Each marker must state
  /// its reason.
  private static let perLineExemptionMarker = "// MIGRATED-DEFERRED:"

  /// Files whose isolation is enforced by the sibling lints
  /// (AccountsManagerIsolation, TPPUserAccountIsolation, UserDefaultsIsolation)
  /// and so are exempt here. Each entry is a path RELATIVE to `palaceTestsRoot`.
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

  /// Deferred file list — loaded from `MetaTests/Baselines/A-deferred-files.txt`
  /// at test time. Each entry is a path relative to the repo root. The lint
  /// allows `AppContainer.production()` references in these files; follow-up
  /// work shrinks the list.
  private static let deferredFiles: Set<String> = {
    let path = baselinesRoot
      .appendingPathComponent("A-deferred-files.txt")
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
  /// The banned pattern. Defined once so the detector and self-tests agree.
  static let bannedProductionToken = "AppContainer.production()"

  /// True iff `line` contains `bannedProductionToken` OUTSIDE any double-quoted
  /// string literal. A mention *inside* a string — e.g. an `XCTFail` /
  /// assertion message that describes the banned pattern — is documentation,
  /// not a production() read, and must not trip the lint (same reasoning as the
  /// comment-line skip). Escaped quotes (`\"`) are handled; a `\(...)`
  /// interpolation is treated as still-inside-string, so a (vanishingly rare)
  /// real call placed inside an interpolation would be missed — an acceptable
  /// false-negative versus the deterministic false-positive this closes
  /// (AccountsManagerLaunchSnapshotTests's re-entrancy-guard XCTFail message
  /// named the pattern in prose and reddened the lint on every run).
  static func hasNonStringProductionReference(_ line: String) -> Bool {
    let chars = Array(line)
    let token = Array(bannedProductionToken)
    var inString = false
    var i = 0
    while i < chars.count {
      if inString {
        if chars[i] == "\\" { i += 2; continue }   // skip escaped char (incl. \" and \()
        if chars[i] == "\"" { inString = false }
        i += 1
        continue
      }
      if chars[i] == "\"" { inString = true; i += 1; continue }
      if chars[i] == token.first,
         i + token.count <= chars.count,
         Array(chars[i ..< i + token.count]) == token {
        return true
      }
      i += 1
    }
    return false
  }

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
      // Only a REAL (non-string-literal) reference is a violation. A mention
      // inside an assertion/XCTFail message is documentation — same as a
      // comment — and previously produced a deterministic false positive.
      guard Self.hasNonStringProductionReference(lineStr) else { continue }
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
      // a follow-up migration).
      if Self.deferredFiles.contains(repoRelPath) {
        continue
      }
      // Files covered by the sibling isolation lints are exempt here.
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

  /// The baselines must be TRACKED, not merely present on the machine that
  /// wrote them. They used to live in a gitignored directory; archiving it
  /// (#1411) left the files on disk for
  /// anyone who already had them and absent for every fresh checkout, so this
  /// lint passed locally and on branches cut earlier while failing on every
  /// branch cut afterwards. A gitignored gate input is a gate that is off.
  ///
  /// The test target runs in the simulator, where `Process` does not exist, so
  /// this cannot ask git directly. It reads `.gitignore` instead and fails if
  /// anything there names the baselines directory — which is the specific way
  /// this broke, and the specific way it would break again.
  func testBaselinesDirectoryIsNotGitIgnored() throws {
    let gitignore = Self.repoRoot.appendingPathComponent(".gitignore")
    let contents = try XCTUnwrap(
      try? String(contentsOf: gitignore, encoding: .utf8),
      "could not read .gitignore at \(gitignore.path)"
    )

    let offenders = contents
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .filter { $0.contains("MetaTests/Baselines") || $0.contains("MetaTests/") }

    XCTAssertTrue(
      offenders.isEmpty,
      "`.gitignore` names the lint baselines directory (\(offenders.joined(separator: ", "))). "
      + "These files are gate INPUTS: ignored, they vanish from fresh checkouts, the amnesty list "
      + "comes back empty, and every pre-existing violation reports as a new one."
    )
  }

  /// Deferred-list-file self-test: confirms the resolver reads the
  /// `A-deferred-files.txt` file and parses ≥1 entry. If the file moves
  /// or is empty, the lint will silently treat every legacy file as a
  /// violator — a louder failure mode than letting them pass.
  func testDeferredListFileIsLoaded() {
    XCTAssertFalse(Self.deferredFiles.isEmpty,
                   "Expected A-deferred-files.txt to load with at least one entry. Most likely the file is not in this checkout rather than the resolver being wrong — it is a gate INPUT and must be tracked; it previously lived under gitignored `.forgeos/swarms/` and vanished for every fresh checkout.")
    // The deferred list should be a reasonable size (not 0, not the entire
    // repo). A growing-over-time deferred list is a smell, but baseline must
    // be reachable.
    XCTAssertLessThan(Self.deferredFiles.count, 200,
                      "Deferred list is unexpectedly large — verify the file was not corrupted")
  }

  /// String-literal self-test — the false positive this detector fix closes.
  /// An `AppContainer.production()` mention inside a string literal (e.g. an
  /// `XCTFail` / assertion message that *describes* the banned pattern) MUST
  /// NOT trigger the lint. This is the exact deterministic failure
  /// `AccountsManagerLaunchSnapshotTests` produced: its re-entrancy-guard
  /// XCTFail message names `AppContainer.production()` with no real call, yet
  /// reddened `testNoAppContainerProductionOutsideWhitelist` on every run
  /// (masked only by the unit-test workflow's `continue-on-error`).
  func testLintIgnoresStringLiteralMentions() {
    let syntheticWithStringMention = """
    func sut() {
        XCTFail("re-enters AppContainer.production() under the held lock (PR #1226)")
        assert(condition, "AppContainer.production() must not be reached here")
    }
    """
    let vios = violations(in: syntheticWithStringMention)
    XCTAssertEqual(vios.count, 0,
                   "`AppContainer.production()` inside a string literal (assertion message) must NOT trigger the lint")
  }

  /// Boundary self-test: the string-literal skip must NOT blind the detector to
  /// a REAL call that shares a line with a string mention — otherwise the fix
  /// would open a hole where wrapping a call site in a same-line log message
  /// evades the lint.
  func testLintFlagsRealCallEvenWhenSameLineAlsoMentionsInString() {
    let mixed = """
    func sut() {
        let x = AppContainer.production().bookRegistry; log("touched AppContainer.production()")
    }
    """
    let vios = violations(in: mixed)
    XCTAssertEqual(vios.count, 1,
                   "A real `AppContainer.production()` call must still be flagged even when the same line also mentions it inside a string")
  }

  // MARK: - Rule 3 — production code reads owned services through its container

  /// `Palace/`, scanned by the owned-service rule. `Palace/Packages/` is
  /// skipped: package targets cannot see `AppContainer`.
  private static let palaceSourceRoot: URL = repoRoot.appendingPathComponent("Palace")

  /// Most entries the owned-service baseline may hold. Lower it together with
  /// the baseline when a listed read is removed.
  static let ownedServiceBaselineCeiling = 11

  /// The services `AppContainerOwnedServices` stores, read from its source so
  /// a service added there is covered without editing this lint.
  static func ownedServiceNames(inOwnedServicesSource source: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"^\s*var\s+(\w+)\s*:"#, options: [.anchorsMatchLines])
    let range = NSRange(source.startIndex..., in: source)
    return pattern.matches(in: source, range: range).compactMap { match in
      Range(match.range(at: 1), in: source).map { String(source[$0]) }
    }
  }

  /// `source` with comment lines blanked, string-literal contents blanked and
  /// trailing `//` comments removed, keeping line structure.
  static func codeOnly(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { return "" }
      var out = ""
      var inString = false
      let chars = Array(rawLine)
      var i = 0
      while i < chars.count {
        let c = chars[i]
        if inString {
          if c == "\\" { i += 2; continue }
          if c == "\"" { inString = false; out.append(c) }
          i += 1
          continue
        }
        if c == "\"" { inString = true; out.append(c); i += 1; continue }
        if c == "/", i + 1 < chars.count, chars[i + 1] == "/" { break }
        out.append(c)
        i += 1
      }
      return out
    }.joined(separator: "\n")
  }

  /// One entry per `AppContainer.production().<service>` read in `source`,
  /// including a chain split across lines.
  static func ownedServiceReads(in source: String, services: [String]) -> [String] {
    guard !services.isEmpty else { return [] }
    let alternation = services.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    let pattern = try! NSRegularExpression(
      pattern: #"AppContainer\s*\.\s*production\(\)\s*\.\s*("# + alternation + #")\b"#
    )
    let code = codeOnly(source)
    let range = NSRange(code.startIndex..., in: code)
    return pattern.matches(in: code, range: range).compactMap { match in
      Range(match.range(at: 1), in: code).map { String(code[$0]) }
    }
  }

  /// Multiset difference between the reads found and the baseline entries:
  /// reads with no entry, and entries with no read.
  static func ownedServiceBaselineDiff(found: [String], baseline: [String]) -> (unlisted: [String], stale: [String]) {
    var remaining = Dictionary(baseline.map { ($0, 1) }, uniquingKeysWith: +)
    var unlisted: [String] = []
    for entry in found {
      if let count = remaining[entry], count > 0 {
        remaining[entry] = count - 1
      } else {
        unlisted.append(entry)
      }
    }
    let stale = remaining.sorted { $0.key < $1.key }.flatMap { Array(repeating: $0.key, count: $0.value) }
    return (unlisted.sorted(), stale)
  }

  private static func ownedServiceBaseline() throws -> [String] {
    let url = baselinesRoot.appendingPathComponent("owned-service-production-reads.txt")
    let contents = try String(contentsOf: url, encoding: .utf8)
    return contents.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
  }

  /// Production code must read the services a container owns through the
  /// container it was given. `AppContainer.production().<service>` reaches the
  /// process container's instance instead, so a test or preview container's
  /// collaborators are bypassed (#1593). Reads that predate the rule are listed
  /// in `Baselines/owned-service-production-reads.txt`.
  func testProductionCodeReadsOwnedServicesThroughItsContainer() throws {
    let ownedSource = try String(
      contentsOf: Self.palaceSourceRoot.appendingPathComponent("AppInfrastructure/AppContainerOwnedServices.swift"),
      encoding: .utf8
    )
    let services = Self.ownedServiceNames(inOwnedServicesSource: ownedSource)
    XCTAssertTrue(services.contains("signInModalSheetPresenter"),
                  "Could not read the owned services from AppContainerOwnedServices.swift; found \(services)")

    let fm = FileManager.default
    let enumerator = try XCTUnwrap(fm.enumerator(
      at: Self.palaceSourceRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ), "Could not enumerate \(Self.palaceSourceRoot.path)")
    let packagesPrefix = Self.palaceSourceRoot.standardizedFileURL.path + "/Packages/"
    var scanned = 0
    var found: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      guard !url.standardizedFileURL.path.hasPrefix(packagesPrefix),
            let source = contents(of: url) else { continue }
      scanned += 1
      let path = repoRelativePath(for: url)
      found += Self.ownedServiceReads(in: source, services: services).map { "\(path) \($0)" }
    }
    XCTAssertGreaterThan(scanned, 100, "Expected to scan the app sources under \(Self.palaceSourceRoot.path)")

    let baseline = try Self.ownedServiceBaseline()
    XCTAssertLessThanOrEqual(baseline.count, Self.ownedServiceBaselineCeiling,
                             "The owned-service baseline may only shrink; it now has \(baseline.count) entries")

    let diff = Self.ownedServiceBaselineDiff(found: found, baseline: baseline)
    XCTAssertTrue(diff.unlisted.isEmpty,
                  "Read the owned service through the container this type was given, not AppContainer.production():\n"
                  + diff.unlisted.joined(separator: "\n"))
    XCTAssertTrue(diff.stale.isEmpty,
                  "These baseline entries no longer match a read; remove them and lower ownedServiceBaselineCeiling:\n"
                  + diff.stale.joined(separator: "\n"))
  }

  /// The scanner finds a read on one line and one whose member access starts
  /// on the next line, and reports the service each one reads.
  func testOwnedServiceScanner_FindsSameLineAndChainedReads() {
    let source = """
    func sut() {
        let cache = AppContainer.production().bookCellModelCache
        AppContainer.production()
            .signInModalSheetPresenter
            .presentSignInModalForCurrentAccount(completion: nil)
    }
    """
    XCTAssertEqual(
      Self.ownedServiceReads(in: source, services: ["bookCellModelCache", "signInModalSheetPresenter"]),
      ["bookCellModelCache", "signInModalSheetPresenter"]
    )
  }

  /// Comments, string literals and collaborators the container does not own
  /// are not owned-service reads.
  func testOwnedServiceScanner_IgnoresCommentsStringsAndOtherMembers() {
    let source = """
    // AppContainer.production().catalogAPI is the process instance.
    /// `AppContainer.production().catalogAPI`
    let executor = AppContainer.production().networkExecutor
    log("AppContainer.production().catalogAPI") // AppContainer.production().catalogAPI
    let cache = AppContainer.production().catalogAPIs
    """
    XCTAssertEqual(Self.ownedServiceReads(in: source, services: ["catalogAPI"]), [])
  }

  /// A reintroduced read is reported as unlisted, and a removed one as stale,
  /// counting repeated reads in one file separately.
  func testOwnedServiceBaselineDiff_ReportsUnlistedAndStaleReads() {
    let baseline = ["A.swift presenter", "A.swift presenter", "B.swift cache"]

    let diff = Self.ownedServiceBaselineDiff(
      found: ["A.swift presenter", "C.swift presenter", "A.swift presenter", "A.swift presenter"],
      baseline: baseline
    )

    XCTAssertEqual(diff.unlisted, ["A.swift presenter", "C.swift presenter"])
    XCTAssertEqual(diff.stale, ["B.swift cache"])
  }

  /// The service list comes from the stored properties of
  /// `AppContainerOwnedServices`, skipping its initializer.
  func testOwnedServiceNames_ReadsStoredPropertiesOnly() {
    let source = """
    final class AppContainerOwnedServices {
        var signInModalSheetPresenter: SignInModalSheetPresenter?
        var catalogAPI: DefaultCatalogAPI?

        nonisolated init() {}
    }
    """
    XCTAssertEqual(Self.ownedServiceNames(inOwnedServicesSource: source),
                   ["signInModalSheetPresenter", "catalogAPI"])
  }
}

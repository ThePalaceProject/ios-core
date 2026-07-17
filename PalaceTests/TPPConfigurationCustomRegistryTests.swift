import XCTest
@testable import Palace

/// Covers the developer-settings custom registry URL construction
/// (`TPPConfiguration.customUrl` / `customRegistryIsExplicitURL`).
///
/// A bare host preserves the historical `https://<host>/libraries/qa`
/// behavior; a full URL is used verbatim so a developer can target an
/// exact endpoint such as the non-crawlable `/libraries` feed that older
/// clients parse directly.
@MainActor
final class TPPConfigurationCustomRegistryTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var settings: TPPSettings!

  override func setUp() {
    super.setUp()
    suiteName = "TPPConfigurationCustomRegistryTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    settings = TPPSettings(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    settings = nil
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  // MARK: - customUrl

  func test_customUrl_whenUnset_isNil() {
    XCTAssertNil(TPPConfiguration.customUrl(settings: settings),
                 "No custom registry configured should yield no custom URL")
    XCTAssertFalse(TPPConfiguration.customRegistryIsExplicitURL(settings: settings))
  }

  func test_customUrl_bareHost_appendsLibrariesQa() {
    settings.customLibraryRegistryServer = "registry.dev.palaceproject.io"
    XCTAssertEqual(
      TPPConfiguration.customUrl(settings: settings)?.absoluteString,
      "https://registry.dev.palaceproject.io/libraries/qa",
      "Bare host must preserve the legacy https://<host>/libraries/qa form")
    XCTAssertFalse(TPPConfiguration.customRegistryIsExplicitURL(settings: settings),
                   "A bare host is not an explicit URL")
  }

  func test_customUrl_fullHttpsURL_isUsedVerbatim() {
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries"
    XCTAssertEqual(
      TPPConfiguration.customUrl(settings: settings)?.absoluteString,
      "https://registry.dev.palaceproject.io/libraries",
      "A full https URL must be fetched verbatim — no /qa suffix appended")
    XCTAssertTrue(TPPConfiguration.customRegistryIsExplicitURL(settings: settings),
                  "A full URL must be flagged explicit so the crawler is bypassed")
  }

  func test_customUrl_fullHttpURL_isUsedVerbatim() {
    settings.customLibraryRegistryServer = "http://localhost:8000/libraries"
    XCTAssertEqual(
      TPPConfiguration.customUrl(settings: settings)?.absoluteString,
      "http://localhost:8000/libraries",
      "A full http URL (local dev server) must be used verbatim")
    XCTAssertTrue(TPPConfiguration.customRegistryIsExplicitURL(settings: settings))
  }

  func test_customUrl_fullURLWithQuery_preservesQuery() {
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries?availability=all"
    XCTAssertEqual(
      TPPConfiguration.customUrl(settings: settings)?.absoluteString,
      "https://registry.dev.palaceproject.io/libraries?availability=all",
      "Query params on an explicit URL must be preserved, not stripped")
  }

  func test_customUrl_whitespacePaddedHost_isTrimmed() {
    settings.customLibraryRegistryServer = "  registry.dev.palaceproject.io  "
    XCTAssertEqual(
      TPPConfiguration.customUrl(settings: settings)?.absoluteString,
      "https://registry.dev.palaceproject.io/libraries/qa",
      "Surrounding whitespace must be trimmed before URL construction")
  }

  func test_customUrl_emptyOrWhitespaceOnly_isNil() {
    settings.customLibraryRegistryServer = "   "
    XCTAssertNil(TPPConfiguration.customUrl(settings: settings),
                 "Whitespace-only input must not produce a malformed https:///libraries/qa URL")
    XCTAssertFalse(TPPConfiguration.customRegistryIsExplicitURL(settings: settings))
  }

  // MARK: - hash consistency

  func test_customUrlHash_matchesHashOfActualFetchURL() {
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries"
    // The cache key must hash the exact URL the app fetches, otherwise the
    // explicit-URL response is cached under a key the loader never reads.
    let url = TPPConfiguration.customUrl(settings: settings)!
    let expected = url.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])
    XCTAssertEqual(TPPConfiguration.customUrlHash(settings: settings), expected)
  }

  // MARK: - availability=all (Enable Hidden Libraries, PP-4698)

  /// Returns the `availability` query values present on the custom URL, in order.
  private func availabilityValues() -> [String] {
    guard let url = TPPConfiguration.customUrl(settings: settings),
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return [] }
    return items.filter { $0.name == "availability" }.compactMap { $0.value }
  }

  private func queryValue(_ name: String) -> String? {
    guard let url = TPPConfiguration.customUrl(settings: settings),
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return nil }
    return items.first { $0.name == name }?.value
  }

  /// Sets the "Enable Hidden Libraries" flag by writing the backing key on the
  /// test's ISOLATED defaults suite, rather than via `settings.useBetaLibraries`'s
  /// setter. The setter posts `.TPPUseBetaDidChange`, which a live shared
  /// `AccountsManager` observes and turns into a background `loadCatalogs` that
  /// reads `.standard` and outlives the test — the test-pollution shape CLAUDE.md
  /// item #2 names. The getter reads this key, so behavior under test is identical
  /// while the global notification fan-out is avoided.
  private func setHiddenLibraries(_ on: Bool) {
    defaults.set(on, forKey: "NYPLUseBetaLibrariesKey")
  }

  func test_explicitURL_whenHiddenLibrariesOn_appendsAvailabilityAll() {
    setHiddenLibraries(true)
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries"
    XCTAssertEqual(availabilityValues(), ["all"],
                   "Enable Hidden Libraries must add availability=all to the explicit registry fetch URL")
  }

  func test_explicitURL_whenHiddenLibrariesOff_hasNoAvailability() {
    setHiddenLibraries(false)
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries"
    XCTAssertEqual(TPPConfiguration.customUrl(settings: settings)?.absoluteString,
                   "https://registry.dev.palaceproject.io/libraries",
                   "With Hidden Libraries off, the explicit URL is fetched exactly as typed")
    XCTAssertTrue(availabilityValues().isEmpty)
  }

  func test_explicitURL_whenHiddenLibrariesOn_preservesOtherQueryItems() {
    setHiddenLibraries(true)
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries?order=modified"
    XCTAssertEqual(queryValue("order"), "modified",
                   "Existing query items the developer typed must be preserved")
    XCTAssertEqual(availabilityValues(), ["all"],
                   "availability=all is added alongside, not instead of, existing query items")
  }

  func test_explicitURL_whenHiddenLibrariesOn_overwritesExistingAvailability() {
    setHiddenLibraries(true)
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries?availability=production"
    XCTAssertEqual(availabilityValues(), ["all"],
                   "A developer-typed availability=production must be overwritten to all (exactly once) when Hidden Libraries is on")
  }

  func test_explicitURL_whenHiddenLibrariesOff_leavesTypedAvailabilityUntouched() {
    setHiddenLibraries(false)
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries?availability=production"
    XCTAssertEqual(availabilityValues(), ["production"],
                   "With Hidden Libraries off, the app must not rewrite an availability value the developer typed themselves")
  }

  func test_bareHost_whenHiddenLibrariesOn_isNotRewrittenAtThisLayer() {
    // A bare host is not an explicit URL: it keeps the legacy
    // https://<host>/libraries/qa form and gets availability=all from the
    // crawler (LibraryRegistryCrawler.crawlableURL), NOT from customUrl. This
    // pins that customUrl does not also inject it, which would double-append.
    setHiddenLibraries(true)
    settings.customLibraryRegistryServer = "registry.dev.palaceproject.io"
    XCTAssertEqual(TPPConfiguration.customUrl(settings: settings)?.absoluteString,
                   "https://registry.dev.palaceproject.io/libraries/qa",
                   "Bare host must not get availability=all injected at the customUrl layer")
    XCTAssertTrue(availabilityValues().isEmpty)
  }

  func test_hiddenLibrariesToggle_changesCacheHashForExplicitURL() {
    settings.customLibraryRegistryServer = "https://registry.dev.palaceproject.io/libraries"
    setHiddenLibraries(false)
    let hashOff = TPPConfiguration.customUrlHash(settings: settings)
    setHiddenLibraries(true)
    let hashOn = TPPConfiguration.customUrlHash(settings: settings)
    XCTAssertNotNil(hashOff)
    XCTAssertNotNil(hashOn)
    XCTAssertNotEqual(hashOff, hashOn,
                      "Toggling Hidden Libraries must change the cache key so the availability=all feed is fetched, not served from the production-feed cache")
  }

  // MARK: - explicit-URL predicate parse fidelity (SoD deferred item #1)

  func test_customRegistryIsExplicitURL_unparseableExplicitInput_isFalse() {
    // Has an http(s):// prefix but does not parse to a URL (unclosed IPv6
    // literal). The predicate must agree with customUrl() — otherwise
    // AccountsManager takes the explicit-URL branch for a URL that is nil.
    settings.customLibraryRegistryServer = "https://["
    XCTAssertNil(TPPConfiguration.customUrl(settings: settings),
                 "An unparseable explicit string yields no custom URL")
    XCTAssertFalse(TPPConfiguration.customRegistryIsExplicitURL(settings: settings),
                   "customRegistryIsExplicitURL must not claim explicit when customUrl() is nil")
  }
}

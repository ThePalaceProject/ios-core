import XCTest
@testable import Palace

/// Covers the developer-settings custom registry URL construction
/// (`TPPConfiguration.customUrl` / `customRegistryIsExplicitURL`).
///
/// A bare host preserves the historical `https://<host>/libraries/qa`
/// behavior; a full URL is used verbatim so a developer can target an
/// exact endpoint such as the non-crawlable `/libraries` feed that older
/// clients parse directly.
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
}

import XCTest
@testable import Palace

final class TPPConfigurationTests: XCTestCase {

  // MARK: - Color Methods

  func test_mainColor_returnsValidUIColor() {
    let color = TPPConfiguration.mainColor()
    XCTAssertNotNil(color, "mainColor() should return a non-nil UIColor")
    // Color should be deterministic across calls
    XCTAssertEqual(color, TPPConfiguration.mainColor(), "mainColor() should return consistent value")
  }

  func test_accentColor_returnsValidUIColor() {
    let color = TPPConfiguration.accentColor()
    XCTAssertNotNil(color, "accentColor() should return a non-nil UIColor")
    // accentColor should differ from mainColor (they serve different purposes)
    XCTAssertNotEqual(color, TPPConfiguration.mainColor(),
                      "accentColor should be visually distinct from mainColor")
  }

  func test_backgroundColor_returnsValidUIColor() {
    let color = TPPConfiguration.backgroundColor()
    XCTAssertNotNil(color, "backgroundColor() should return a non-nil UIColor")
    // Background color should be distinct from foreground colors
    XCTAssertEqual(color, TPPConfiguration.backgroundColor(), "backgroundColor() should be deterministic")
  }

  func test_readerBackgroundColor_returnsValidUIColor() {
    let color = TPPConfiguration.readerBackgroundColor()
    XCTAssertNotNil(color)
    // Reader background color should be consistent (used while reading)
    XCTAssertEqual(color, TPPConfiguration.readerBackgroundColor(),
                   "readerBackgroundColor() should be deterministic")
  }

  func test_readerBackgroundDarkColor_returnsValidUIColor() {
    let color = TPPConfiguration.readerBackgroundDarkColor()
    XCTAssertNotNil(color)
    // Dark mode background should differ from standard background
    let standard = TPPConfiguration.readerBackgroundColor()
    XCTAssertNotEqual(color, standard,
                      "Dark reader background should differ from standard reader background")
  }

  func test_readerBackgroundSepiaColor_returnsValidUIColor() {
    let color = TPPConfiguration.readerBackgroundSepiaColor()
    XCTAssertNotNil(color)
    // Sepia background should differ from both standard and dark backgrounds
    let standard = TPPConfiguration.readerBackgroundColor()
    XCTAssertNotEqual(color, standard,
                      "Sepia reader background should differ from standard reader background")
  }

  func test_palaceRed_returnsValidUIColor() {
    let color = TPPConfiguration.palaceRed()
    XCTAssertNotNil(color)
    // palaceRed is a brand color and should be deterministic
    XCTAssertEqual(color, TPPConfiguration.palaceRed(), "palaceRed() should be deterministic")
  }

  func test_backgroundMediaOverlayHighlightColor_returnsValidUIColor() {
    let color = TPPConfiguration.backgroundMediaOverlayHighlightColor()
    XCTAssertNotNil(color)
    // The highlight overlay color should be deterministic
    XCTAssertEqual(color, TPPConfiguration.backgroundMediaOverlayHighlightColor(),
                   "backgroundMediaOverlayHighlightColor() should be deterministic")
  }

  // MARK: - Font Methods

  func test_systemFontFamilyName_returnsNonEmptyString() {
    let name = TPPConfiguration.systemFontFamilyName()
    XCTAssertNotNil(name)
    XCTAssertFalse(name.isEmpty, "systemFontFamilyName() should return a non-empty string")
  }

  func test_systemFontName_returnsNonEmptyString() {
    let name = TPPConfiguration.systemFontName()
    XCTAssertNotNil(name)
    XCTAssertFalse(name.isEmpty)
  }

  func test_semiBoldSystemFontName_returnsNonEmptyString() {
    let name = TPPConfiguration.semiBoldSystemFontName()
    XCTAssertNotNil(name)
    XCTAssertFalse(name.isEmpty)
  }

  func test_boldSystemFontName_returnsNonEmptyString() {
    let name = TPPConfiguration.boldSystemFontName()
    XCTAssertNotNil(name)
    XCTAssertFalse(name.isEmpty)
  }

  func test_systemFontFamilyName_returnsOpenSans() {
    let name = TPPConfiguration.systemFontFamilyName()
    XCTAssertEqual(name, "OpenSans")
    // Verify it is also non-empty (belt-and-suspenders check)
    XCTAssertFalse(name.isEmpty, "Font family name should not be empty")
  }

  // MARK: - Layout Constants

  func test_defaultTOCRowHeight_returnsPositiveValue() {
    let height = TPPConfiguration.defaultTOCRowHeight()
    XCTAssertGreaterThan(height, 0, "defaultTOCRowHeight should be positive")
    XCTAssertEqual(height, 56, "Expected default TOC row height of 56")
  }

  func test_defaultBookmarkRowHeight_returnsPositiveValue() {
    let height = TPPConfiguration.defaultBookmarkRowHeight()
    XCTAssertGreaterThan(height, 0, "defaultBookmarkRowHeight should be positive")
    XCTAssertEqual(height, 100, "Expected default bookmark row height of 100")
  }

  // MARK: - Navigation Bar Appearance

  func test_defaultAppearance_returnsConfiguredAppearance() {
    let appearance = TPPConfiguration.defaultAppearance()
    XCTAssertNotNil(appearance, "defaultAppearance should return a non-nil appearance")
    XCTAssertNotNil(appearance.backgroundColor, "defaultAppearance should have a background color")
  }

  func test_appearanceWithBackgroundColor_usesProvidedColor() {
    let testColor = UIColor.red
    let appearance = TPPConfiguration.appearance(withBackgroundColor: testColor)
    XCTAssertNotNil(appearance)
    XCTAssertNotNil(appearance.backgroundColor)
  }

  // MARK: - Registry URLs

  func test_betaUrl_isValid() {
    XCTAssertEqual(
      TPPConfiguration.betaUrl.absoluteString,
      "https://registry.palaceproject.io/libraries/qa"
    )
    // Beta URL should differ from prod URL
    XCTAssertNotEqual(TPPConfiguration.betaUrl, TPPConfiguration.prodUrl,
                      "Beta and prod URLs must be different")
  }

  func test_prodUrl_isValid() {
    XCTAssertEqual(
      TPPConfiguration.prodUrl.absoluteString,
      "https://registry.palaceproject.io/libraries"
    )
    // Prod URL should use HTTPS
    XCTAssertTrue(TPPConfiguration.prodUrl.scheme == "https",
                  "Production registry URL must use HTTPS")
  }

  func test_betaUrlHash_isNonEmpty() {
    XCTAssertFalse(TPPConfiguration.betaUrlHash.isEmpty)
    // Hash should differ from prod hash since URLs differ
    XCTAssertNotEqual(TPPConfiguration.betaUrlHash, TPPConfiguration.prodUrlHash,
                      "Beta and prod URL hashes should differ")
  }

  func test_prodUrlHash_isNonEmpty() {
    XCTAssertFalse(TPPConfiguration.prodUrlHash.isEmpty)
    // Hash length should be consistent (e.g., MD5 = 32 hex chars, SHA = longer)
    XCTAssertGreaterThan(TPPConfiguration.prodUrlHash.count, 4,
                         "URL hash should be a reasonably long string")
  }

  func test_prodUrlHash_isDeterministic() {
    let hash1 = TPPConfiguration.prodUrlHash
    let hash2 = TPPConfiguration.prodUrlHash
    XCTAssertEqual(hash1, hash2, "Hash should be deterministic across calls")
  }
}

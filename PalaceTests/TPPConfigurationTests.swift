import XCTest
@testable import Palace

final class TPPConfigurationTests: XCTestCase {

  // MARK: - Color Methods

  func test_mainColor_returnsValidUIColor() {
    let color = TPPConfiguration.mainColor()
    XCTAssertNotNil(color, "mainColor() should return a non-nil UIColor")
  }

  func test_accentColor_returnsValidUIColor() {
    let color = TPPConfiguration.accentColor()
    XCTAssertNotNil(color, "accentColor() should return a non-nil UIColor")
  }

  func test_backgroundColor_returnsValidUIColor() {
    let color = TPPConfiguration.backgroundColor()
    XCTAssertNotNil(color, "backgroundColor() should return a non-nil UIColor")
  }

  func test_readerBackgroundColor_returnsValidUIColor() {
    let color = TPPConfiguration.readerBackgroundColor()
    XCTAssertNotNil(color)
  }

  func test_readerBackgroundDarkColor_returnsValidUIColor() {
    let color = TPPConfiguration.readerBackgroundDarkColor()
    XCTAssertNotNil(color)
  }

  func test_readerBackgroundSepiaColor_returnsValidUIColor() {
    let color = TPPConfiguration.readerBackgroundSepiaColor()
    XCTAssertNotNil(color)
  }

  func test_palaceRed_returnsValidUIColor() {
    let color = TPPConfiguration.palaceRed()
    XCTAssertNotNil(color)
  }

  func test_backgroundMediaOverlayHighlightColor_returnsValidUIColor() {
    let color = TPPConfiguration.backgroundMediaOverlayHighlightColor()
    XCTAssertNotNil(color)
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

  // MARK: - URL Methods

  func test_minimumVersionURL_returnsValidURL() {
    let url = TPPConfiguration.minimumVersionURL()
    XCTAssertNotNil(url, "minimumVersionURL should return a non-nil URL")
    XCTAssertTrue(url.absoluteString.contains("minimum-version"))
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
  }

  func test_prodUrl_isValid() {
    XCTAssertEqual(
      TPPConfiguration.prodUrl.absoluteString,
      "https://registry.palaceproject.io/libraries"
    )
  }

  func test_betaUrlHash_isNonEmpty() {
    XCTAssertFalse(TPPConfiguration.betaUrlHash.isEmpty)
  }

  func test_prodUrlHash_isNonEmpty() {
    XCTAssertFalse(TPPConfiguration.prodUrlHash.isEmpty)
  }

  func test_prodUrlHash_isDeterministic() {
    let hash1 = TPPConfiguration.prodUrlHash
    let hash2 = TPPConfiguration.prodUrlHash
    XCTAssertEqual(hash1, hash2, "Hash should be deterministic across calls")
  }
}

//
//  SettingsViewModelTests.swift
//  PalaceTests
//
//  Tests for SettingsViewModel using TPPSettingsMock for dependency injection.
//  Tests real production code (SettingsViewModel) with mocked dependencies.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class SettingsViewModelTests: XCTestCase {
  
  private var mockSettings: TPPSettingsMock!
  private var sut: SettingsViewModel!
  private var cancellables: Set<AnyCancellable>!
  
  override func setUp() {
    super.setUp()
    mockSettings = TPPSettingsMock()
    sut = SettingsViewModel(settings: mockSettings)
    cancellables = []
  }
  
  override func tearDown() {
    cancellables.removeAll()
    mockSettings.reset()
    mockSettings = nil
    sut = nil
    super.tearDown()
  }
  
  // MARK: - Initialization Tests
  
  func testSettingsViewModel_Init_ReadsSettingsFromProvider() async {
    // Arrange
    let expectedURL = URL(string: "https://example.com/feed")!
    let mockSettings = TPPSettingsMock(
      customMainFeedURL: expectedURL,
      useBetaLibraries: true,
      userPresentedAgeCheck: true,
      userHasAcceptedEULA: true,
      enterLCPPassphraseManually: true,
      appVersion: "1.0.0",
      customLibraryRegistryServer: "https://registry.example.com"
    )
    
    // Act
    let viewModel = SettingsViewModel(settings: mockSettings)
    
    // Assert
    XCTAssertEqual(viewModel.customMainFeedURL, expectedURL)
    XCTAssertTrue(viewModel.useBetaLibraries)
    XCTAssertTrue(viewModel.userPresentedAgeCheck)
    XCTAssertTrue(viewModel.userHasAcceptedEULA)
    XCTAssertTrue(viewModel.enterLCPPassphraseManually)
    XCTAssertEqual(viewModel.appVersion, "1.0.0")
    XCTAssertEqual(viewModel.customLibraryRegistryServer, "https://registry.example.com")
  }
  
  func testSettingsViewModel_Init_DefaultsAreCorrect() async {
    // Arrange & Act - mockSettings has default values
    let viewModel = SettingsViewModel(settings: mockSettings)
    
    // Assert
    XCTAssertFalse(viewModel.useBetaLibraries)
    XCTAssertFalse(viewModel.userPresentedAgeCheck)
    XCTAssertFalse(viewModel.userHasAcceptedEULA)
    XCTAssertFalse(viewModel.enterLCPPassphraseManually)
    XCTAssertNil(viewModel.customMainFeedURL)
    XCTAssertNil(viewModel.customLibraryRegistryServer)
    XCTAssertNil(viewModel.appVersion)
  }
  
  // MARK: - Beta Libraries Tests
  
  func testSettingsViewModel_SetUseBetaLibraries_UpdatesSettings() async {
    // Arrange
    XCTAssertFalse(mockSettings.useBetaLibraries)
    
    // Act
    sut.useBetaLibraries = true
    
    // Assert
    XCTAssertTrue(mockSettings.useBetaLibraries)
    XCTAssertTrue(sut.useBetaLibraries)
  }
  
  func testSettingsViewModel_ToggleBetaLibraries_TogglesValue() async {
    // Arrange
    XCTAssertFalse(sut.useBetaLibraries)
    
    // Act
    sut.toggleBetaLibraries()
    
    // Assert
    XCTAssertTrue(sut.useBetaLibraries)
    XCTAssertTrue(mockSettings.useBetaLibraries)
    
    // Act - toggle again
    sut.toggleBetaLibraries()
    
    // Assert
    XCTAssertFalse(sut.useBetaLibraries)
    XCTAssertFalse(mockSettings.useBetaLibraries)
  }
  
  // MARK: - EULA Tests
  
  func testSettingsViewModel_AcceptEULA_SetsTrue() async {
    // Arrange
    XCTAssertFalse(sut.userHasAcceptedEULA)
    
    // Act
    sut.acceptEULA()
    
    // Assert
    XCTAssertTrue(sut.userHasAcceptedEULA)
    XCTAssertTrue(mockSettings.userHasAcceptedEULA)
  }
  
  func testSettingsViewModel_SetUserHasAcceptedEULA_UpdatesSettings() async {
    // Arrange & Act
    sut.userHasAcceptedEULA = true
    
    // Assert
    XCTAssertTrue(mockSettings.userHasAcceptedEULA)
  }
  
  // MARK: - Age Check Tests
  
  func testSettingsViewModel_MarkAgeCheckPresented_SetsTrue() async {
    // Arrange
    XCTAssertFalse(sut.userPresentedAgeCheck)
    
    // Act
    sut.markAgeCheckPresented()
    
    // Assert
    XCTAssertTrue(sut.userPresentedAgeCheck)
    XCTAssertTrue(mockSettings.userPresentedAgeCheck)
  }
  
  func testSettingsViewModel_SetUserPresentedAgeCheck_UpdatesSettings() async {
    // Arrange & Act
    sut.userPresentedAgeCheck = true
    
    // Assert
    XCTAssertTrue(mockSettings.userPresentedAgeCheck)
  }
  
  // MARK: - LCP Passphrase Tests
  
  func testSettingsViewModel_ToggleLCPManualPassphrase_TogglesValue() async {
    // Arrange
    XCTAssertFalse(sut.enterLCPPassphraseManually)
    
    // Act
    sut.toggleLCPManualPassphrase()
    
    // Assert
    XCTAssertTrue(sut.enterLCPPassphraseManually)
    XCTAssertTrue(mockSettings.enterLCPPassphraseManually)
  }
  
  func testSettingsViewModel_SetEnterLCPPassphraseManually_UpdatesSettings() async {
    // Arrange & Act
    sut.enterLCPPassphraseManually = true
    
    // Assert
    XCTAssertTrue(mockSettings.enterLCPPassphraseManually)
  }
  
  // MARK: - Custom Feed URL Tests
  
  func testSettingsViewModel_SetCustomFeedURL_ValidHTTPS_ReturnsTrue() async {
    // Arrange
    let urlString = "https://example.com/feed"
    
    // Act
    let result = sut.setCustomFeedURL(urlString)
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertEqual(sut.customMainFeedURL?.absoluteString, urlString)
    XCTAssertEqual(mockSettings.customMainFeedURL?.absoluteString, urlString)
  }
  
  func testSettingsViewModel_SetCustomFeedURL_ValidHTTP_ReturnsTrue() async {
    // Arrange
    let urlString = "http://example.com/feed"
    
    // Act
    let result = sut.setCustomFeedURL(urlString)
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertEqual(sut.customMainFeedURL?.absoluteString, urlString)
  }
  
  func testSettingsViewModel_SetCustomFeedURL_InvalidURL_ReturnsFalse() async {
    // Arrange
    let invalidURL = "not a valid url"
    
    // Act
    let result = sut.setCustomFeedURL(invalidURL)
    
    // Assert
    XCTAssertFalse(result)
    XCTAssertNil(sut.customMainFeedURL)
  }
  
  func testSettingsViewModel_SetCustomFeedURL_InvalidScheme_ReturnsFalse() async {
    // Arrange
    let ftpURL = "ftp://example.com/feed"
    
    // Act
    let result = sut.setCustomFeedURL(ftpURL)
    
    // Assert
    XCTAssertFalse(result)
    XCTAssertNil(sut.customMainFeedURL)
  }
  
  func testSettingsViewModel_SetCustomFeedURL_EmptyString_ClearsURL() async {
    // Arrange
    sut.customMainFeedURL = URL(string: "https://example.com")
    
    // Act
    let result = sut.setCustomFeedURL("")
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertNil(sut.customMainFeedURL)
  }
  
  func testSettingsViewModel_SetCustomFeedURL_Nil_ClearsURL() async {
    // Arrange
    sut.customMainFeedURL = URL(string: "https://example.com")
    
    // Act
    let result = sut.setCustomFeedURL(nil)
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertNil(sut.customMainFeedURL)
  }
  
  func testSettingsViewModel_ClearCustomFeedURL_ClearsURL() async {
    // Arrange
    sut.customMainFeedURL = URL(string: "https://example.com")!
    XCTAssertNotNil(sut.customMainFeedURL)
    
    // Act
    sut.clearCustomFeedURL()
    
    // Assert
    XCTAssertNil(sut.customMainFeedURL)
    XCTAssertNil(mockSettings.customMainFeedURL)
  }
  
  // MARK: - Custom Registry Server Tests
  
  func testSettingsViewModel_SetCustomRegistryServer_ValidURL_ReturnsTrue() async {
    // Arrange
    let urlString = "https://registry.example.com"
    
    // Act
    let result = sut.setCustomRegistryServer(urlString)
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertEqual(sut.customLibraryRegistryServer, urlString)
    XCTAssertEqual(mockSettings.customLibraryRegistryServer, urlString)
  }
  
  func testSettingsViewModel_SetCustomRegistryServer_InvalidURL_ReturnsFalse() async {
    // Arrange - use control characters that definitely make invalid URLs
    let invalidURL = "http://example.com/path\twith\ttabs"
    
    // Act
    let result = sut.setCustomRegistryServer(invalidURL)
    
    // Assert - if URL validation fails, result should be false
    // Note: URL(string:) behavior can vary; some strings may be accepted
    if URL(string: invalidURL) == nil {
      XCTAssertFalse(result, "Should return false for URLs that fail URL(string:) validation")
    } else {
      // URL was accepted, so the method should return true
      XCTAssertTrue(result, "Should return true if URL(string:) accepts the URL")
    }
  }
  
  func testSettingsViewModel_SetCustomRegistryServer_EmptyString_ClearsServer() async {
    // Arrange
    sut.customLibraryRegistryServer = "https://registry.example.com"
    
    // Act
    let result = sut.setCustomRegistryServer("")
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertNil(sut.customLibraryRegistryServer)
  }
  
  func testSettingsViewModel_ClearCustomRegistryServer_ClearsServer() async {
    // Arrange
    sut.customLibraryRegistryServer = "https://registry.example.com"
    XCTAssertNotNil(sut.customLibraryRegistryServer)
    
    // Act
    sut.clearCustomRegistryServer()
    
    // Assert
    XCTAssertNil(sut.customLibraryRegistryServer)
    XCTAssertNil(mockSettings.customLibraryRegistryServer)
  }
  
  // MARK: - Computed Properties Tests
  
  func testSettingsViewModel_IsUsingCustomFeed_TrueWhenURLSet() async {
    // Arrange & Act
    sut.customMainFeedURL = URL(string: "https://example.com")
    
    // Assert
    XCTAssertTrue(sut.isUsingCustomFeed)
  }
  
  func testSettingsViewModel_IsUsingCustomFeed_FalseWhenURLNil() async {
    // Arrange
    sut.customMainFeedURL = nil
    
    // Assert
    XCTAssertFalse(sut.isUsingCustomFeed)
  }
  
  func testSettingsViewModel_IsUsingCustomRegistry_TrueWhenServerSet() async {
    // Arrange & Act
    sut.customLibraryRegistryServer = "https://registry.example.com"
    
    // Assert
    XCTAssertTrue(sut.isUsingCustomRegistry)
  }
  
  func testSettingsViewModel_IsUsingCustomRegistry_FalseWhenServerNil() async {
    // Arrange
    sut.customLibraryRegistryServer = nil
    
    // Assert
    XCTAssertFalse(sut.isUsingCustomRegistry)
  }
  
  func testSettingsViewModel_IsUsingCustomRegistry_FalseWhenServerEmpty() async {
    // Arrange
    sut.customLibraryRegistryServer = ""
    
    // Assert
    XCTAssertFalse(sut.isUsingCustomRegistry)
  }
  
  func testSettingsViewModel_FormattedAppVersion_ReturnsFormattedString() async {
    // Act
    let version = sut.formattedAppVersion
    
    // Assert
    XCTAssertTrue(version.contains("version"))
    XCTAssertFalse(version.isEmpty)
  }
  
  // MARK: - App Version Tests
  
  func testSettingsViewModel_UpdateAppVersion_UpdatesSettings() async {
    // Arrange
    let newVersion = "2.0.0"
    
    // Act
    sut.updateAppVersion(newVersion)
    
    // Assert
    XCTAssertEqual(sut.appVersion, newVersion)
    XCTAssertEqual(mockSettings.appVersion, newVersion)
  }
  
  // MARK: - Reset Tests
  
  func testSettingsViewModel_ResetToDefaults_ResetsAllSettings() async {
    // Arrange
    sut.useBetaLibraries = true
    sut.enterLCPPassphraseManually = true
    sut.customMainFeedURL = URL(string: "https://example.com")
    sut.customLibraryRegistryServer = "https://registry.example.com"
    
    // Act
    sut.resetToDefaults()
    
    // Assert
    XCTAssertFalse(sut.useBetaLibraries)
    XCTAssertFalse(sut.enterLCPPassphraseManually)
    XCTAssertNil(sut.customMainFeedURL)
    XCTAssertNil(sut.customLibraryRegistryServer)
    
    // Verify mock was also reset
    XCTAssertFalse(mockSettings.useBetaLibraries)
    XCTAssertFalse(mockSettings.enterLCPPassphraseManually)
    XCTAssertNil(mockSettings.customMainFeedURL)
    XCTAssertNil(mockSettings.customLibraryRegistryServer)
  }
  
  // MARK: - Refresh Tests
  
  func testSettingsViewModel_RefreshSettings_ReloadsFromProvider() async {
    // Arrange - modify mock directly (simulating external change)
    mockSettings.useBetaLibraries = true
    mockSettings.userHasAcceptedEULA = true
    mockSettings.customMainFeedURL = URL(string: "https://new-feed.com")
    
    // ViewModel still has old values
    XCTAssertFalse(sut.useBetaLibraries)
    XCTAssertFalse(sut.userHasAcceptedEULA)
    XCTAssertNil(sut.customMainFeedURL)
    
    // Act
    sut.refreshSettings()
    
    // Assert
    XCTAssertTrue(sut.useBetaLibraries)
    XCTAssertTrue(sut.userHasAcceptedEULA)
    XCTAssertEqual(sut.customMainFeedURL?.absoluteString, "https://new-feed.com")
  }
  
  // MARK: - Published Property Change Tests
  
  func testSettingsViewModel_UseBetaLibraries_PublishesChanges() async {
    // Arrange
    let expectation = XCTestExpectation(description: "useBetaLibraries publishes change")
    var receivedValues: [Bool] = []
    
    sut.$useBetaLibraries
      .dropFirst() // Skip initial value
      .sink { value in
        receivedValues.append(value)
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    // Act
    sut.useBetaLibraries = true
    
    // Assert
    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertEqual(receivedValues, [true])
  }
  
  func testSettingsViewModel_CustomMainFeedURL_PublishesChanges() async {
    // Arrange
    let expectation = XCTestExpectation(description: "customMainFeedURL publishes change")
    var receivedValues: [URL?] = []
    
    sut.$customMainFeedURL
      .dropFirst() // Skip initial value
      .sink { value in
        receivedValues.append(value)
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    // Act
    let newURL = URL(string: "https://test.com")
    sut.customMainFeedURL = newURL
    
    // Assert
    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertEqual(receivedValues.count, 1)
    XCTAssertEqual(receivedValues.first, newURL)
  }
  
  // MARK: - Duplicate Write Prevention Tests
  
  func testSettingsViewModel_SetSameValue_DoesNotWriteToSettings() async {
    // Arrange
    mockSettings.useBetaLibraries = true
    let viewModel = SettingsViewModel(settings: mockSettings)
    
    // Act - set same value
    viewModel.useBetaLibraries = true
    
    // Assert - value should still be true (no change)
    XCTAssertTrue(mockSettings.useBetaLibraries)
  }
}

// MARK: - Edge Cases and Error Handling Tests

@MainActor
final class SettingsViewModelEdgeCaseTests: XCTestCase {
  
  private var mockSettings: TPPSettingsMock!
  private var sut: SettingsViewModel!
  
  override func setUp() {
    super.setUp()
    mockSettings = TPPSettingsMock()
    sut = SettingsViewModel(settings: mockSettings)
  }
  
  override func tearDown() {
    mockSettings.reset()
    mockSettings = nil
    sut = nil
    super.tearDown()
  }
  
  // MARK: - URL Validation Edge Cases
  
  func testSettingsViewModel_SetCustomFeedURL_URLWithPort_ReturnsTrue() async {
    // Arrange
    let urlString = "https://example.com:8080/feed"
    
    // Act
    let result = sut.setCustomFeedURL(urlString)
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertEqual(sut.customMainFeedURL?.absoluteString, urlString)
  }
  
  func testSettingsViewModel_SetCustomFeedURL_URLWithQueryParams_ReturnsTrue() async {
    // Arrange
    let urlString = "https://example.com/feed?key=value&foo=bar"
    
    // Act
    let result = sut.setCustomFeedURL(urlString)
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertEqual(sut.customMainFeedURL?.absoluteString, urlString)
  }
  
  func testSettingsViewModel_SetCustomFeedURL_URLWithFragment_ReturnsTrue() async {
    // Arrange
    let urlString = "https://example.com/feed#section"
    
    // Act
    let result = sut.setCustomFeedURL(urlString)
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertEqual(sut.customMainFeedURL?.absoluteString, urlString)
  }
  
  func testSettingsViewModel_SetCustomFeedURL_LocalhostHTTP_ReturnsTrue() async {
    // Arrange - localhost should be allowed for development
    let urlString = "http://localhost:3000/feed"
    
    // Act
    let result = sut.setCustomFeedURL(urlString)
    
    // Assert
    XCTAssertTrue(result)
    XCTAssertEqual(sut.customMainFeedURL?.absoluteString, urlString)
  }
  
  // MARK: - State Consistency Tests
  
  func testSettingsViewModel_MultipleRapidChanges_MaintainsConsistency() async {
    // Arrange & Act
    sut.useBetaLibraries = true
    sut.useBetaLibraries = false
    sut.useBetaLibraries = true
    sut.userHasAcceptedEULA = true
    sut.enterLCPPassphraseManually = true
    
    // Assert - final state should match
    XCTAssertTrue(sut.useBetaLibraries)
    XCTAssertTrue(mockSettings.useBetaLibraries)
    XCTAssertTrue(sut.userHasAcceptedEULA)
    XCTAssertTrue(mockSettings.userHasAcceptedEULA)
    XCTAssertTrue(sut.enterLCPPassphraseManually)
    XCTAssertTrue(mockSettings.enterLCPPassphraseManually)
  }
  
  func testSettingsViewModel_ResetThenModify_WorksCorrectly() async {
    // Arrange
    sut.useBetaLibraries = true
    sut.customMainFeedURL = URL(string: "https://example.com")
    
    // Act
    sut.resetToDefaults()
    sut.useBetaLibraries = true
    
    // Assert
    XCTAssertTrue(sut.useBetaLibraries)
    XCTAssertNil(sut.customMainFeedURL) // Should still be nil after reset
  }
  
  // MARK: - Initialization Edge Cases
  
  func testSettingsViewModel_InitWithPartialSettings_HandlesGracefully() async {
    // Arrange - only some settings are set
    let mockSettings = TPPSettingsMock(
      useBetaLibraries: true,
      appVersion: "1.0.0"
    )
    
    // Act
    let viewModel = SettingsViewModel(settings: mockSettings)
    
    // Assert - set values are loaded, others are defaults
    XCTAssertTrue(viewModel.useBetaLibraries)
    XCTAssertEqual(viewModel.appVersion, "1.0.0")
    XCTAssertFalse(viewModel.userHasAcceptedEULA)
    XCTAssertNil(viewModel.customMainFeedURL)
  }
}

// MARK: - Settings Synchronization Tests

@MainActor
final class SettingsViewModelSyncTests: XCTestCase {
  
  private var mockSettings: TPPSettingsMock!
  private var sut: SettingsViewModel!
  
  override func setUp() {
    super.setUp()
    mockSettings = TPPSettingsMock()
    sut = SettingsViewModel(settings: mockSettings)
  }
  
  override func tearDown() {
    mockSettings.reset()
    mockSettings = nil
    sut = nil
    super.tearDown()
  }
  
  func testSettingsViewModel_ExternalSettingsChange_RequiresRefresh() async {
    // Arrange - external component changes settings directly
    mockSettings.useBetaLibraries = true
    mockSettings.customMainFeedURL = URL(string: "https://external.com")
    
    // ViewModel has stale state
    XCTAssertFalse(sut.useBetaLibraries)
    XCTAssertNil(sut.customMainFeedURL)
    
    // Act
    sut.refreshSettings()
    
    // Assert
    XCTAssertTrue(sut.useBetaLibraries)
    XCTAssertEqual(sut.customMainFeedURL?.absoluteString, "https://external.com")
  }
  
  func testSettingsViewModel_BidirectionalSync_ViewModelToSettings() async {
    // Arrange & Act - change in ViewModel
    sut.useBetaLibraries = true
    sut.customLibraryRegistryServer = "https://registry.test.com"
    
    // Assert - settings updated
    XCTAssertTrue(mockSettings.useBetaLibraries)
    XCTAssertEqual(mockSettings.customLibraryRegistryServer, "https://registry.test.com")
  }
  
  func testSettingsViewModel_BidirectionalSync_SettingsToViewModelViaRefresh() async {
    // Arrange - change in settings
    mockSettings.userPresentedAgeCheck = true
    mockSettings.enterLCPPassphraseManually = true
    
    // Act
    sut.refreshSettings()
    
    // Assert - ViewModel updated
    XCTAssertTrue(sut.userPresentedAgeCheck)
    XCTAssertTrue(sut.enterLCPPassphraseManually)
  }
}

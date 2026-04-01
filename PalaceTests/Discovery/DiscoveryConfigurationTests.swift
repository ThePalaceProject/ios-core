//
//  DiscoveryConfigurationTests.swift
//  PalaceTests
//
//  Tests for DefaultDiscoveryConfiguration reading from UserDefaults and environment.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class DiscoveryConfigurationTests: XCTestCase {

  private let apiKeyDefaultsKey = "DiscoveryClaudeAPIKey"
  private let endpointDefaultsKey = "DiscoveryClaudeEndpoint"
  private let modelDefaultsKey = "DiscoveryClaudeModel"
  private let enabledDefaultsKey = "DiscoveryFeatureEnabled"

  override func tearDown() {
    // Clean up UserDefaults after each test
    UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
    UserDefaults.standard.removeObject(forKey: endpointDefaultsKey)
    UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
    UserDefaults.standard.removeObject(forKey: enabledDefaultsKey)
    super.tearDown()
  }

  // MARK: - API Key

  func testApiKey_ReturnsNil_WhenNothingConfigured() {
    UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
    let config = DefaultDiscoveryConfiguration()
    // This will also check env and Info.plist, but for a clean test environment
    // we verify the UserDefaults path returns nil when not set
    // (Environment may or may not have CLAUDE_API_KEY set)
    if ProcessInfo.processInfo.environment["CLAUDE_API_KEY"] == nil {
      XCTAssertNil(config.apiKey)
    }
  }

  func testApiKey_ReadsFromUserDefaults() {
    UserDefaults.standard.set("test-key-123", forKey: apiKeyDefaultsKey)
    let config = DefaultDiscoveryConfiguration()

    XCTAssertEqual(config.apiKey, "test-key-123")
  }

  func testApiKey_UserDefaultsTakesPrecedenceOverEnvironment() {
    UserDefaults.standard.set("defaults-key", forKey: apiKeyDefaultsKey)
    let config = DefaultDiscoveryConfiguration()

    // UserDefaults should always be checked first
    XCTAssertEqual(config.apiKey, "defaults-key")
  }

  func testApiKey_IgnoresEmptyStringInUserDefaults() {
    UserDefaults.standard.set("", forKey: apiKeyDefaultsKey)
    let config = DefaultDiscoveryConfiguration()

    // Empty string should be treated as not set
    if ProcessInfo.processInfo.environment["CLAUDE_API_KEY"] == nil {
      XCTAssertNil(config.apiKey)
    }
  }

  func testSetAPIKey_PersistsToUserDefaults() {
    DefaultDiscoveryConfiguration.setAPIKey("persisted-key")

    let stored = UserDefaults.standard.string(forKey: apiKeyDefaultsKey)
    XCTAssertEqual(stored, "persisted-key")
  }

  func testSetAPIKey_Nil_RemovesFromUserDefaults() {
    UserDefaults.standard.set("existing", forKey: apiKeyDefaultsKey)
    DefaultDiscoveryConfiguration.setAPIKey(nil)

    let stored = UserDefaults.standard.string(forKey: apiKeyDefaultsKey)
    XCTAssertNil(stored)
  }

  // MARK: - Endpoint

  func testEndpoint_DefaultValue() {
    let config = DefaultDiscoveryConfiguration()

    XCTAssertEqual(config.endpoint.absoluteString, "https://api.anthropic.com/v1/messages")
  }

  func testSetEndpoint_PersistsToUserDefaults() {
    let customURL = URL(string: "https://custom.api.example.com/v1")!
    DefaultDiscoveryConfiguration.setEndpoint(customURL)

    let config = DefaultDiscoveryConfiguration()
    XCTAssertEqual(config.endpoint, customURL)
  }

  func testSetEndpoint_Nil_RestoresDefault() {
    DefaultDiscoveryConfiguration.setEndpoint(URL(string: "https://custom.example.com")!)
    DefaultDiscoveryConfiguration.setEndpoint(nil)

    let config = DefaultDiscoveryConfiguration()
    XCTAssertEqual(config.endpoint.absoluteString, "https://api.anthropic.com/v1/messages")
  }

  // MARK: - Model

  func testModel_DefaultValue() {
    let config = DefaultDiscoveryConfiguration()

    XCTAssertEqual(config.model, "claude-sonnet-4-20250514")
  }

  func testSetModel_PersistsToUserDefaults() {
    DefaultDiscoveryConfiguration.setModel("claude-opus-4-20250514")

    let config = DefaultDiscoveryConfiguration()
    XCTAssertEqual(config.model, "claude-opus-4-20250514")
  }

  func testSetModel_Nil_RestoresDefault() {
    DefaultDiscoveryConfiguration.setModel("custom-model")
    DefaultDiscoveryConfiguration.setModel(nil)

    let config = DefaultDiscoveryConfiguration()
    XCTAssertEqual(config.model, "claude-sonnet-4-20250514")
  }

  // MARK: - isEnabled

  func testIsEnabled_DefaultValue() {
    let config = DefaultDiscoveryConfiguration()

    XCTAssertTrue(config.isEnabled)
  }

  func testSetEnabled_PersistsToUserDefaults() {
    DefaultDiscoveryConfiguration.setEnabled(false)

    let config = DefaultDiscoveryConfiguration()
    XCTAssertFalse(config.isEnabled)
  }

  func testSetEnabled_True_PersistsToUserDefaults() {
    DefaultDiscoveryConfiguration.setEnabled(false)
    DefaultDiscoveryConfiguration.setEnabled(true)

    let config = DefaultDiscoveryConfiguration()
    XCTAssertTrue(config.isEnabled)
  }

  // MARK: - isAIAvailable

  func testIsAIAvailable_TrueWhenKeySetAndEnabled() {
    UserDefaults.standard.set("some-key", forKey: apiKeyDefaultsKey)
    DefaultDiscoveryConfiguration.setEnabled(true)

    let config = DefaultDiscoveryConfiguration()
    XCTAssertTrue(config.isAIAvailable)
  }

  func testIsAIAvailable_FalseWhenNoKey() {
    UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
    if ProcessInfo.processInfo.environment["CLAUDE_API_KEY"] == nil {
      let config = DefaultDiscoveryConfiguration()
      XCTAssertFalse(config.isAIAvailable)
    }
  }

  func testIsAIAvailable_FalseWhenDisabled() {
    UserDefaults.standard.set("some-key", forKey: apiKeyDefaultsKey)
    DefaultDiscoveryConfiguration.setEnabled(false)

    let config = DefaultDiscoveryConfiguration()
    XCTAssertFalse(config.isAIAvailable)
  }

  // MARK: - Constants

  func testMaxRecommendations_DefaultValue() {
    let config = DefaultDiscoveryConfiguration()
    XCTAssertEqual(config.maxRecommendations, 20)
  }

  func testRequestTimeout_DefaultValue() {
    let config = DefaultDiscoveryConfiguration()
    XCTAssertEqual(config.requestTimeout, 30)
  }
}

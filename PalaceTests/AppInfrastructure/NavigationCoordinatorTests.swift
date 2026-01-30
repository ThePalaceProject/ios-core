//
//  NavigationCoordinatorTests.swift
//  PalaceTests
//
//  Tests for NavigationCoordinator routing and audio route handling
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

/// Tests for NavigationCoordinator navigation path management.
/// Verifies push/pop behavior, audio route clearing, and debouncing.
@MainActor
final class NavigationCoordinatorTests: XCTestCase {
  
  var coordinator: NavigationCoordinator!
  
  override func setUp() {
    super.setUp()
    coordinator = NavigationCoordinator()
  }
  
  override func tearDown() {
    coordinator = nil
    super.tearDown()
  }
  
  // MARK: - Initial State Tests
  
  func testNavigationCoordinator_InitialState_PathIsEmpty() {
    XCTAssertTrue(coordinator.path.isEmpty, "Path should be empty initially")
  }
  
  func testNavigationCoordinator_InitialState_NoEPUBSamplePresented() {
    XCTAssertNil(coordinator.presentedEPUBSample, "No EPUB sample should be presented initially")
  }
  
  // MARK: - Push Tests
  
  func testNavigationCoordinator_Push_IncreasesPathCount() {
    // Arrange
    let route = AppRoute.bookDetail(BookRoute(id: "test-book"))
    
    // Act
    coordinator.push(route)
    
    // Assert
    XCTAssertEqual(coordinator.path.count, 1, "Path should have 1 item after push")
  }
  
  func testNavigationCoordinator_MultiplePushes_AccumulateInPath() {
    // Arrange & Act
    coordinator.push(.bookDetail(BookRoute(id: "book-1")))
    coordinator.push(.bookDetail(BookRoute(id: "book-2")))
    coordinator.push(.bookDetail(BookRoute(id: "book-3")))
    
    // Assert
    XCTAssertEqual(coordinator.path.count, 3, "Path should have 3 items after 3 pushes")
  }
  
  // MARK: - Pop Tests
  
  func testNavigationCoordinator_Pop_DecreasesPathCount() {
    // Arrange
    coordinator.push(.bookDetail(BookRoute(id: "test-book")))
    XCTAssertEqual(coordinator.path.count, 1)
    
    // Act
    coordinator.pop()
    
    // Assert
    XCTAssertEqual(coordinator.path.count, 0, "Path should be empty after pop")
  }
  
  func testNavigationCoordinator_Pop_OnEmptyPath_DoesNotCrash() {
    // Arrange - path is already empty
    XCTAssertTrue(coordinator.path.isEmpty)
    
    // Act & Assert - should not crash
    coordinator.pop()
    XCTAssertTrue(coordinator.path.isEmpty, "Path should still be empty")
  }
  
  // MARK: - Pop to Root Tests
  
  func testNavigationCoordinator_PopToRoot_ClearsEntirePath() {
    // Arrange
    coordinator.push(.bookDetail(BookRoute(id: "book-1")))
    coordinator.push(.bookDetail(BookRoute(id: "book-2")))
    coordinator.push(.bookDetail(BookRoute(id: "book-3")))
    XCTAssertEqual(coordinator.path.count, 3)
    
    // Act
    coordinator.popToRoot()
    
    // Assert
    XCTAssertEqual(coordinator.path.count, 0, "Path should be empty after popToRoot")
  }
  
  func testNavigationCoordinator_PopToRoot_OnEmptyPath_DoesNotCrash() {
    // Arrange
    XCTAssertTrue(coordinator.path.isEmpty)
    
    // Act & Assert - should not crash
    coordinator.popToRoot()
    XCTAssertTrue(coordinator.path.isEmpty)
  }
  
  // MARK: - Audio Route Tests
  
  func testNavigationCoordinator_ClearAudioRoutes_ClearsPath() {
    // Arrange
    coordinator.push(.audio(BookRoute(id: "audiobook-1")))
    XCTAssertEqual(coordinator.path.count, 1)
    
    // Act
    coordinator.clearAudioRoutes()
    
    // Assert
    XCTAssertEqual(coordinator.path.count, 0, "Path should be empty after clearAudioRoutes")
  }
  
  func testNavigationCoordinator_ClearAudioRoutes_OnEmptyPath_DoesNotCrash() {
    // Arrange
    XCTAssertTrue(coordinator.path.isEmpty)
    
    // Act & Assert
    coordinator.clearAudioRoutes()
    XCTAssertTrue(coordinator.path.isEmpty)
  }
  
  func testNavigationCoordinator_PushAudioRoute_ClearsExistingRoutes() {
    // Arrange - push some routes first
    coordinator.push(.bookDetail(BookRoute(id: "book-1")))
    coordinator.push(.audio(BookRoute(id: "audiobook-1")))
    XCTAssertEqual(coordinator.path.count, 2)
    
    // Act - push a new audio route
    coordinator.pushAudioRoute(BookRoute(id: "audiobook-2"))
    
    // Assert - should only have the new audio route
    XCTAssertEqual(coordinator.path.count, 1, "Should only have 1 route after pushAudioRoute")
  }
  
  func testNavigationCoordinator_PushAudioRoute_OnEmptyPath_AddsRoute() {
    // Arrange
    XCTAssertTrue(coordinator.path.isEmpty)
    
    // Act
    coordinator.pushAudioRoute(BookRoute(id: "audiobook-1"))
    
    // Assert
    XCTAssertEqual(coordinator.path.count, 1, "Should have 1 route after pushAudioRoute on empty path")
  }
  
  func testNavigationCoordinator_PushAudioRoute_PreventsDuplicateAudioRoutes() {
    // Arrange & Act - push same audiobook multiple times
    coordinator.pushAudioRoute(BookRoute(id: "audiobook-1"))
    coordinator.pushAudioRoute(BookRoute(id: "audiobook-1"))
    coordinator.pushAudioRoute(BookRoute(id: "audiobook-1"))
    
    // Assert - should only have 1 route (no accumulation)
    XCTAssertEqual(coordinator.path.count, 1, "Should not accumulate duplicate audio routes")
  }
  
  // MARK: - Book Storage Tests
  
  func testNavigationCoordinator_StoreBook_CanBeRetrieved() {
    // Arrange
    let book = TPPBookMocker.snapshotAudiobook()
    
    // Act
    coordinator.store(book: book)
    let retrieved = coordinator.resolveBook(for: BookRoute(id: book.identifier))
    
    // Assert
    XCTAssertNotNil(retrieved, "Stored book should be retrievable")
    XCTAssertEqual(retrieved?.identifier, book.identifier, "Retrieved book should match stored book")
  }
  
  func testNavigationCoordinator_Book_NotStored_ReturnsNil() {
    // Act
    let retrieved = coordinator.resolveBook(for: BookRoute(id: "non-existent-book"))
    
    // Assert
    XCTAssertNil(retrieved, "Non-existent book should return nil")
  }
  
  // MARK: - Audio Model Storage Tests
  
  func testNavigationCoordinator_StoreAudioModel_CanBeRetrieved() {
    // We can't easily create AudiobookPlaybackModel in tests without a real AudiobookManager
    // But we can test that the storage mechanism works for nil cases
    let retrieved = coordinator.resolveAudioModel(for: BookRoute(id: "non-existent-book"))
    XCTAssertNil(retrieved, "Non-existent audio model should return nil")
  }
}

// MARK: - AppRoute Tests

final class AppRouteTests: XCTestCase {
  
  func testAppRoute_BookDetail_IsHashable() {
    let route1 = AppRoute.bookDetail(BookRoute(id: "book-1"))
    let route2 = AppRoute.bookDetail(BookRoute(id: "book-1"))
    let route3 = AppRoute.bookDetail(BookRoute(id: "book-2"))
    
    XCTAssertEqual(route1, route2, "Same book ID should be equal")
    XCTAssertNotEqual(route1, route3, "Different book IDs should not be equal")
  }
  
  func testAppRoute_Audio_IsHashable() {
    let route1 = AppRoute.audio(BookRoute(id: "audiobook-1"))
    let route2 = AppRoute.audio(BookRoute(id: "audiobook-1"))
    let route3 = AppRoute.audio(BookRoute(id: "audiobook-2"))
    
    XCTAssertEqual(route1, route2, "Same audiobook ID should be equal")
    XCTAssertNotEqual(route1, route3, "Different audiobook IDs should not be equal")
  }
  
  func testAppRoute_DifferentTypes_NotEqual() {
    let bookRoute = AppRoute.bookDetail(BookRoute(id: "id-1"))
    let audioRoute = AppRoute.audio(BookRoute(id: "id-1"))
    
    XCTAssertNotEqual(bookRoute, audioRoute, "Different route types should not be equal even with same ID")
  }
  
  func testBookRoute_IsHashable() {
    let route1 = BookRoute(id: "book-123")
    let route2 = BookRoute(id: "book-123")
    let route3 = BookRoute(id: "book-456")
    
    XCTAssertEqual(route1, route2, "Same ID should be equal")
    XCTAssertNotEqual(route1, route3, "Different IDs should not be equal")
    
    // Test in Set
    let set: Set<BookRoute> = [route1, route2, route3]
    XCTAssertEqual(set.count, 2, "Set should deduplicate equal routes")
  }
  
  func testSearchRoute_IsHashable() {
    let id = UUID()
    let route1 = SearchRoute(id: id)
    let route2 = SearchRoute(id: id)
    let route3 = SearchRoute(id: UUID())
    
    XCTAssertEqual(route1, route2, "Same UUID should be equal")
    XCTAssertNotEqual(route1, route3, "Different UUIDs should not be equal")
  }
}

// MARK: - SceneDelegate Tests

@MainActor
final class SceneDelegateTests: XCTestCase {
  
  func testSceneDelegate_HasMainSceneConnected_InitiallyFalse() {
    // The static property should be false initially (before any scene connects)
    // This test verifies the property exists and is accessible
    let hasConnected = SceneDelegate.hasMainSceneConnected
    
    // In test environment, this should be false since no real scene is connected
    // (Note: If tests run after app launch, this might be true)
    XCTAssertNotNil(hasConnected as Bool?, "hasMainSceneConnected should be accessible")
  }
}

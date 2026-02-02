//
//  KeyboardNavigationHandler.swift
//  Palace
//
//  Handles keyboard events for EPUB reader navigation.
//  Implements PP-3594: iOS keyboard accessibility controls.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumNavigator

/// Protocol defining keyboard navigation capabilities for the reader
@MainActor
protocol KeyboardNavigable: AnyObject {
  /// Whether the navigation bar (toolbar) is currently hidden
  var isToolbarHidden: Bool { get }
  
  /// Toggles the toolbar visibility
  func toggleToolbar()
  
  /// Navigates to the left page
  func navigateLeft() async -> Bool
  
  /// Navigates to the right page
  func navigateRight() async -> Bool
  
  /// Navigates forward in reading progression
  func navigateForward() async -> Bool
}

/// Handles keyboard events for EPUB reader navigation
/// Extracted for testability per TDD requirements
@MainActor
final class KeyboardNavigationHandler {
  
  // MARK: - Properties
  
  private weak var navigable: KeyboardNavigable?
  
  // MARK: - Initialization
  
  init(navigable: KeyboardNavigable) {
    self.navigable = navigable
  }
  
  // MARK: - Keyboard Event Handling
  
  /// Handles a keyboard event from the navigator
  /// - Parameter event: The key event to handle
  /// - Returns: Whether the event was consumed
  @discardableResult
  func handleKeyEvent(_ event: KeyEvent) async -> Bool {
    // Only handle key down events
    guard event.phase == .down else { return false }
    
    // Ignore events with modifiers (allow system shortcuts like Cmd+C)
    guard event.modifiers.isEmpty else { return false }
    
    guard let navigable = navigable else { return false }
    
    switch event.key {
    case .escape:
      // Escape toggles toolbar visibility (AC2.1, AC2.2)
      navigable.toggleToolbar()
      return true
      
    case .arrowLeft:
      // Left arrow navigates to previous page when toolbar is hidden (AC3.2)
      guard navigable.isToolbarHidden else { return false }
      return await navigable.navigateLeft()
      
    case .arrowRight:
      // Right arrow navigates to next page when toolbar is hidden (AC3.1)
      guard navigable.isToolbarHidden else { return false }
      return await navigable.navigateRight()
      
    case .space:
      // Space advances forward when toolbar is hidden
      guard navigable.isToolbarHidden else { return false }
      return await navigable.navigateForward()
      
    case .pageDown:
      // Page Down advances forward when toolbar is hidden
      guard navigable.isToolbarHidden else { return false }
      return await navigable.navigateForward()
      
    case .pageUp:
      // Page Up goes backward when toolbar is hidden
      guard navigable.isToolbarHidden else { return false }
      return await navigable.navigateLeft()
      
    default:
      return false
    }
  }
}

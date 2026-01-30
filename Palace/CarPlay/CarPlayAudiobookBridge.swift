//
//  CarPlayAudiobookBridge.swift
//  Palace
//
//  Thin adapter bridging CarPlay UI to AudiobookSessionManager.
//  All state management is delegated to AudiobookSessionManager.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import MediaPlayer
import PalaceAudiobookToolkit
import UIKit

// MARK: - CarPlayPlaybackError

/// Error types for CarPlay playback failures
enum CarPlayPlaybackError: Error {
  case authenticationRequired
  case networkError
  case drmError
  case notDownloaded
  case unknown
  
  init(from sessionError: AudiobookSessionError) {
    switch sessionError {
    case .notAuthenticated:
      self = .authenticationRequired
    case .notDownloaded:
      self = .notDownloaded
    case .networkUnavailable:
      self = .networkError
    default:
      self = .unknown
    }
  }
}

// MARK: - CarPlayAuthHelper

/// Shared authentication helper for CarPlay components.
enum CarPlayAuthHelper {
  /// Checks if the user is authenticated with the current library.
  static func isAuthenticated() -> Bool {
    guard let account = AccountsManager.shared.currentAccount else {
      return false
    }
    
    guard let details = account.details,
          let defaultAuth = details.defaultAuth else {
      return true
    }
    
    if !defaultAuth.needsAuth {
      return true
    }
    
    return TPPUserAccount.sharedAccount().hasCredentials()
  }
}

// MARK: - CarPlayAudiobookBridge

/// Thin adapter bridging CarPlay UI to AudiobookSessionManager.
/// Provides CarPlay-specific publishers and convenience methods.
@MainActor
final class CarPlayAudiobookBridge: ObservableObject {
  
  // MARK: - Types
  
  typealias PlaybackResult = Result<Void, CarPlayPlaybackError>
  typealias PlaybackCompletion = (PlaybackResult) -> Void
  
  enum PlaybackState {
    case playing
    case paused
    case stopped
  }
  
  // MARK: - Properties
  
  private let sessionManager: AudiobookSessionManager
  private var cancellables = Set<AnyCancellable>()
  
  /// Publisher for CarPlay UI to observe playback state changes
  let playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
  
  /// Publisher for chapter updates
  let chapterUpdatePublisher = PassthroughSubject<[Chapter], Never>()
  
  /// Publisher for errors
  let errorPublisher = PassthroughSubject<CarPlayPlaybackError, Never>()
  
  // MARK: - Computed Properties
  
  var currentBook: TPPBook? {
    sessionManager.currentBook
  }
  
  var currentChapters: [Chapter]? {
    sessionManager.currentChapters.isEmpty ? nil : sessionManager.currentChapters
  }
  
  var currentChapter: Chapter? {
    sessionManager.currentChapter
  }
  
  var isPlaying: Bool {
    sessionManager.isPlaying
  }
  
  // MARK: - Initialization
  
  init(sessionManager: AudiobookSessionManager = .shared) {
    self.sessionManager = sessionManager
    setupSubscriptions()
    Log.info(#file, "CarPlayAudiobookBridge initialized")
  }
  
  // MARK: - Public API
  
  /// Initiates audiobook playback for CarPlay
  func playAudiobook(_ book: TPPBook, completion: @escaping PlaybackCompletion) {
    Log.info(#file, "CarPlay: Starting playback for '\(book.title)'")
    
    Task {
      let result = await sessionManager.openAudiobook(book, startPlaying: true)
      
      switch result {
      case .success:
        Log.info(#file, "CarPlay: Playback started successfully")
        completion(.success(()))
        
      case .failure(let error):
        Log.error(#file, "CarPlay: Playback failed - \(error.localizedDescription)")
        let carPlayError = CarPlayPlaybackError(from: error)
        completion(.failure(carPlayError))
      }
    }
  }
  
  /// Resumes playback
  func play() {
    sessionManager.play()
  }
  
  /// Pauses playback
  func pause() {
    sessionManager.pause()
  }
  
  /// Cycles through playback rates
  func cyclePlaybackRate() {
    _ = sessionManager.cyclePlaybackRate()
  }
  
  /// Skips to a specific chapter
  func skipToChapter(at index: Int) {
    sessionManager.skipToChapter(at: index)
  }
  
  /// Stops playback and cleans up.
  /// Note: This does NOT dismiss the phone UI - the user may want to continue using the phone app.
  /// Phone UI is only dismissed when switching to a different book (handled in openAudiobook).
  func stopCurrentPlayback() {
    Task {
      await sessionManager.stopPlayback(dismissPhoneUI: false)
    }
    Log.info(#file, "CarPlay: Stopped playback")
  }
  
  /// Dismisses the audiobook view on the phone
  func dismissBookOnPhone() {
    Task {
      if let coordinator = NavigationCoordinatorHub.shared.coordinator,
         let bookId = currentBook?.identifier {
        Log.info(#file, "CarPlay: Dismissing book view on phone")
        coordinator.removeAudioModel(forBookId: bookId)
        coordinator.popToRoot()
      }
    }
  }
  
  /// Checks if user is authenticated
  func isAuthenticated() -> Bool {
    CarPlayAuthHelper.isAuthenticated()
  }
  
  // MARK: - Private Methods
  
  private func setupSubscriptions() {
    // Subscribe to session manager state changes
    sessionManager.playbackStatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.handleSessionState(state)
      }
      .store(in: &cancellables)
    
    // Subscribe to chapter updates
    sessionManager.chapterUpdatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] (chapters, _) in
        self?.chapterUpdatePublisher.send(chapters)
      }
      .store(in: &cancellables)
    
    // Subscribe to errors
    sessionManager.errorPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] error in
        self?.errorPublisher.send(CarPlayPlaybackError(from: error))
      }
      .store(in: &cancellables)
  }
  
  private func handleSessionState(_ state: AudiobookSessionState) {
    switch state {
    case .playing:
      Log.debug(#file, "CarPlay: State changed to playing")
      playbackStatePublisher.send(.playing)
      
    case .paused:
      Log.debug(#file, "CarPlay: State changed to paused")
      playbackStatePublisher.send(.paused)
      
    case .idle, .error:
      Log.debug(#file, "CarPlay: State changed to stopped")
      playbackStatePublisher.send(.stopped)
      
    case .loading:
      Log.debug(#file, "CarPlay: State changed to loading")
      // Don't send state change for loading - wait for actual playback
      break
    }
  }
}

// MARK: - NavigationCoordinator Extension

extension NavigationCoordinator {
  /// Retrieves the stored AudiobookPlaybackModel for a given book ID
  func getAudioModel(forBookId bookId: String) -> AudiobookPlaybackModel? {
    resolveAudioModel(for: BookRoute(id: bookId))
  }
}

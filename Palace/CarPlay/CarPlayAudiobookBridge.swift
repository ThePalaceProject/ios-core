//
//  CarPlayAudiobookBridge.swift
//  Palace
//
//  Created for CarPlay audiobook support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import MediaPlayer
import PalaceAudiobookToolkit
import UIKit

/// Error types for CarPlay playback failures
enum CarPlayPlaybackError: Error {
  case authenticationRequired
  case networkError
  case drmError
  case notDownloaded
  case unknown
}

// MARK: - Shared Authentication Helper

/// Shared authentication helper for CarPlay components.
/// Centralizes auth logic to avoid duplication between CarPlayTemplateManager and CarPlayAudiobookBridge.
enum CarPlayAuthHelper {
  /// Checks if the user is authenticated with the current library.
  /// Note: If tokens need refresh, the app's auth layer handles this automatically.
  /// CarPlay cannot show sign-in UI - users must sign in via the phone app.
  static func isAuthenticated() -> Bool {
    guard let account = AccountsManager.shared.currentAccount else {
      return false
    }
    
    // If library doesn't require authentication, allow access
    guard let details = account.details,
          let defaultAuth = details.defaultAuth else {
      // No details or auth available - allow access (might be loading or anonymous)
      return true
    }
    
    // Check if the default auth method requires authentication
    if !defaultAuth.needsAuth {
      return true
    }
    
    // Check if user has valid credentials
    // Token refresh is handled automatically by the auth layer when making API calls
    return TPPUserAccount.sharedAccount().hasCredentials()
  }
}

/// Bridges CarPlay controls to the existing AudiobookManager infrastructure
/// Handles playback initiation, state synchronization, and chapter navigation
final class CarPlayAudiobookBridge {
  
  // MARK: - Types
  
  typealias PlaybackResult = Result<Void, CarPlayPlaybackError>
  typealias PlaybackCompletion = (PlaybackResult) -> Void
  
  enum PlaybackState {
    case playing
    case paused
    case stopped
  }
  
  // MARK: - Properties
  
  private(set) var currentBook: TPPBook?
  private(set) var currentManager: AudiobookManager?
  private(set) var currentChapters: [Chapter]?
  private(set) var currentChapter: Chapter?
  
  private var globalCancellables = Set<AnyCancellable>()  // For app-wide subscriptions (AudiobookEvents)
  private var bookCancellables = Set<AnyCancellable>()    // For per-book subscriptions (manager state, position)
  private var pendingStopWorkItem: DispatchWorkItem?
  
  /// Publisher that emits when chapter list updates
  let chapterUpdatePublisher = PassthroughSubject<[Chapter], Never>()
  
  /// Publisher that emits current playback state
  let playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
  
  /// Publisher that emits playback errors
  let errorPublisher = PassthroughSubject<CarPlayPlaybackError, Never>()
  
  // MARK: - Available Playback Rates
  
  private let availableRates: [PlaybackRate] = [
    .threeQuartersTime,
    .normalTime,
    .oneAndAQuarterTime,
    .oneAndAHalfTime,
    .doubleTime
  ]
  private var currentRateIndex: Int = 1 // Start at normal speed
  
  // MARK: - Initialization
  
  init() {
    subscribeToGlobalPlayback()
  }
  
  /// Initiates audiobook playback for CarPlay
  /// - Parameters:
  ///   - book: The audiobook to play
  ///   - completion: Called with success/failure result
  func playAudiobook(_ book: TPPBook, completion: @escaping PlaybackCompletion) {
    Log.info(#file, "CarPlay: Starting playback for '\(book.title)'")
    
    currentBook = book
    
    // Pre-flight checks
    if let error = validatePlaybackRequirements(for: book) {
      Log.error(#file, "CarPlay: Pre-flight check failed: \(error)")
      completion(.failure(error))
      return
    }
    
    // Set up a one-time listener for playback to actually begin
    // This will be triggered when the toolkit starts playing after position sync
    var playbackStartedCancellable: AnyCancellable?
    playbackStartedCancellable = playbackStatePublisher
      .first { state in
        if case .playing = state { return true }
        return false
      }
      .sink { _ in
        Log.info(#file, "CarPlay: Detected playback started - Now Playing should show playing state")
        playbackStartedCancellable?.cancel()
      }
    
    // Thread-safe completion state tracking
    let completionState = PlaybackCompletionState()
    
    // Set up timeout for playback start
    let timeoutWorkItem = DispatchWorkItem { [weak self] in
      guard completionState.tryComplete() else { return }
      playbackStartedCancellable?.cancel()
      Log.error(#file, "CarPlay: Playback timed out for '\(book.title)'")
      self?.currentBook = nil
      completion(.failure(.unknown))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: timeoutWorkItem)
    
    // Use BookService to handle the complex audiobook opening logic
    // This handles DRM, manifest fetching, position restoration, etc.
    // Note: BookService.open calls completion BEFORE playback actually starts
    // (playback starts after async position sync completes)
    BookService.open(book) { [weak self] in
      guard !completionState.isCompleted else { return }
      
      guard let self = self else {
        guard completionState.tryComplete() else { return }
        timeoutWorkItem.cancel()
        playbackStartedCancellable?.cancel()
        completion(.failure(.unknown))
        return
      }
      
      // After BookService opens the book, we need to get a reference to the manager
      // The manager is stored in the navigation coordinator
      // Give time for the view to be pushed and manager to be stored
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard completionState.tryComplete() else { return }
        
        self.linkToActiveAudiobook()
        
        // Explicitly call play() to ensure CarPlay is properly synced
        // This triggers the remote command path which properly sets up CarPlay
        if let manager = self.currentManager {
          timeoutWorkItem.cancel()
          
          Log.info(#file, "CarPlay: Linked to manager, explicitly starting playback...")
          manager.play()
          // Force the Now Playing state after a brief delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.forcePlayingStateForCarPlay()
          }
          completion(.success(()))
        } else {
          timeoutWorkItem.cancel()
          Log.warn(#file, "CarPlay: Could not link to manager")
          completion(.failure(.unknown))
        }
      }
    }
  }
  
  /// Thread-safe state tracker for playback completion
  private class PlaybackCompletionState {
    private let lock = NSLock()
    private var _isCompleted = false
    
    var isCompleted: Bool {
      lock.lock()
      defer { lock.unlock() }
      return _isCompleted
    }
    
    /// Attempts to mark as completed. Returns true if this call completed it, false if already completed.
    func tryComplete() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if _isCompleted { return false }
      _isCompleted = true
      return true
    }
  }
  
  /// Validates that all requirements are met before attempting playback
  private func validatePlaybackRequirements(for book: TPPBook) -> CarPlayPlaybackError? {
    // Check authentication
    if !isAuthenticated() {
      return .authenticationRequired
    }
    
    // Check book state
    let state = TPPBookRegistry.shared.state(for: book.identifier)
    if state == .unregistered || state == .downloadNeeded {
      return .notDownloaded
    }
    
    // Check network for partially downloaded content
    let isFullyDownloaded = state == .downloadSuccessful || state == .used
    if !isFullyDownloaded && !Reachability.shared.isConnectedToNetwork() {
      return .networkError
    }
    
    return nil
  }
  
  /// Checks if user is authenticated with the current library
  private func isAuthenticated() -> Bool {
    CarPlayAuthHelper.isAuthenticated()
  }
  
  /// Cycles through available playback rates
  func cyclePlaybackRate() {
    guard let manager = currentManager else { return }
    
    currentRateIndex = (currentRateIndex + 1) % availableRates.count
    let newRate = availableRates[currentRateIndex]
    
    manager.audiobook.player.playbackRate = newRate
    
    Log.debug(#file, "CarPlay: Playback rate changed to \(PlaybackRate.convert(rate: newRate))x")
    // Toolkit handles updating Now Playing info with new rate
  }
  
  /// Skips to a specific chapter
  /// - Parameter index: Chapter index to skip to
  func skipToChapter(at index: Int) {
    guard let manager = currentManager,
          let chapters = currentChapters,
          index >= 0 && index < chapters.count else { return }
    
    let chapter = chapters[index]
    manager.audiobook.player.play(at: chapter.position, completion: nil)
    
    Log.debug(#file, "CarPlay: Skipped to chapter '\(chapter.title ?? "Unknown")'")
  }
  
  /// Resumes playback of the current audiobook
  func play() {
    currentManager?.play()
  }
  
  /// Pauses the current audiobook
  func pause() {
    currentManager?.pause()
  }
  
  /// Forces an update to MPNowPlayingInfoCenter playback state for CarPlay
  /// - Parameter forcePlayingState: If true, forces the playback state to playing
  func forceUpdateNowPlayingInfo(forcePlayingState: Bool = false) {
    guard let manager = currentManager else {
      Log.warn(#file, "CarPlay: Cannot force update - no manager")
      return
    }
    
    let isPlaying = forcePlayingState || manager.audiobook.player.isPlaying
    Log.info(#file, "CarPlay: Setting playback state - isPlaying: \(isPlaying)")
    
    // Update the playback rate in the info dictionary (critical for real CarPlay)
    if var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo {
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
      nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
      // Ensure media type is set
      if nowPlayingInfo[MPMediaItemPropertyMediaType] == nil {
        nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    // Also set the playback state
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
  }
  
  /// Sets playback state for CarPlay
  private func setupCompleteNowPlayingInfo() {
    guard let manager = currentManager else {
      Log.warn(#file, "CarPlay: Cannot setup Now Playing - missing manager")
      return
    }
    
    Log.info(#file, "CarPlay: Setting up Now Playing state for CarPlay")
    
    let isPlaying = manager.audiobook.player.isPlaying
    
    // Update the playback rate in the info dictionary (critical for real CarPlay)
    if var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo {
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
      nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
      // Ensure media type is set
      if nowPlayingInfo[MPMediaItemPropertyMediaType] == nil {
        nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    
    Log.info(#file, "CarPlay: Playback state set - isPlaying: \(isPlaying)")
  }
  
  /// Validates and fixes Now Playing info to ensure time remaining is never negative
  /// and all required fields are set for real CarPlay hardware.
  private func validateAndFixNowPlayingInfo() {
    guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
      Log.warn(#file, "CarPlay: No Now Playing info to validate")
      return
    }
    
    let title = nowPlayingInfo[MPMediaItemPropertyTitle] as? String ?? "unknown"
    var elapsed = nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
    var duration = nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
    let rate = nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
    
    Log.info(#file, "CarPlay: Validating Now Playing - title: '\(title)', elapsed: \(elapsed)s, duration: \(duration)s, rate: \(rate)")
    
    var needsUpdate = false
    
    // Ensure media type is set for CarPlay
    if nowPlayingInfo[MPMediaItemPropertyMediaType] == nil {
      nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
      needsUpdate = true
      Log.info(#file, "CarPlay: Added missing media type (audioBook)")
    }
    
    // Fix negative duration
    if duration < 0 {
      Log.error(#file, "CarPlay: FIXING negative duration: \(duration) -> \(abs(duration))")
      duration = abs(duration)
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
      needsUpdate = true
    }
    
    // Ensure minimum duration
    if duration < 1.0 {
      Log.error(#file, "CarPlay: FIXING too-small duration: \(duration) -> 1.0")
      duration = 1.0
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
      needsUpdate = true
    }
    
    // Fix negative elapsed
    if elapsed < 0 {
      Log.error(#file, "CarPlay: FIXING negative elapsed: \(elapsed) -> 0")
      elapsed = 0
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
      needsUpdate = true
    }
    
    // Fix elapsed > duration (would cause negative time remaining)
    if elapsed > duration {
      Log.error(#file, "CarPlay: FIXING elapsed > duration: \(elapsed) > \(duration), setting to \(duration)")
      elapsed = duration
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
      needsUpdate = true
    }
    
    let timeRemaining = duration - elapsed
    Log.info(#file, "CarPlay: Now Playing validated - elapsed: \(elapsed)s, duration: \(duration)s, remaining: \(timeRemaining)s")
    
    if needsUpdate {
      Log.warn(#file, "CarPlay: Applied corrections to Now Playing info")
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
  }
  
  /// Forces CarPlay to show playing state with multiple update attempts
  func forcePlayingStateForCarPlay() {
    Log.info(#file, "CarPlay: Forcing playing state with multiple updates")
    
    // Immediate update
    forceUpdateNowPlayingInfo(forcePlayingState: true)
    
    // Delayed updates to ensure CarPlay picks it up
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.forceUpdateNowPlayingInfo(forcePlayingState: true)
    }
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.forceUpdateNowPlayingInfo(forcePlayingState: true)
    }
  }
  
  /// Stops current playback and cleans up for a new book
  func stopCurrentPlayback() {
    // CRITICAL: Cancel all per-book subscriptions FIRST to stop receiving updates from old manager
    bookCancellables.removeAll()
    
    // Pause any current playback
    currentManager?.pause()
    
    // Clear current state
    currentManager = nil
    currentChapters = nil
    currentChapter = nil
    
    // Pop the phone app's audiobook view if open
    dismissBookOnPhone()
    
    currentBook = nil
    
    Log.info(#file, "CarPlay: Stopped current playback and cleaned up")
  }
  
  /// Dismisses the audiobook view on the phone without stopping playback
  func dismissBookOnPhone() {
    Task { @MainActor in
      if let coordinator = NavigationCoordinatorHub.shared.coordinator,
         let bookId = currentBook?.identifier {
        Log.info(#file, "CarPlay: Dismissing book view on phone for book: \(bookId)")
        coordinator.removeAudioModel(forBookId: bookId)
        coordinator.popToRoot()
      }
    }
  }
  
  // MARK: - Private Methods
  
  private func subscribeToGlobalPlayback() {
    // Subscribe to audiobook manager creation events (global, not per-book)
    AudiobookEvents.managerCreated
      .receive(on: DispatchQueue.main)
      .sink { [weak self] manager in
        Log.info(#file, "CarPlay: Received manager creation event - binding to manager")
        self?.bindToManager(manager)
      }
      .store(in: &globalCancellables)
  }
  
  private func linkToActiveAudiobook() {
    guard let bookId = currentBook?.identifier else {
      Log.warn(#file, "CarPlay: No current book to link")
      return
    }
    
    // Access the coordinator on the main actor
    Task { @MainActor in
      guard let coordinator = NavigationCoordinatorHub.shared.coordinator else {
        Log.warn(#file, "CarPlay: Could not find navigation coordinator")
        return
      }
      
      if let playbackModel = coordinator.getAudioModel(forBookId: bookId) {
        self.bindToPlaybackModel(playbackModel)
      }
    }
  }
  
  private func bindToPlaybackModel(_ playbackModel: AudiobookPlaybackModel) {
    // Subscribe to the playback model's state changes
    playbackModel.$currentLocation
      .receive(on: DispatchQueue.main)
      .sink { [weak self] position in
        guard let position = position else { return }
        self?.handlePositionUpdate(position)
      }
      .store(in: &bookCancellables)
    
    // Chapter info is set when we bind to the manager via AudiobookEvents.managerCreated
    // Just notify that we're bound
    if let chapters = currentChapters {
      chapterUpdatePublisher.send(chapters)
    }
    
    Log.info(#file, "CarPlay: Bound to playback model")
  }
  
  private func bindToManager(_ manager: AudiobookManager) {
    // Cancel any existing per-book subscriptions before binding to new manager
    bookCancellables.removeAll()
    
    currentManager = manager
    currentChapters = manager.audiobook.tableOfContents.toc
    
    // Subscribe to manager state changes (per-book subscription)
    manager.statePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.handleManagerState(state)
      }
      .store(in: &bookCancellables)
    
    chapterUpdatePublisher.send(currentChapters ?? [])
    
    // Tell toolkit to refresh its Now Playing info with current position
    if let position = manager.audiobook.player.currentTrackPosition {
      manager.updateNowPlayingInfo(position)
      validateAndFixNowPlayingInfo()
    }
    
    // Set up playback state for CarPlay
    setupCompleteNowPlayingInfo()
    
    // Check if already playing and sync CarPlay state
    if manager.audiobook.player.isPlaying {
      Log.info(#file, "CarPlay: Manager is already playing - syncing state")
      playbackStatePublisher.send(.playing)
      forcePlayingStateForCarPlay()
    }
    
    Log.info(#file, "CarPlay: Bound to audiobook manager")
  }
  
  private func handleManagerState(_ state: AudiobookManagerState) {
    switch state {
    case .playbackBegan(let position):
      Log.info(#file, "CarPlay: Playback began at \(position.timestamp) - sending .playing state")
      // Cancel any pending stop handling - playback resumed
      pendingStopWorkItem?.cancel()
      pendingStopWorkItem = nil
      playbackStatePublisher.send(.playing)
      Log.info(#file, "CarPlay: Sent .playing to playbackStatePublisher")
      // Tell toolkit to refresh its Now Playing info with current position
      currentManager?.updateNowPlayingInfo(position)
      // Validate and fix any issues with the Now Playing values
      validateAndFixNowPlayingInfo()
      // Force CarPlay to show playing state
      forcePlayingStateForCarPlay()
      
    case .playbackStopped(let position):
      Log.debug(#file, "CarPlay: Playback stopped at \(position.timestamp)")
      // Delay stop handling to allow for brief stop/start cycles during track changes
      pendingStopWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.playbackStatePublisher.send(.paused)
        // Update MPNowPlayingInfoCenter to show paused state
        self?.forceUpdateNowPlayingInfo(forcePlayingState: false)
      }
      pendingStopWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
      
    case .playbackFailed(let position):
      Log.error(#file, "CarPlay: Playback failed at position: \(String(describing: position))")
      pendingStopWorkItem?.cancel()
      pendingStopWorkItem = nil
      playbackStatePublisher.send(.stopped)
      // Notify of error - template manager can subscribe to this
      errorPublisher.send(.unknown)
      
    case .playbackCompleted:
      Log.info(#file, "CarPlay: Playback completed")
      pendingStopWorkItem?.cancel()
      pendingStopWorkItem = nil
      playbackStatePublisher.send(.stopped)
      
    case .positionUpdated(let position):
      if let pos = position {
        handlePositionUpdate(pos)
      }
      
    default:
      break
    }
  }
  
  private func handlePositionUpdate(_ position: TrackPosition) {
    // Update current chapter if changed
    guard let chapters = currentChapters else { return }
    
    if let newChapter = findChapter(for: position, in: chapters) {
      if currentChapter?.position.track.key != newChapter.position.track.key {
        currentChapter = newChapter
        Log.debug(#file, "CarPlay: Chapter changed to '\(newChapter.title ?? "Unknown")'")
        chapterUpdatePublisher.send(chapters)
      }
    }
  }
  
  private func findChapter(for position: TrackPosition, in chapters: [Chapter]) -> Chapter? {
    // Find the chapter that contains this position
    // We look for the chapter whose track matches the current position's track
    chapters.first { chapter in
      chapter.position.track.key == position.track.key
    }
  }
}

// MARK: - NavigationCoordinator Extension

extension NavigationCoordinator {
  /// Retrieves the stored AudiobookPlaybackModel for a given book ID
  /// Uses the existing resolveAudioModel method through BookRoute
  func getAudioModel(forBookId bookId: String) -> AudiobookPlaybackModel? {
    resolveAudioModel(for: BookRoute(id: bookId))
  }
}

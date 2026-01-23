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

/// Bridges CarPlay controls to the existing AudiobookManager infrastructure
/// Handles playback initiation, state synchronization, and chapter navigation
final class CarPlayAudiobookBridge {
  
  // MARK: - Types
  
  typealias PlaybackCompletion = (Bool) -> Void
  
  // MARK: - Properties
  
  private(set) var currentBook: TPPBook?
  private(set) var currentManager: AudiobookManager?
  private(set) var currentChapters: [Chapter]?
  private(set) var currentChapter: Chapter?
  
  private var cancellables = Set<AnyCancellable>()
  
  /// Publisher that emits when chapter list updates
  let chapterUpdatePublisher = PassthroughSubject<[Chapter], Never>()
  
  /// Publisher that emits current playback state
  let playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
  
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
  
  // MARK: - Public Methods
  
  /// Initiates audiobook playback for CarPlay
  /// - Parameters:
  ///   - book: The audiobook to play
  ///   - completion: Called with success/failure status
  func playAudiobook(_ book: TPPBook, completion: @escaping PlaybackCompletion) {
    Log.info(#file, "CarPlay: Starting playback for '\(book.title)'")
    
    currentBook = book
    
    // Use BookService to handle the complex audiobook opening logic
    // This handles DRM, manifest fetching, position restoration, etc.
    BookService.open(book) { [weak self] in
      guard let self = self else {
        completion(false)
        return
      }
      
      // After BookService opens the book, we need to get a reference to the manager
      // The manager is stored in the navigation coordinator
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        self.linkToActiveAudiobook()
        completion(self.currentManager != nil)
      }
    }
  }
  
  /// Cycles through available playback rates
  func cyclePlaybackRate() {
    guard let manager = currentManager else { return }
    
    currentRateIndex = (currentRateIndex + 1) % availableRates.count
    let newRate = availableRates[currentRateIndex]
    
    manager.audiobook.player.playbackRate = newRate
    
    Log.debug(#file, "CarPlay: Playback rate changed to \(PlaybackRate.convert(rate: newRate))x")
    
    // Update MPNowPlayingInfoCenter with new rate
    updateNowPlayingRate(newRate)
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
  
  /// Stops current playback and cleans up for a new book
  func stopCurrentPlayback() {
    // Pause any current playback
    currentManager?.pause()
    
    // Clear current state
    currentManager = nil
    currentChapters = nil
    currentChapter = nil
    
    // Pop the phone app's audiobook view if open
    Task { @MainActor in
      if let coordinator = NavigationCoordinatorHub.shared.coordinator,
         let bookId = currentBook?.identifier {
        coordinator.removeAudioModel(forBookId: bookId)
        coordinator.popToRoot()
      }
    }
    
    currentBook = nil
    
    Log.info(#file, "CarPlay: Stopped current playback and cleaned up")
  }
  
  // MARK: - Private Methods
  
  private func subscribeToGlobalPlayback() {
    // Subscribe to audiobook manager creation events
    AudiobookEvents.managerCreated
      .receive(on: DispatchQueue.main)
      .sink { [weak self] manager in
        self?.bindToManager(manager)
      }
      .store(in: &cancellables)
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
      .store(in: &cancellables)
    
    // Chapter info is set when we bind to the manager via AudiobookEvents.managerCreated
    // Just notify that we're bound
    if let chapters = currentChapters {
      chapterUpdatePublisher.send(chapters)
    }
    
    Log.info(#file, "CarPlay: Bound to playback model")
  }
  
  private func bindToManager(_ manager: AudiobookManager) {
    currentManager = manager
    currentChapters = manager.audiobook.tableOfContents.toc
    
    // Subscribe to manager state changes
    manager.statePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.handleManagerState(state)
      }
      .store(in: &cancellables)
    
    chapterUpdatePublisher.send(currentChapters ?? [])
    
    Log.info(#file, "CarPlay: Bound to audiobook manager")
  }
  
  private func handleManagerState(_ state: AudiobookManagerState) {
    switch state {
    case .playbackBegan(let position):
      Log.debug(#file, "CarPlay: Playback began at \(position.timestamp)")
      
    case .playbackStopped(let position):
      Log.debug(#file, "CarPlay: Playback stopped at \(position.timestamp)")
      
    case .playbackCompleted:
      Log.info(#file, "CarPlay: Playback completed")
      
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
  
  private func updateNowPlayingRate(_ rate: PlaybackRate) {
    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = PlaybackRate.convert(rate: rate)
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = PlaybackRate.convert(rate: rate)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
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

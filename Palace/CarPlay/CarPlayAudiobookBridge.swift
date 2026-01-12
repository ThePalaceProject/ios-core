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
    
    Log.debug(#file, "CarPlay: Playback rate changed to \(newRate.description)")
    
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
  
  // MARK: - Private Methods
  
  private func subscribeToGlobalPlayback() {
    // Subscribe to playback started notifications to catch audiobooks
    // opened from anywhere in the app
    NotificationCenter.default.publisher(for: .TPPAudiobookManagerCreated)
      .sink { [weak self] notification in
        if let manager = notification.object as? AudiobookManager {
          self?.bindToManager(manager)
        }
      }
      .store(in: &cancellables)
  }
  
  private func linkToActiveAudiobook() {
    // Try to get the current audiobook manager from the playback model
    // stored in the navigation coordinator
    guard let coordinator = NavigationCoordinatorHub.shared.coordinator,
          let bookId = currentBook?.identifier else {
      Log.warn(#file, "CarPlay: Could not find active audiobook manager")
      return
    }
    
    // The audiobook playback model contains the manager reference
    // We access it through the coordinator's stored models
    if let playbackModel = coordinator.getAudioModel(forBookId: bookId) {
      bindToPlaybackModel(playbackModel)
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
    
    // Store chapter information
    currentChapters = playbackModel.tableOfContents?.toc
    chapterUpdatePublisher.send(currentChapters ?? [])
    
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
    if let chapters = currentChapters,
       let currentChapter = try? findChapter(for: position, in: chapters),
       currentChapter.title != currentChapters?.first(where: { 
         try? $0.position.track.key == position.track.key 
       })?.title {
      Log.debug(#file, "CarPlay: Chapter changed to '\(currentChapter.title ?? "Unknown")'")
    }
  }
  
  private func findChapter(for position: TrackPosition, in chapters: [Chapter]) throws -> Chapter? {
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

// MARK: - Notification Names

extension Notification.Name {
  /// Posted when a new AudiobookManager is created and ready for playback
  static let TPPAudiobookManagerCreated = Notification.Name("TPPAudiobookManagerCreated")
}

// MARK: - NavigationCoordinator Extension

extension NavigationCoordinator {
  /// Retrieves the stored AudiobookPlaybackModel for a given book ID
  /// Uses the existing resolveAudioModel method through BookRoute
  func getAudioModel(forBookId bookId: String) -> AudiobookPlaybackModel? {
    resolveAudioModel(for: BookRoute(id: bookId))
  }
}

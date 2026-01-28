//
//  AudiobookSessionManager.swift
//  Palace
//
//  Central manager for audiobook playback across phone and CarPlay.
//  Provides a single source of truth for playback state to avoid
//  race conditions and duplicate state management.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import MediaPlayer
import PalaceAudiobookToolkit

// MARK: - AudiobookSessionState

/// Represents the current state of audiobook playback
public enum AudiobookSessionState: Equatable {
  case idle
  case loading(bookId: String)
  case playing(bookId: String)
  case paused(bookId: String)
  case error(bookId: String, message: String)
  
  public var bookId: String? {
    switch self {
    case .idle: return nil
    case .loading(let id), .playing(let id), .paused(let id), .error(let id, _): return id
    }
  }
  
  public var isActive: Bool {
    switch self {
    case .playing, .paused, .loading: return true
    case .idle, .error: return false
    }
  }
}

// MARK: - AudiobookSessionError

public enum AudiobookSessionError: Error, Equatable {
  case notAuthenticated
  case notDownloaded
  case networkUnavailable
  case manifestLoadFailed
  case playerCreationFailed
  case alreadyLoading
  case unknown(String)
  
  var localizedDescription: String {
    switch self {
    case .notAuthenticated:
      return "Please sign in to your library account to play this audiobook."
    case .notDownloaded:
      return "This audiobook needs to be downloaded first."
    case .networkUnavailable:
      return "No network connection. Please try again when online."
    case .manifestLoadFailed:
      return "Failed to load audiobook data. Please try again."
    case .playerCreationFailed:
      return "Failed to create audio player. Please try again."
    case .alreadyLoading:
      return "Audiobook is already loading."
    case .unknown(let message):
      return message
    }
  }
}

// MARK: - AudiobookSessionManager

/// Singleton manager that owns audiobook playback state.
/// Thread-safe via MainActor isolation.
@MainActor
public final class AudiobookSessionManager: ObservableObject {
  
  // MARK: - Singleton
  
  public static let shared = AudiobookSessionManager()
  
  // MARK: - Published State
  
  @Published public private(set) var state: AudiobookSessionState = .idle
  @Published public private(set) var currentBook: TPPBook?
  @Published public private(set) var currentChapters: [Chapter] = []
  @Published public private(set) var currentChapter: Chapter?
  @Published public private(set) var currentPosition: TrackPosition?
  @Published public private(set) var isPlaying: Bool = false
  @Published public private(set) var coverImage: UIImage?
  
  // MARK: - Internal State
  
  private(set) var audiobook: Audiobook?
  private(set) var manager: AudiobookManager?
  private(set) var playbackModel: AudiobookPlaybackModel?
  private(set) var nowPlayingCoordinator: NowPlayingCoordinator?
  
  private var cancellables = Set<AnyCancellable>()
  private var managerCancellables = Set<AnyCancellable>()
  
  // MARK: - Publishers for External Observers
  
  /// Emits when playback state changes (for CarPlay UI updates)
  public let playbackStatePublisher = PassthroughSubject<AudiobookSessionState, Never>()
  
  /// Emits when chapter list or current chapter changes
  public let chapterUpdatePublisher = PassthroughSubject<(chapters: [Chapter], current: Chapter?), Never>()
  
  /// Emits errors for UI display
  public let errorPublisher = PassthroughSubject<AudiobookSessionError, Never>()
  
  // MARK: - Initialization
  
  private init() {
    Log.info(#file, "AudiobookSessionManager initialized")
    nowPlayingCoordinator = NowPlayingCoordinator()
    // Note: Remote commands are handled by the toolkit's MediaControlPublisher
    // NowPlayingCoordinator only manages Now Playing info updates
    subscribeToGlobalEvents()
  }
  
  // MARK: - Public API
  
  /// Opens and starts playing an audiobook.
  /// This is the single entry point for playback from both phone and CarPlay.
  ///
  /// - Parameters:
  ///   - book: The book to play
  ///   - startPlaying: Whether to auto-start playback (default: true)
  /// - Returns: Result indicating success or failure
  @discardableResult
  public func openAudiobook(_ book: TPPBook, startPlaying: Bool = true) async -> Result<Void, AudiobookSessionError> {
    Log.info(#file, "Opening audiobook: '\(book.title)' (id: \(book.identifier))")
    
    // Check if already loading this book
    if case .loading(let loadingId) = state, loadingId == book.identifier {
      Log.warn(#file, "Audiobook already loading: \(book.identifier)")
      return .failure(.alreadyLoading)
    }
    
    // Check if this is the same book that's currently playing
    let isSameBook = currentBook?.identifier == book.identifier
    
    // Stop any current playback (don't dismiss phone UI if reopening same book)
    if state.isActive {
      await stopPlayback(dismissPhoneUI: !isSameBook)
    }
    
    // Validate requirements
    if let error = validateRequirements(for: book) {
      Log.error(#file, "Validation failed: \(error)")
      state = .error(bookId: book.identifier, message: error.localizedDescription)
      errorPublisher.send(error)
      return .failure(error)
    }
    
    // Update state
    state = .loading(bookId: book.identifier)
    currentBook = book
    playbackStatePublisher.send(state)
    
    // Use continuation to bridge completion-based BookService to async
    return await withCheckedContinuation { continuation in
      // Open the book using existing BookService infrastructure
      // This handles DRM, manifest fetching, position restoration, etc.
      openBookWithService(book, startPlaying: startPlaying) { [weak self] result in
        Task { @MainActor in
          guard let self = self else {
            continuation.resume(returning: .failure(.unknown("Session manager deallocated")))
            return
          }
          
          switch result {
          case .success:
            Log.info(#file, "Audiobook opened successfully: '\(book.title)'")
            continuation.resume(returning: .success(()))
            
          case .failure(let error):
            Log.error(#file, "Failed to open audiobook: \(error)")
            self.state = .error(bookId: book.identifier, message: error.localizedDescription)
            self.errorPublisher.send(error)
            continuation.resume(returning: .failure(error))
          }
        }
      }
    }
  }
  
  /// Plays the current audiobook
  public func play() {
    guard let manager = manager else {
      Log.warn(#file, "Cannot play - no active manager")
      return
    }
    
    manager.play()
    nowPlayingCoordinator?.setPlaybackState(playing: true)
  }
  
  /// Pauses the current audiobook
  public func pause() {
    guard let manager = manager else {
      Log.warn(#file, "Cannot pause - no active manager")
      return
    }
    
    manager.pause()
    nowPlayingCoordinator?.setPlaybackState(playing: false)
  }
  
  /// Toggles play/pause
  public func togglePlayPause() {
    if isPlaying {
      pause()
    } else {
      play()
    }
  }
  
  /// Skips to a specific chapter
  public func skipToChapter(at index: Int) {
    guard let manager = manager,
          index >= 0 && index < currentChapters.count else {
      Log.warn(#file, "Invalid chapter index: \(index)")
      return
    }
    
    let chapter = currentChapters[index]
    manager.audiobook.player.play(at: chapter.position, completion: nil)
    
    Log.debug(#file, "Skipping to chapter: '\(chapter.title ?? "Unknown")'")
  }
  
  /// Cycles through playback rates
  public func cyclePlaybackRate() -> PlaybackRate {
    guard let player = manager?.audiobook.player else {
      return .normalTime
    }
    
    let rates: [PlaybackRate] = [.threeQuartersTime, .normalTime, .oneAndAQuarterTime, .oneAndAHalfTime, .doubleTime]
    let currentIndex = rates.firstIndex(of: player.playbackRate) ?? 1
    let nextIndex = (currentIndex + 1) % rates.count
    let newRate = rates[nextIndex]
    
    player.playbackRate = newRate
    nowPlayingCoordinator?.updatePlaybackRate(newRate)
    
    Log.debug(#file, "Playback rate changed to: \(PlaybackRate.convert(rate: newRate))x")
    return newRate
  }
  
  /// Stops playback and clears current session
  /// - Parameter dismissPhoneUI: Whether to dismiss the player UI on the phone (default: true)
  public func stopPlayback(dismissPhoneUI: Bool = true) async {
    Log.info(#file, "Stopping playback (dismissPhoneUI: \(dismissPhoneUI))")
    
    // Capture book ID before clearing state
    let bookId = currentBook?.identifier
    
    // Save position before stopping
    if let position = currentPosition {
      manager?.saveLocation(position)
    }
    
    // Clear subscriptions first
    managerCancellables.removeAll()
    
    // Pause and unload
    manager?.pause()
    manager?.unload()
    
    // Dismiss phone UI if requested (e.g., when switching books from CarPlay)
    if dismissPhoneUI, let bookId = bookId {
      dismissPlayerOnPhone(bookId: bookId)
    }
    
    // Clear state
    manager = nil
    audiobook = nil
    playbackModel = nil
    currentBook = nil
    currentChapters = []
    currentChapter = nil
    currentPosition = nil
    isPlaying = false
    coverImage = nil
    
    // Clear Now Playing
    nowPlayingCoordinator?.clearNowPlaying()
    
    state = .idle
    playbackStatePublisher.send(state)
    
    Log.info(#file, "Playback stopped and session cleared")
  }
  
  /// Dismisses the audiobook player view on the phone
  private func dismissPlayerOnPhone(bookId: String) {
    if let coordinator = NavigationCoordinatorHub.shared.coordinator {
      Log.info(#file, "Dismissing player UI on phone for book: \(bookId)")
      coordinator.removeAudioModel(forBookId: bookId)
      coordinator.popToRoot()
    }
  }
  
  /// Updates cover image (called when image loads asynchronously)
  public func updateCoverImage(_ image: UIImage?) {
    coverImage = image
    nowPlayingCoordinator?.updateArtwork(image)
  }
  
  // MARK: - Manager Binding (Called by AudiobookEvents)
  
  /// Binds to an AudiobookManager created by BookService.
  /// This is called via AudiobookEvents.managerCreated subscription.
  func bindToManager(_ newManager: AudiobookManager) {
    Log.info(#file, "Binding to AudiobookManager")
    let hadExistingManager = manager != nil
    let existingBookId = currentBook?.identifier ?? "none"
    
    if hadExistingManager {
    }
    
    // Clear previous subscriptions
    managerCancellables.removeAll()
    
    manager = newManager
    audiobook = newManager.audiobook
    currentChapters = newManager.audiobook.tableOfContents.toc
    
    // Subscribe to manager state changes
    newManager.statePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] managerState in
        self?.handleManagerState(managerState)
      }
      .store(in: &managerCancellables)
    
    // Subscribe to position updates via player's fast publisher
    newManager.audiobook.player.positionPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] position in
        self?.handlePositionUpdate(position)
      }
      .store(in: &managerCancellables)
    
    // Initialize Now Playing with current state
    if let position = newManager.audiobook.player.currentTrackPosition {
      updateNowPlayingInfo(position: position)
    }
    
    // Set initial chapter using manager's public property
    currentChapter = newManager.currentChapter
    
    // Notify observers
    chapterUpdatePublisher.send((chapters: currentChapters, current: currentChapter))
    
    // Update state based on player state
    if newManager.audiobook.player.isPlaying {
      isPlaying = true
      if let bookId = currentBook?.identifier {
        state = .playing(bookId: bookId)
      }
    } else if let bookId = currentBook?.identifier {
      state = .paused(bookId: bookId)
    }
    
    playbackStatePublisher.send(state)
    
    Log.info(#file, "Bound to AudiobookManager - chapters: \(currentChapters.count), isPlaying: \(isPlaying)")
  }
  
  // MARK: - Private Methods
  
  private func subscribeToGlobalEvents() {
    // Subscribe to manager creation events
    AudiobookEvents.managerCreated
      .receive(on: DispatchQueue.main)
      .sink { [weak self] manager in
        Log.info(#file, "Received AudiobookEvents.managerCreated")
        self?.bindToManager(manager)
      }
      .store(in: &cancellables)
  }
  
  private func validateRequirements(for book: TPPBook) -> AudiobookSessionError? {
    // Check authentication
    let isAuthenticated = isUserAuthenticated()
    if !isAuthenticated {
      return .notAuthenticated
    }
    
    // Check book state
    let bookState = TPPBookRegistry.shared.state(for: book.identifier)
    if bookState == .unregistered || bookState == .downloadNeeded {
      return .notDownloaded
    }
    
    // Check network for streaming content
    let isFullyDownloaded = bookState == .downloadSuccessful || bookState == .used
    let hasNetwork = Reachability.shared.isConnectedToNetwork()
    if !isFullyDownloaded && !hasNetwork {
      return .networkUnavailable
    }
    
    return nil
  }
  
  private func isUserAuthenticated() -> Bool {
    guard let account = AccountsManager.shared.currentAccount else {
      return false
    }
    
    guard let details = account.details,
          let defaultAuth = details.defaultAuth else {
      return true // No auth required
    }
    
    if !defaultAuth.needsAuth {
      return true
    }
    
    return TPPUserAccount.sharedAccount().hasCredentials()
  }
  
  private func openBookWithService(
    _ book: TPPBook,
    startPlaying: Bool,
    completion: @escaping (Result<Void, AudiobookSessionError>) -> Void
  ) {
    
    // Set up timeout
    var didComplete = false
    let timeoutWorkItem = DispatchWorkItem { [weak self] in
      guard !didComplete else { return }
      didComplete = true
      
      Task { @MainActor in
        self?.state = .error(bookId: book.identifier, message: "Timeout loading audiobook")
      }
      completion(.failure(.unknown("Timeout loading audiobook")))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: timeoutWorkItem)
    
    // Use BookService to handle the complex opening logic
    BookService.open(book) { [weak self] in
      guard !didComplete else {
        return
      }
      didComplete = true
      timeoutWorkItem.cancel()
      
      Task { @MainActor in
        guard let self = self else {
          completion(.failure(.unknown("Session manager deallocated")))
          return
        }
        
        
        // Manager should be bound by now via AudiobookEvents
        if self.manager != nil {
          completion(.success(()))
        } else {
          // Give a brief moment for the event to propagate
          try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
          
          if self.manager != nil {
            completion(.success(()))
          } else {
            self.state = .error(bookId: book.identifier, message: "Failed to initialize player")
            completion(.failure(.playerCreationFailed))
          }
        }
      }
    }
  }
  
  private func handleManagerState(_ managerState: AudiobookManagerState) {
    guard let bookId = currentBook?.identifier else { return }
    
    switch managerState {
    case .playbackBegan(let position):
      Log.debug(#file, "Playback began at: \(position.timestamp)")
      isPlaying = true
      state = .playing(bookId: bookId)
      currentPosition = position
      updateNowPlayingInfo(position: position)
      playbackStatePublisher.send(state)
      
    case .playbackStopped(let position):
      Log.debug(#file, "Playback stopped at: \(position.timestamp)")
      isPlaying = false
      state = .paused(bookId: bookId)
      currentPosition = position
      nowPlayingCoordinator?.setPlaybackState(playing: false)
      playbackStatePublisher.send(state)
      
    case .playbackFailed(let position):
      Log.error(#file, "Playback failed at position: \(String(describing: position))")
      isPlaying = false
      state = .error(bookId: bookId, message: "Playback failed")
      errorPublisher.send(.unknown("Playback failed"))
      playbackStatePublisher.send(state)
      
    case .playbackCompleted(let position):
      Log.info(#file, "Playback completed at: \(position.timestamp)")
      isPlaying = false
      state = .paused(bookId: bookId)
      currentPosition = position
      playbackStatePublisher.send(state)
      
    case .positionUpdated(let position):
      if let position = position {
        handlePositionUpdate(position)
      }
      
    default:
      break
    }
  }
  
  private func handlePositionUpdate(_ position: TrackPosition) {
    currentPosition = position
    
    // Check for chapter change using manager's currentChapter
    if let mgr = manager, let newChapter = mgr.currentChapter {
      if currentChapter?.position.track.key != newChapter.position.track.key ||
         currentChapter?.title != newChapter.title {
        currentChapter = newChapter
        chapterUpdatePublisher.send((chapters: currentChapters, current: currentChapter))
        Log.debug(#file, "Chapter changed to: '\(newChapter.title ?? "Unknown")'")
      }
    }
    
    // Update Now Playing (debounced in coordinator)
    updateNowPlayingInfo(position: position)
  }
  
  private func updateNowPlayingInfo(position: TrackPosition) {
    guard let book = currentBook,
          let audiobook = audiobook,
          let mgr = manager else {
      return
    }
    
    // Use manager's public properties for chapter info
    let chapter = mgr.currentChapter
    let chapterOffset = mgr.currentOffset
    let chapterDuration = mgr.currentDuration
    
    let title = chapter?.title ?? position.track.title ?? "Unknown"
    
    nowPlayingCoordinator?.updateNowPlaying(
      title: title,
      artist: book.title,
      album: book.authors,
      elapsed: chapterOffset,
      duration: chapterDuration,
      isPlaying: isPlaying,
      playbackRate: audiobook.player.playbackRate
    )
  }
}

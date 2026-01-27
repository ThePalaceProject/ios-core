//
//  CarPlayTemplateManager.swift
//  Palace
//
//  Created for CarPlay audiobook support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import CarPlay
import Combine
import PalaceAudiobookToolkit

/// Manages CarPlay template hierarchy and navigation for audiobook playback
final class CarPlayTemplateManager: NSObject {
  
  // MARK: - Constants
  
  // MARK: - Layout Constants
  // Apple CarPlay Guidelines (CarPlay-Audio-App-Programming-Guide.pdf):
  // - Max hierarchy depth: 5 levels (we use ~3-4)
  // - Chapter lists are explicitly allowed for audiobook navigation
  // Following Apple Books' approach: show all chapters, let user scroll
  private enum Layout {
    static let maxListItems = 20
    static let artworkSize = CGSize(width: 90, height: 90)
  }
  
  // MARK: - Properties
  
  private weak var interfaceController: CPInterfaceController?
  private let imageProvider: CarPlayImageProvider
  private let playerBridge: CarPlayAudiobookBridge
  private var cancellables = Set<AnyCancellable>()
  
  private var libraryTemplate: CPListTemplate?
  private var nowPlayingTemplate: CPNowPlayingTemplate?
  private var isPushingNowPlaying = false
  private var isShowingNowPlaying = false
  
  // MARK: - Initialization
  
  init(interfaceController: CPInterfaceController) {
    self.interfaceController = interfaceController
    self.imageProvider = CarPlayImageProvider()
    self.playerBridge = CarPlayAudiobookBridge()
    
    super.init()
    
    interfaceController.delegate = self
    setupPlayerBridgeBindings()
  }
  
  // MARK: - Public Methods
  
  func setupRootTemplate() {
    libraryTemplate = createLibraryTemplate()
    nowPlayingTemplate = CPNowPlayingTemplate.shared
    
    configureNowPlayingTemplate()
    
    // Note: CPNowPlayingTemplate cannot be added to tab bar - it's shown automatically
    // by the system when audio is playing. We only set up the library as root.
    guard let libraryTemplate = libraryTemplate else {
      Log.error(#file, "CarPlay: Failed to create library template")
      return
    }
    interfaceController?.setRootTemplate(libraryTemplate, animated: true, completion: nil)
    
    Log.info(#file, "CarPlay root template configured")
  }
  
  func refreshLibrary() {
    guard let libraryTemplate = libraryTemplate else { return }
    
    let items = createLibraryItems()
    let section = CPListSection(items: items)
    libraryTemplate.updateSections([section])
    
    Log.debug(#file, "CarPlay library refreshed with \(items.count) audiobooks")
  }
  
  // MARK: - Library Template
  
  private func createLibraryTemplate() -> CPListTemplate {
    let items = createLibraryItems()
    let section = CPListSection(items: items)
    
    // Use the library's actual name with beta indicator
    let libraryName = AccountsManager.shared.currentAccount?.name ?? Strings.CarPlay.library
    let titleWithBeta = "\(libraryName) (beta)"
    
    let template = CPListTemplate(title: titleWithBeta, sections: [section])
    template.tabTitle = Strings.CarPlay.library
    template.tabImage = UIImage(systemName: "books.vertical")
    template.emptyViewTitleVariants = [Strings.CarPlay.noAudiobooks]
    template.emptyViewSubtitleVariants = [Strings.CarPlay.downloadAudiobooks]
    
    return template
  }
  
  private func createLibraryItems() -> [CPListItem] {
    let audiobooks = fetchDownloadedAudiobooks()
    
    Log.info(#file, "🚗 CarPlay: Found \(audiobooks.count) downloaded audiobooks")
    
    if audiobooks.isEmpty {
      // Show a placeholder item when no audiobooks are downloaded
      let placeholderItem = CPListItem(
        text: "No Audiobooks Downloaded",
        detailText: "Download audiobooks in the Palace app first"
      )
      placeholderItem.handler = { _, completion in
        Log.info(#file, "🚗 CarPlay: Placeholder item tapped")
        completion()
      }
      return [placeholderItem]
    }
    
    return audiobooks.prefix(Layout.maxListItems).map { book in
      createListItem(for: book)
    }
  }
  
  private func createListItem(for book: TPPBook) -> CPListItem {
    let item = CPListItem(
      text: book.title,
      detailText: book.authors ?? "Unknown Author"
    )
    
    item.accessoryType = .disclosureIndicator
    item.userInfo = ["bookIdentifier": book.identifier]
    
    // Load artwork asynchronously
    imageProvider.artwork(for: book) { [weak item] image in
      guard let image = image else { return }
      DispatchQueue.main.async {
        item?.setImage(image)
      }
    }
    
    item.handler = { [weak self] _, completion in
      self?.handleBookSelection(book, completion: completion)
    }
    
    return item
  }
  
  private func handleBookSelection(_ book: TPPBook, completion: @escaping () -> Void) {
    Log.info(#file, "CarPlay: User selected audiobook '\(book.title)'")
    completion()
    
    // Check authentication status first
    guard isUserAuthenticated() else {
      Log.warn(#file, "CarPlay: User not authenticated")
      showErrorAlert(
        title: Strings.CarPlay.Error.authRequired,
        message: Strings.CarPlay.Error.authMessage
      )
      return
    }
    
    // Check if book is downloaded for offline play
    guard isDownloaded(book) else {
      showErrorAlert(
        title: Strings.CarPlay.Error.notDownloaded,
        message: Strings.CarPlay.Error.downloadRequired
      )
      return
    }
    
    // Check network connectivity for streaming content that requires it
    let isOffline = !Reachability.shared.isConnectedToNetwork()
    let needsNetwork = !isFullyDownloaded(book)
    
    if isOffline && needsNetwork {
      Log.warn(#file, "CarPlay: Offline and book not fully downloaded")
      showErrorAlert(
        title: Strings.CarPlay.Error.offline,
        message: Strings.CarPlay.Error.offlineMessage
      )
      return
    }
    
    // Stop any existing playback and clean up before starting new book
    playerBridge.stopCurrentPlayback()
    
    // Pop to root to clear any stacked templates (only if not already at root)
    if let controller = interfaceController, controller.templates.count > 1 {
      controller.popToRootTemplate(animated: false, completion: nil)
    }
    
    // Start playback through the bridge with enhanced error handling
    // Note: switchToNowPlaying will be called automatically via playbackStatePublisher
    // when playback actually begins (after BookService finishes position sync)
    playerBridge.playAudiobook(book) { [weak self] result in
      switch result {
      case .success:
        Log.info(#file, "CarPlay: Playback started successfully for '\(book.title)'")
      case .failure(let error):
        Log.error(#file, "CarPlay: Failed to start playback for '\(book.title)': \(error)")
        self?.handlePlaybackError(error)
      }
    }
  }
  
  /// Checks if the user is authenticated with the current library
  /// Note: If tokens need refresh, the app's auth layer handles this automatically.
  /// CarPlay cannot show sign-in UI - users must sign in via the phone app.
  private func isUserAuthenticated() -> Bool {
    CarPlayAuthHelper.isAuthenticated()
  }
  
  /// Handles specific playback errors with appropriate UI
  private func handlePlaybackError(_ error: CarPlayPlaybackError) {
    switch error {
    case .authenticationRequired:
      showErrorAlert(
        title: Strings.CarPlay.Error.authRequired,
        message: Strings.CarPlay.Error.authMessage
      )
    case .networkError:
      showErrorAlert(
        title: Strings.CarPlay.Error.offline,
        message: Strings.CarPlay.Error.offlineMessage
      )
    case .drmError:
      showErrorAlert(
        title: Strings.CarPlay.Error.playbackFailed,
        message: Strings.CarPlay.Error.drmMessage
      )
    case .notDownloaded:
      showErrorAlert(
        title: Strings.CarPlay.Error.notDownloaded,
        message: Strings.CarPlay.Error.downloadRequired
      )
    case .unknown:
      showErrorAlert(
        title: Strings.CarPlay.Error.playbackFailed,
        message: Strings.CarPlay.Error.tryAgain
      )
    }
  }
  
  private func isFullyDownloaded(_ book: TPPBook) -> Bool {
    // Check if all audio files are downloaded
    // For now, assume if state is downloadSuccessful/used, it's fully downloaded
    let state = TPPBookRegistry.shared.state(for: book.identifier)
    return state == .downloadSuccessful || state == .used
  }
  
  // MARK: - Error Handling
  
  private func showErrorAlert(title: String, message: String) {
    guard let interfaceController = interfaceController else { return }
    
    let alert = CPAlertTemplate(
      titleVariants: [title],
      actions: [
        CPAlertAction(title: Strings.Generic.ok, style: .default) { _ in
          interfaceController.dismissTemplate(animated: true, completion: nil)
        }
      ]
    )
    
    interfaceController.presentTemplate(alert, animated: true, completion: nil)
  }
  
  // MARK: - Now Playing Template
  
  private func configureNowPlayingTemplate() {
    guard let nowPlayingTemplate = nowPlayingTemplate else { return }
    
    nowPlayingTemplate.tabTitle = Strings.CarPlay.nowPlaying
    nowPlayingTemplate.tabImage = UIImage(systemName: "play.circle")
    
    // Set ourselves as the observer to handle up next button taps
    nowPlayingTemplate.add(self)
    
    // Configure playback buttons - use custom TOC button with list.bullet icon
    let rateButton = CPNowPlayingPlaybackRateButton { [weak self] button in
      self?.playerBridge.cyclePlaybackRate()
    }
    
    // Create custom table of contents button with list.bullet icon (same as app)
    guard let tocImage = UIImage(systemName: "list.bullet") else {
      Log.warn(#file, "CarPlay: Could not load list.bullet image")
      nowPlayingTemplate.updateNowPlayingButtons([rateButton])
      return
    }
    let tocButton = CPNowPlayingImageButton(image: tocImage) { [weak self] _ in
      Log.info(#file, "CarPlay: TOC button tapped")
      self?.showChapterList()
    }
    
    nowPlayingTemplate.updateNowPlayingButtons([tocButton, rateButton])
    
    // Disable the system Up Next button since we're using a custom TOC button
    nowPlayingTemplate.isUpNextButtonEnabled = false
  }
  
  private func updateChapterList() {
    // No longer needed since we use a custom button, but keep for potential future use
    guard let chapters = playerBridge.currentChapters, !chapters.isEmpty else {
      return
    }
    // Chapters are available - the TOC button will show them
  }
  
  // MARK: - Chapter List
  
  private func showChapterList() {
    guard let chapters = playerBridge.currentChapters, !chapters.isEmpty else {
      Log.warn(#file, "CarPlay: No chapters available to display")
      return
    }
    
    Log.info(#file, "CarPlay: Showing chapter list with \(chapters.count) chapters")
    
    // Show all chapters like Apple Books does - users can scroll through the list
    let items = chapters.enumerated().map { index, chapter in
      createChapterItem(chapter: chapter, index: index)
    }
    
    let section = CPListSection(items: items)
    let chapterTemplate = CPListTemplate(title: Strings.CarPlay.chapters, sections: [section])
    
    interfaceController?.pushTemplate(chapterTemplate, animated: true, completion: nil)
  }
  
  private func createChapterItem(chapter: Chapter, index: Int) -> CPListItem {
    let title = chapter.title
    let duration = formatDuration(chapter.duration)
    
    let item = CPListItem(text: title, detailText: duration)
    item.userInfo = ["chapterIndex": index]
    
    // Highlight current chapter
    if let currentChapter = playerBridge.currentChapter,
       currentChapter.position.track.key == chapter.position.track.key {
      item.isPlaying = true
    }
    
    item.handler = { [weak self] _, completion in
      self?.playerBridge.skipToChapter(at: index)
      self?.interfaceController?.popTemplate(animated: true, completion: nil)
      completion()
    }
    
    return item
  }
  
  private func formatDuration(_ duration: Double?) -> String {
    guard let duration = duration, duration > 0 else {
      return ""
    }
    
    // Log warning if we receive negative duration (should not happen)
    if duration < 0 {
      Log.warn(#file, "CarPlay: Received negative duration value: \(duration)")
    }
    
    let totalSeconds = Int(abs(duration))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    
    if minutes >= 60 {
      let hours = minutes / 60
      let remainingMinutes = minutes % 60
      return String(format: "%d:%02d:%02d", hours, remainingMinutes, seconds)
    } else {
      return String(format: "%d:%02d", minutes, seconds)
    }
  }
  
  private func switchToNowPlaying() {
    // CPNowPlayingTemplate is automatically shown by the system when playback starts.
    // We can push it onto the navigation stack if needed, but typically the system
    // handles showing it via the Now Playing button in CarPlay.
    guard let nowPlayingTemplate = nowPlayingTemplate else {
      Log.warn(#file, "CarPlay: No Now Playing template available")
      return
    }
    
    Log.info(#file, "CarPlay: Pushing Now Playing template")
    interfaceController?.pushTemplate(nowPlayingTemplate, animated: true) { [weak self] success, error in
      if let error = error {
        Log.error(#file, "CarPlay: Failed to push Now Playing: \(error)")
      } else {
        Log.info(#file, "CarPlay: Now Playing template pushed successfully")
        self?.isShowingNowPlaying = true
        // Force CarPlay to show playing state
        self?.playerBridge.forcePlayingStateForCarPlay()
      }
    }
  }
  
  private func switchToNowPlayingIfNeeded() {
    Log.info(#file, "CarPlay: switchToNowPlayingIfNeeded called")
    
    // Only push if we're not already showing Now Playing
    guard let controller = interfaceController else {
      Log.warn(#file, "CarPlay: No interface controller")
      return
    }
    
    // Check if Now Playing is already the top template
    if let topTemplate = controller.topTemplate,
       topTemplate is CPNowPlayingTemplate {
      Log.debug(#file, "CarPlay: Already showing Now Playing, skipping push")
      return
    }
    
    // Check if we're already in the process of pushing
    guard !isPushingNowPlaying else {
      Log.debug(#file, "CarPlay: Already pushing Now Playing, skipping")
      return
    }
    
    isPushingNowPlaying = true
    Log.info(#file, "CarPlay: Will push Now Playing in 0.5s")
    
    // Delay to ensure MPNowPlayingInfoCenter has been fully updated by the toolkit
    // Longer delay for reliability, especially on first play
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self = self else { return }
      
      // Double-check we're not already showing Now Playing
      if let topTemplate = self.interfaceController?.topTemplate,
         topTemplate is CPNowPlayingTemplate {
        Log.debug(#file, "CarPlay: Already showing Now Playing after delay, skipping")
        self.isPushingNowPlaying = false
        return
      }
      
      self.switchToNowPlaying()
      self.isPushingNowPlaying = false
    }
  }
  
  // MARK: - Data Access
  
  private func fetchDownloadedAudiobooks() -> [TPPBook] {
    TPPBookRegistry.shared.myBooks
      .filter { $0.isAudiobook }
      .filter { isDownloaded($0) }
      .sorted { ($0.title) < ($1.title) }
  }
  
  private func isDownloaded(_ book: TPPBook) -> Bool {
    let state = TPPBookRegistry.shared.state(for: book.identifier)
    return state == .downloadSuccessful || state == .used
  }
  
  // MARK: - Player Bridge Bindings
  
  private func setupPlayerBridgeBindings() {
    playerBridge.chapterUpdatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.updateChapterList()
      }
      .store(in: &cancellables)
    
    // Listen for playback to begin and switch to Now Playing
    // This ensures the Now Playing view shows after the toolkit updates MPNowPlayingInfoCenter
    playerBridge.playbackStatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        Log.info(#file, "CarPlay: Received playback state: \(state)")
        if case .playing = state {
          Log.info(#file, "CarPlay: Playback started - will switch to Now Playing")
          self?.switchToNowPlayingIfNeeded()
        }
      }
      .store(in: &cancellables)
    
    // Listen for playback errors
    playerBridge.errorPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] error in
        Log.error(#file, "CarPlay: Received playback error: \(error)")
        self?.handlePlaybackError(error)
        // Pop back to library if we're showing Now Playing
        if let controller = self?.interfaceController,
           controller.topTemplate is CPNowPlayingTemplate {
          controller.popTemplate(animated: true, completion: nil)
        }
      }
      .store(in: &cancellables)
  }
}

// MARK: - CPInterfaceControllerDelegate

extension CarPlayTemplateManager: CPInterfaceControllerDelegate {
  func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
    // Track template appearance if needed
  }
  
  func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
    // Track template appearance if needed
  }
  
  func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {
    Log.debug(#file, "CarPlay: Template will disappear: \(type(of: aTemplate))")
  }
  
  func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
    Log.debug(#file, "CarPlay: Template did disappear: \(type(of: aTemplate))")
    
    // Track when Now Playing disappears
    if aTemplate is CPNowPlayingTemplate && isShowingNowPlaying {
      // Check if we're back at the library (root) or if another template is on top
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        
        // If templates count is 1 (only root/library), user backed out completely
        if let templateCount = self.interfaceController?.templates.count, templateCount <= 1 {
          Log.info(#file, "CarPlay: User returned to library - stopping playback")
          self.isShowingNowPlaying = false
          self.playerBridge.stopCurrentPlayback()
        } else {
          Log.debug(#file, "CarPlay: Now Playing covered by another template")
        }
      }
    }
  }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlayTemplateManager: CPNowPlayingTemplateObserver {
  func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    Log.info(#file, "CarPlay: Up next (chapters) button tapped")
    showChapterList()
  }
  
  func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    // Not used - we don't enable album artist button
  }
}

// MARK: - Strings Extension

extension Strings {
  enum CarPlay {
    static let library = NSLocalizedString(
      "CarPlay.library",
      value: "Library",
      comment: "CarPlay tab title for audiobook library"
    )
    static let nowPlaying = NSLocalizedString(
      "CarPlay.nowPlaying",
      value: "Now Playing",
      comment: "CarPlay tab title for now playing screen"
    )
    static let chapters = NSLocalizedString(
      "CarPlay.chapters",
      value: "Chapters",
      comment: "CarPlay chapter list button title"
    )
    static let noAudiobooks = NSLocalizedString(
      "CarPlay.noAudiobooks",
      value: "No Audiobooks",
      comment: "CarPlay empty library title"
    )
    static let downloadAudiobooks = NSLocalizedString(
      "CarPlay.downloadAudiobooks",
      value: "Download audiobooks from your library to listen in CarPlay",
      comment: "CarPlay empty library subtitle"
    )
    
    static func chapterNumber(_ number: Int) -> String {
      String(format: NSLocalizedString(
        "CarPlay.chapterNumber",
        value: "Chapter %d",
        comment: "CarPlay chapter number placeholder"
      ), number)
    }
    
    enum Error {
      static let notDownloaded = NSLocalizedString(
        "CarPlay.Error.notDownloaded",
        value: "Not Downloaded",
        comment: "CarPlay error when audiobook is not downloaded"
      )
      static let downloadRequired = NSLocalizedString(
        "CarPlay.Error.downloadRequired",
        value: "Please download this audiobook in the app first",
        comment: "CarPlay error message when audiobook needs to be downloaded"
      )
      static let offline = NSLocalizedString(
        "CarPlay.Error.offline",
        value: "No Connection",
        comment: "CarPlay error when device is offline"
      )
      static let offlineMessage = NSLocalizedString(
        "CarPlay.Error.offlineMessage",
        value: "Connect to the internet or download the audiobook for offline listening",
        comment: "CarPlay error message when device is offline"
      )
      static let playbackFailed = NSLocalizedString(
        "CarPlay.Error.playbackFailed",
        value: "Playback Error",
        comment: "CarPlay error when playback fails"
      )
      static let tryAgain = NSLocalizedString(
        "CarPlay.Error.tryAgain",
        value: "Unable to play audiobook. Please try again",
        comment: "CarPlay error message when playback fails"
      )
      static let authRequired = NSLocalizedString(
        "CarPlay.Error.authRequired",
        value: "Sign In Required",
        comment: "CarPlay error when authentication is required"
      )
      static let authMessage = NSLocalizedString(
        "CarPlay.Error.authMessage",
        value: "Please sign in to your library in the app",
        comment: "CarPlay error message when authentication is required"
      )
      static let drmMessage = NSLocalizedString(
        "CarPlay.Error.drmMessage",
        value: "There was a problem with the audiobook license. Please try again in the app",
        comment: "CarPlay error message when DRM/license fails"
      )
    }
  }
}

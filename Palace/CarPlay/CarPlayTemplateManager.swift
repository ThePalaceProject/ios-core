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
  
  private enum Layout {
    static let maxListItems = 20
    static let maxChapterItems = 100
    static let artworkSize = CGSize(width: 90, height: 90)
  }
  
  // MARK: - Properties
  
  private weak var interfaceController: CPInterfaceController?
  private let imageProvider: CarPlayImageProvider
  private let playerBridge: CarPlayAudiobookBridge
  private var cancellables = Set<AnyCancellable>()
  
  private var libraryTemplate: CPListTemplate?
  private var nowPlayingTemplate: CPNowPlayingTemplate?
  
  // MARK: - Initialization
  
  init(interfaceController: CPInterfaceController) {
    self.interfaceController = interfaceController
    self.imageProvider = CarPlayImageProvider()
    self.playerBridge = CarPlayAudiobookBridge()
    
    super.init()
    
    setupPlayerBridgeBindings()
  }
  
  // MARK: - Public Methods
  
  func setupRootTemplate() {
    libraryTemplate = createLibraryTemplate()
    nowPlayingTemplate = CPNowPlayingTemplate.shared
    
    configureNowPlayingTemplate()
    
    // Note: CPNowPlayingTemplate cannot be added to tab bar - it's shown automatically
    // by the system when audio is playing. We only set up the library as root.
    interfaceController?.setRootTemplate(libraryTemplate!, animated: true, completion: nil)
    
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
    
    let template = CPListTemplate(title: Strings.CarPlay.library, sections: [section])
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
    
    // Check if book is downloaded for offline play
    guard isDownloaded(book) else {
      showErrorAlert(
        title: Strings.CarPlay.Error.notDownloaded,
        message: Strings.CarPlay.Error.downloadRequired
      )
      completion()
      return
    }
    
    // Check network connectivity for streaming content that requires it
    if !Reachability.shared.isConnectedToNetwork() && !isFullyDownloaded(book) {
      showErrorAlert(
        title: Strings.CarPlay.Error.offline,
        message: Strings.CarPlay.Error.offlineMessage
      )
      completion()
      return
    }
    
    // Stop any existing playback and clean up before starting new book
    playerBridge.stopCurrentPlayback()
    
    // Pop to root to clear any stacked templates (only if not already at root)
    if let controller = interfaceController, controller.templates.count > 1 {
      controller.popToRootTemplate(animated: false, completion: nil)
    }
    
    // Start playback through the bridge
    playerBridge.playAudiobook(book) { [weak self] success in
      if success {
        // Switch to Now Playing view
        self?.switchToNowPlaying()
      } else {
        Log.error(#file, "CarPlay: Failed to start playback for '\(book.title)'")
        self?.showErrorAlert(
          title: Strings.CarPlay.Error.playbackFailed,
          message: Strings.CarPlay.Error.tryAgain
        )
      }
      completion()
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
    
    // Configure playback buttons
    let rateButton = CPNowPlayingPlaybackRateButton { [weak self] button in
      self?.playerBridge.cyclePlaybackRate()
    }
    
    nowPlayingTemplate.updateNowPlayingButtons([rateButton])
    
    // Add chapter list if available
    updateChapterList()
  }
  
  private func updateChapterList() {
    guard let chapters = playerBridge.currentChapters, !chapters.isEmpty else {
      nowPlayingTemplate?.isUpNextButtonEnabled = false
      return
    }
    
    nowPlayingTemplate?.isUpNextButtonEnabled = true
    nowPlayingTemplate?.upNextTitle = Strings.CarPlay.chapters
  }
  
  // MARK: - Chapter List
  
  private func showChapterList() {
    guard let chapters = playerBridge.currentChapters, !chapters.isEmpty else {
      Log.warn(#file, "CarPlay: No chapters available to display")
      return
    }
    
    Log.info(#file, "CarPlay: Showing chapter list with \(chapters.count) chapters")
    
    let items = chapters.prefix(Layout.maxChapterItems).enumerated().map { index, chapter in
      createChapterItem(chapter: chapter, index: index)
    }
    
    let section = CPListSection(items: items)
    let chapterTemplate = CPListTemplate(title: Strings.CarPlay.chapters, sections: [section])
    
    interfaceController?.pushTemplate(chapterTemplate, animated: true, completion: nil)
  }
  
  private func createChapterItem(chapter: Chapter, index: Int) -> CPListItem {
    let title = chapter.title ?? Strings.CarPlay.chapterNumber(index + 1)
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
    
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    
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
    guard let nowPlayingTemplate = nowPlayingTemplate else { return }
    
    interfaceController?.pushTemplate(nowPlayingTemplate, animated: true, completion: nil)
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
    }
  }
}

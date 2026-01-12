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
final class CarPlayTemplateManager {
  
  // MARK: - Constants
  
  private enum Layout {
    static let maxListItems = 20
    static let artworkSize = CGSize(width: 90, height: 90)
  }
  
  private enum TabIdentifier {
    static let library = "library"
    static let nowPlaying = "nowPlaying"
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
    
    setupPlayerBridgeBindings()
  }
  
  // MARK: - Public Methods
  
  func setupRootTemplate() {
    libraryTemplate = createLibraryTemplate()
    nowPlayingTemplate = CPNowPlayingTemplate.shared
    
    configureNowPlayingTemplate()
    
    let tabBar = CPTabBarTemplate(templates: [
      libraryTemplate!,
      nowPlayingTemplate!
    ])
    
    interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    
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
      detailText: book.authors ?? Strings.Generic.unknownAuthor
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
    
    // Start playback through the bridge
    playerBridge.playAudiobook(book) { [weak self] success in
      if success {
        // Switch to Now Playing tab
        self?.switchToNowPlaying()
      } else {
        Log.error(#file, "CarPlay: Failed to start playback for '\(book.title)'")
      }
      completion()
    }
  }
  
  // MARK: - Now Playing Template
  
  private func configureNowPlayingTemplate() {
    guard let nowPlayingTemplate = nowPlayingTemplate else { return }
    
    nowPlayingTemplate.tabTitle = Strings.CarPlay.nowPlaying
    nowPlayingTemplate.tabImage = UIImage(systemName: "play.circle")
    
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
  
  private func switchToNowPlaying() {
    guard let interfaceController = interfaceController,
          let rootTemplate = interfaceController.rootTemplate as? CPTabBarTemplate,
          let nowPlayingTemplate = nowPlayingTemplate else { return }
    
    rootTemplate.selectTemplate(nowPlayingTemplate)
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
  }
}

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

/// Manages CarPlay template hierarchy and navigation for audiobook playback.
/// Pure UI layer - all playback logic delegated to AudiobookSessionManager via CarPlayAudiobookBridge.
/// Template construction is delegated to CarPlayTemplateBuilder.
@MainActor
final class CarPlayTemplateManager: NSObject {

    // MARK: - Properties

    private weak var interfaceController: CPInterfaceController?
    private let imageProvider: CarPlayImageProvider
    private let playerBridge: CarPlayAudiobookBridge
    private var cancellables = Set<AnyCancellable>()

    private var libraryTemplate: CPListTemplate?
    private var nowPlayingTemplate: CPNowPlayingTemplate?
    private var isPushingNowPlaying = false
    private var isShowingNowPlaying = false
    private var isLoadingBook = false
    private var lastSelectedBookId: String?
    private var lastSelectionTime: Date?
    private var hasConfiguredNowPlaying = false

    // MARK: - Initialization

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.imageProvider = CarPlayImageProvider()
        self.playerBridge = CarPlayAudiobookBridge()

        super.init()

        interfaceController.delegate = self
        setupPlayerBridgeBindings()
    }

    deinit {
        if hasConfiguredNowPlaying, let nowPlayingTemplate = nowPlayingTemplate {
            nowPlayingTemplate.remove(self)
            Log.debug(#file, "CarPlay: Removed Now Playing observer during deinit")
        }
    }

    // MARK: - Public Methods

    func setupRootTemplate() {
        libraryTemplate = CarPlayTemplateBuilder.makeLibraryTemplate(
            books: CarPlayTemplateBuilder.fetchDownloadedAudiobooks(),
            imageProvider: imageProvider,
            selectionHandler: { [weak self] book, completion in
                self?.handleBookSelection(book, completion: completion)
            }
        )

        guard let libraryTemplate = libraryTemplate else {
            Log.error(#file, "CarPlay: Failed to create library template")
            return
        }
        interfaceController?.setRootTemplate(libraryTemplate, animated: true, completion: nil)

        Log.info(#file, "CarPlay root template configured")
    }

    func refreshLibrary() {
        guard let libraryTemplate = libraryTemplate else { return }

        let items = CarPlayTemplateBuilder.makeLibraryItems(
            books: CarPlayTemplateBuilder.fetchDownloadedAudiobooks(),
            imageProvider: imageProvider,
            selectionHandler: { [weak self] book, completion in
                self?.handleBookSelection(book, completion: completion)
            }
        )
        let section = CPListSection(items: items)
        libraryTemplate.updateSections([section])

        Log.debug(#file, "CarPlay library refreshed with \(items.count) audiobooks")
    }

    func updateLibraryName() {
        guard libraryTemplate != nil else { return }

        let libraryName = AccountsManager.shared.currentAccount?.name ?? Strings.CarPlay.library
        Log.info(#file, "Library name should be: '\(libraryName)' - Note: CPListTemplate title cannot be updated after creation")

        if let controller = interfaceController {
            let newLibraryTemplate = CarPlayTemplateBuilder.makeLibraryTemplate(
                books: CarPlayTemplateBuilder.fetchDownloadedAudiobooks(),
                imageProvider: imageProvider,
                selectionHandler: { [weak self] book, completion in
                    self?.handleBookSelection(book, completion: completion)
                }
            )
            self.libraryTemplate = newLibraryTemplate
            controller.setRootTemplate(newLibraryTemplate, animated: true, completion: nil)
            Log.info(#file, "CarPlay library template replaced with new name: '\(libraryName)'")
        }
    }

    // MARK: - Book Selection

    private func handleBookSelection(_ book: TPPBook, completion: @escaping () -> Void) {
        Log.info(#file, "CarPlay: User selected audiobook '\(book.title)'")
        completion()

        let now = Date()
        if let lastTime = lastSelectionTime,
           let lastId = lastSelectedBookId,
           lastId == book.identifier,
           now.timeIntervalSince(lastTime) < 1.0 {
            Log.info(#file, "CarPlay: Ignoring duplicate selection within 1 second")
            return
        }

        if isLoadingBook {
            Log.info(#file, "CarPlay: Ignoring selection - another book is currently loading")
            return
        }

        lastSelectedBookId = book.identifier
        lastSelectionTime = now

        let mainSceneConnected = SceneDelegate.hasMainSceneConnected
        Log.info(#file, "CarPlay: Main scene connected: \(mainSceneConnected)")

        if !mainSceneConnected {
            Log.info(#file, "CarPlay: Main scene not connected - showing open app alert")
            showOpenAppAlert()
            return
        }

        guard CarPlayAuthHelper.isAuthenticated() else {
            Log.warn(#file, "CarPlay: User not authenticated")
            showErrorAlert(
                title: Strings.CarPlay.Error.authRequired,
                message: Strings.CarPlay.Error.authMessage
            )
            return
        }

        guard CarPlayTemplateBuilder.isDownloaded(book) else {
            showErrorAlert(
                title: Strings.CarPlay.Error.notDownloaded,
                message: Strings.CarPlay.Error.downloadRequired
            )
            return
        }

        let isOffline = !Reachability.shared.isConnectedToNetwork()
        let needsNetwork = !CarPlayTemplateBuilder.isFullyDownloaded(book)

        if isOffline && needsNetwork {
            Log.warn(#file, "CarPlay: Offline and book not fully downloaded")
            showErrorAlert(
                title: Strings.CarPlay.Error.offline,
                message: Strings.CarPlay.Error.offlineMessage
            )
            return
        }

        if let controller = interfaceController, controller.templates.count > 1 {
            controller.popToRootTemplate(animated: false, completion: nil)
        }

        isLoadingBook = true

        playerBridge.playAudiobook(book) { [weak self] result in
            self?.isLoadingBook = false

            switch result {
            case .success:
                Log.info(#file, "CarPlay: Playback started successfully for '\(book.title)'")
            case .failure(let error):
                Log.error(#file, "CarPlay: Failed to start playback for '\(book.title)': \(error)")
                self?.handlePlaybackError(error)
            }
        }
    }

    // MARK: - Error Handling

    private func handlePlaybackError(_ error: CarPlayPlaybackError) {
        switch error {
        case .authenticationRequired:
            showErrorAlert(title: Strings.CarPlay.Error.authRequired, message: Strings.CarPlay.Error.authMessage)
        case .networkError:
            showErrorAlert(title: Strings.CarPlay.Error.offline, message: Strings.CarPlay.Error.offlineMessage)
        case .drmError:
            showErrorAlert(title: Strings.CarPlay.Error.playbackFailed, message: Strings.CarPlay.Error.drmMessage)
        case .notDownloaded:
            showErrorAlert(title: Strings.CarPlay.Error.notDownloaded, message: Strings.CarPlay.Error.downloadRequired)
        case .unknown:
            showErrorAlert(title: Strings.CarPlay.Error.playbackFailed, message: Strings.CarPlay.Error.tryAgain)
        }
    }

    private func showErrorAlert(title: String, message: String) {
        guard let interfaceController = interfaceController else { return }

        let alert = CarPlayTemplateBuilder.makeErrorAlert(
            title: title,
            message: message,
            dismissHandler: {
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private func showOpenAppAlert() {
        guard let interfaceController = interfaceController else { return }

        let alert = CarPlayTemplateBuilder.makeOpenAppAlert(
            dismissHandler: {
                interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        )
        interfaceController.presentTemplate(alert, animated: true) { _, error in
            if let error = error {
                Log.warn(#file, "CarPlay: Failed to present open app alert: \(error)")
            }
        }
    }

    // MARK: - Now Playing

    private func configureNowPlayingTemplateIfNeeded() {
        guard !hasConfiguredNowPlaying else {
            Log.debug(#file, "CarPlay: Now Playing template already configured")
            return
        }

        nowPlayingTemplate = CPNowPlayingTemplate.shared
        guard let nowPlayingTemplate = nowPlayingTemplate else {
            Log.error(#file, "CarPlay: Failed to get shared Now Playing template")
            return
        }

        Log.info(#file, "CarPlay: Configuring Now Playing template (playback active)")

        nowPlayingTemplate.tabTitle = Strings.CarPlay.nowPlaying
        nowPlayingTemplate.tabImage = UIImage(systemName: "play.circle")
        nowPlayingTemplate.add(self)

        CarPlayTemplateBuilder.configureNowPlayingButtons(
            on: nowPlayingTemplate,
            rateHandler: { [weak self] in
                self?.playerBridge.cyclePlaybackRate()
            },
            tocHandler: { [weak self] in
                self?.showChapterList()
            }
        )

        hasConfiguredNowPlaying = true
        Log.info(#file, "CarPlay: Now Playing template configured successfully")
    }

    private func showChapterList() {
        configureNowPlayingTemplateIfNeeded()

        guard let chapters = playerBridge.currentChapters, !chapters.isEmpty else {
            Log.warn(#file, "CarPlay: No chapters available to display")
            return
        }

        Log.info(#file, "CarPlay: Showing chapter list with \(chapters.count) chapters")

        let chapterTemplate = CarPlayTemplateBuilder.makeChapterListTemplate(
            chapters: chapters,
            currentChapter: playerBridge.currentChapter,
            chapterSelectedHandler: { [weak self] index in
                self?.playerBridge.skipToChapter(at: index)
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
        )

        interfaceController?.pushTemplate(chapterTemplate, animated: true, completion: nil)
    }

    private func switchToNowPlaying() {
        configureNowPlayingTemplateIfNeeded()

        guard let nowPlayingTemplate = nowPlayingTemplate else {
            Log.warn(#file, "CarPlay: No Now Playing template available")
            return
        }

        Log.info(#file, "CarPlay: Pushing Now Playing template")
        interfaceController?.pushTemplate(nowPlayingTemplate, animated: true) { [weak self] _, error in
            if let error = error {
                Log.error(#file, "CarPlay: Failed to push Now Playing: \(error)")
            } else {
                Log.info(#file, "CarPlay: Now Playing template pushed successfully")
                self?.isShowingNowPlaying = true
            }
        }
    }

    private func switchToNowPlayingIfNeeded() {
        Log.debug(#file, "CarPlay: switchToNowPlayingIfNeeded called")

        guard let controller = interfaceController else {
            Log.warn(#file, "CarPlay: No interface controller")
            return
        }

        if let top = controller.topTemplate, top is CPNowPlayingTemplate {
            Log.debug(#file, "CarPlay: Already showing Now Playing, skipping push")
            return
        }

        guard !isPushingNowPlaying else {
            Log.debug(#file, "CarPlay: Already pushing Now Playing, skipping")
            return
        }

        isPushingNowPlaying = true
        Log.debug(#file, "CarPlay: Will push Now Playing in 0.15s")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }

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

    // MARK: - Player Bridge Bindings

    private func setupPlayerBridgeBindings() {
        playerBridge.chapterUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Chapters updated - TOC button will show them
                _ = self
            }
            .store(in: &cancellables)

        playerBridge.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Log.debug(#file, "CarPlay: Received playback state: \(state)")
                if case .playing = state {
                    Log.debug(#file, "CarPlay: Playback started - will switch to Now Playing")
                    self?.switchToNowPlayingIfNeeded()
                }
            }
            .store(in: &cancellables)

        playerBridge.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                Log.error(#file, "CarPlay: Received playback error: \(error)")
                self?.handlePlaybackError(error)
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
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {}

    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {}

    func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        Log.debug(#file, "CarPlay: Template will disappear: \(type(of: aTemplate))")
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        Log.debug(#file, "CarPlay: Template did disappear: \(type(of: aTemplate))")

        if aTemplate is CPNowPlayingTemplate && isShowingNowPlaying {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let templateCount = self.interfaceController?.templates.count, templateCount <= 1 {
                    Log.info(#file, "CarPlay: User returned to library - keeping playback active")
                    self.isShowingNowPlaying = false
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

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
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

        enum OpenApp {
            static let message = NSLocalizedString(
                "CarPlay.OpenApp.message",
                value: "Please open Palace on your phone first, then select the book again",
                comment: "CarPlay alert message asking user to open the app on their phone"
            )
            static let messageShort = NSLocalizedString(
                "CarPlay.OpenApp.messageShort",
                value: "Open Palace on your phone first",
                comment: "CarPlay alert short message asking user to open the app"
            )
            static let messageShortest = NSLocalizedString(
                "CarPlay.OpenApp.messageShortest",
                value: "Open Palace first",
                comment: "CarPlay alert shortest message"
            )
        }
    }
}

//
//  CarPlayTemplateBuilder.swift
//  Palace
//
//  Extracted from CarPlayTemplateManager to separate template construction
//  from lifecycle coordination.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import CarPlay
import PalaceAudiobookToolkit

/// Pure factory for building CarPlay templates.
/// Stateless — all context is passed in via parameters.
enum CarPlayTemplateBuilder {

    // MARK: - Layout Constants

    /// Apple CarPlay Guidelines (CarPlay-Audio-App-Programming-Guide.pdf):
    /// - Max hierarchy depth: 5 levels (we use ~3-4)
    /// - Chapter lists are explicitly allowed for audiobook navigation
    /// Following Apple Books' approach: show all chapters, let user scroll
    private enum Layout {
        static let maxListItems = 20
        static let artworkSize = CGSize(width: 90, height: 90)
    }

    // MARK: - Library Template

    static func makeLibraryTemplate(
        books: [TPPBook],
        imageProvider: CarPlayImageProvider,
        selectionHandler: @escaping (TPPBook, @escaping () -> Void) -> Void
    ) -> CPListTemplate {
        let items = makeLibraryItems(
            books: books,
            imageProvider: imageProvider,
            selectionHandler: selectionHandler
        )
        let section = CPListSection(items: items)

        let libraryName = AccountsManager.shared.currentAccount?.name ?? Strings.CarPlay.library

        let template = CPListTemplate(title: libraryName, sections: [section])
        template.tabTitle = Strings.CarPlay.library
        template.tabImage = UIImage(systemName: "books.vertical")
        template.emptyViewTitleVariants = [Strings.CarPlay.noAudiobooks]
        template.emptyViewSubtitleVariants = [Strings.CarPlay.downloadAudiobooks]

        return template
    }

    static func makeLibraryItems(
        books: [TPPBook],
        imageProvider: CarPlayImageProvider,
        selectionHandler: @escaping (TPPBook, @escaping () -> Void) -> Void
    ) -> [CPListItem] {
        if books.isEmpty {
            let placeholderItem = CPListItem(
                text: "No Audiobooks Downloaded",
                detailText: "Download audiobooks in the Palace app first"
            )
            placeholderItem.handler = { _, completion in
                Log.info(#file, "CarPlay: Placeholder item tapped")
                completion()
            }
            return [placeholderItem]
        }

        return books.prefix(Layout.maxListItems).map { book in
            makeListItem(for: book, imageProvider: imageProvider, selectionHandler: selectionHandler)
        }
    }

    static func makeListItem(
        for book: TPPBook,
        imageProvider: CarPlayImageProvider,
        selectionHandler: @escaping (TPPBook, @escaping () -> Void) -> Void
    ) -> CPListItem {
        let placeholderImage = UIImage(systemName: "headphones") ?? UIImage()

        let item = CPListItem(
            text: book.title,
            detailText: book.authors ?? "Unknown Author",
            image: placeholderImage
        )

        item.accessoryType = .disclosureIndicator
        item.userInfo = ["bookIdentifier": book.identifier]

        // Load actual artwork asynchronously
        imageProvider.artwork(for: book) { [weak item] image in
            guard let image = image else { return }
            DispatchQueue.main.async {
                item?.setImage(image)
            }
        }

        item.handler = { _, completion in
            selectionHandler(book, completion)
        }

        return item
    }

    // MARK: - Chapter List

    static func makeChapterListTemplate(
        chapters: [Chapter],
        currentChapter: Chapter?,
        chapterSelectedHandler: @escaping (Int) -> Void
    ) -> CPListTemplate {
        let items = chapters.enumerated().map { index, chapter in
            makeChapterItem(
                chapter: chapter,
                index: index,
                currentChapter: currentChapter,
                selectedHandler: chapterSelectedHandler
            )
        }

        let section = CPListSection(items: items)
        return CPListTemplate(title: Strings.CarPlay.chapters, sections: [section])
    }

    static func makeChapterItem(
        chapter: Chapter,
        index: Int,
        currentChapter: Chapter?,
        selectedHandler: @escaping (Int) -> Void
    ) -> CPListItem {
        let title = chapter.title
        let duration = formatDuration(chapter.duration)

        let item = CPListItem(text: title, detailText: duration)
        item.userInfo = ["chapterIndex": index]

        if let currentChapter = currentChapter,
           currentChapter.position.track.key == chapter.position.track.key {
            item.isPlaying = true
        }

        item.handler = { _, completion in
            selectedHandler(index)
            completion()
        }

        return item
    }

    // MARK: - Now Playing

    static func configureNowPlayingButtons(
        on template: CPNowPlayingTemplate,
        rateHandler: @escaping () -> Void,
        tocHandler: @escaping () -> Void
    ) {
        let rateButton = CPNowPlayingPlaybackRateButton { _ in
            rateHandler()
        }

        guard let tocImage = UIImage(systemName: "list.bullet") else {
            Log.warn(#file, "CarPlay: Could not load list.bullet image")
            template.updateNowPlayingButtons([rateButton])
            return
        }

        let tocButton = CPNowPlayingImageButton(image: tocImage) { _ in
            Log.info(#file, "CarPlay: TOC button tapped")
            tocHandler()
        }

        template.updateNowPlayingButtons([tocButton, rateButton])
        template.isUpNextButtonEnabled = false
    }

    // MARK: - Alerts

    static func makeErrorAlert(
        title: String,
        message: String,
        dismissHandler: @escaping () -> Void
    ) -> CPAlertTemplate {
        CPAlertTemplate(
            titleVariants: [title],
            actions: [
                CPAlertAction(title: Strings.Generic.ok, style: .default) { _ in
                    dismissHandler()
                }
            ]
        )
    }

    static func makeOpenAppAlert(
        dismissHandler: @escaping () -> Void
    ) -> CPAlertTemplate {
        CPAlertTemplate(
            titleVariants: [
                Strings.CarPlay.OpenApp.message,
                Strings.CarPlay.OpenApp.messageShort,
                Strings.CarPlay.OpenApp.messageShortest
            ],
            actions: [
                CPAlertAction(title: Strings.Generic.ok, style: .default) { _ in
                    dismissHandler()
                }
            ]
        )
    }

    // MARK: - Data Helpers

    static func fetchDownloadedAudiobooks() -> [TPPBook] {
        TPPBookRegistry.shared.myBooks
            .filter { $0.isAudiobook }
            .filter { isDownloaded($0) }
            .sorted { ($0.title) < ($1.title) }
    }

    static func isDownloaded(_ book: TPPBook) -> Bool {
        let state = TPPBookRegistry.shared.state(for: book.identifier)
        return state == .downloadSuccessful || state == .used
    }

    static func isFullyDownloaded(_ book: TPPBook) -> Bool {
        let state = TPPBookRegistry.shared.state(for: book.identifier)
        return state == .downloadSuccessful || state == .used
    }

    // MARK: - Formatting

    static func formatDuration(_ duration: Double?) -> String {
        guard let duration = duration, duration > 0 else {
            return ""
        }

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
}

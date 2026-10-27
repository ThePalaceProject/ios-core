//
//  BookDetailViewModel+StreamableLoanListen.swift
//  Palace
//
//  Opening the reader or player from the detail screen, and (PP-5402) the
//  Listen tap on a loan whose license has not been fetched yet.
//

import Foundation
import PalaceBookModel
import PalaceLogging

extension BookDetailViewModel {

    func openForReading(_ button: BookButtonType) {
        // PP-4633: dismiss the half-sheet so it does not linger over the
        // reader/player (on iPad it is a floating form-sheet). Dismiss only
        // AFTER the reader/player is presented: dismissing while the player
        // is presenting races the two modal transitions on iPad and freezes
        // the screen.
        //
        // Audiobooks dismiss early via `onLoadingShellPresented`, because the
        // open completion waits for the content download (PP-4542). The
        // completion dismissal stays as an idempotent backstop for EPUB and
        // for opens that fail before a shell is shown.
        didSelectRead(for: book, completion: {
            self.removeProcessingButton(button)
            self.showHalfSheet = false
        }, onLoadingShellPresented: { [weak self] in
            // Defer one runloop tick so the player's present commits first;
            // same-tick dismissal is the PP-4633 iPad modal race.
            DispatchQueue.main.async { self?.showHalfSheet = false }
        })
    }

    /// Whether Listen on this book must fetch the license before the player can open.
    var listenNeedsLicenseFirst: Bool {
        registry.state(for: book.identifier) == .downloadNeeded
            && StreamableLoanListen.offersListen(book: book, streamingEnabled: downloadCenter.lcpStreamingEnabledProvider())
    }

    func advancePendingListen(on state: TPPBookState) {
        guard let phase = pendingListen else { return }
        switch StreamableLoanListen.step(phase, on: state) {
        case .open:
            pendingListen = nil
            openForReading(.listen)
        case .wait(let next):
            pendingListen = next
        case .abandon:
            pendingListen = nil
            removeProcessingButton(.listen)
        }
    }

    @MainActor
    func openBook(_ book: TPPBook, completion: (() -> Void)?, onLoadingShellPresented: (@MainActor () -> Void)? = nil) {
        Log.debug(#file, "🎬 [OPEN BOOK] User requested to open book: \(book.title) (ID: \(book.identifier))")
        TPPCirculationAnalytics.postEvent("open_book", withBook: book)

        let resolvedBook = registry.book(forIdentifier: book.identifier) ?? book
        let destination = BookOpenRouter.destination(for: resolvedBook)

        Log.debug(#file, "  Routing \(TPPBookContentTypeConverter.stringValue(of: resolvedBook.defaultBookContentType)) to \(destination); distributor: \(resolvedBook.distributor ?? "nil")")

        // Every arm below clears `processingButtons` — a button left spinning is
        // a stuck screen. `.unsupported` deliberately does NOT report
        // completion: it ends in an alert, not in a reader.
        let finishOnMain: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.processingButtons.removeAll()
                completion?()
            }
        }

        switch destination {
        case .epubReader, .pdfReader:
            BookOpenRouter.open(resolvedBook, bookRegistry: registry, onFinish: finishOnMain)
        case .audiobookSession:
            openAudiobook(resolvedBook, completion: finishOnMain, onLoadingShellPresented: onLoadingShellPresented)
        case .streamingReader:
            // PP-4161: `handleAction(.readStreaming)` is the canonical entry
            // point; this arm covers the rare path where another call site
            // funnels a streamingHTML book through `openBook` (a
            // coordinator-level resume, say).
            BookOpenRouter.presentStreamingReader(resolvedBook)
            processingButtons.removeAll()
            completion?()
        case .unsupported:
            processingButtons.removeAll()
            presentUnsupportedItemError()
        }
    }
}

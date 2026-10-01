//
//  Routes a book to the reader that can render it. Lives in AppInfrastructure,
//  not Palace/Book/, because a router that knows every reader is composition;
//  this keeps Book from depending on PDF (cycle 8 in
//  docs/architecture/god-class-decomposition-plan.md).
//
//  `destination(for:)` is the pure, table-testable decision; `open(_:...)`
//  performs it, including the per-identifier lock that stops a second tap from
//  starting a parallel open. `BookService.open` forwards here.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry
import PalaceLogging

/// Which reader a book opens in. One case per `TPPBookContentType`, so the
/// mapping is total and a new content type cannot be added without choosing a
/// destination for it.
enum BookOpenDestination: Equatable {
    case epubReader
    case pdfReader
    case audiobookSession
    /// PP-4161 streaming-media: the in-app WKWebView shell, reached through
    /// `NavigationCoordinator` rather than through a reader module.
    case streamingReader
    /// No reader can render this acquisition. The caller surfaces the
    /// format error; note that this arm does NOT report completion — see
    /// `BookDetailViewModel.openBook`.
    case unsupported
}

@MainActor
enum BookOpenRouter {

    // MARK: - The decision

    /// The format -> destination table. Pure, total, and free of the reader
    /// stack, so every cell is assertable directly.
    static func destination(for contentType: TPPBookContentType) -> BookOpenDestination {
        switch contentType {
        case .epub: return .epubReader
        case .pdf: return .pdfReader
        case .audiobook: return .audiobookSession
        case .streamingHTML: return .streamingReader
        case .unsupported: return .unsupported
        }
    }

    /// Convenience over a book's default content type — the form both call
    /// sites use.
    static func destination(for book: TPPBook) -> BookOpenDestination {
        destination(for: book.defaultBookContentType)
    }

    // MARK: - Performing it

    /// Safety cap: if the open pipeline never reports completion (hang, timeout,
    /// unhandled throw inside a Task), releasing after this window prevents the
    /// lock from latching permanently and silently swallowing every retry.
    private static let openLockSafetyRelease: TimeInterval = 30

    // Main-actor-confined: every mutation already happens on the main thread
    // (callers are `@MainActor` view models; the safety-release and dispatch
    // hops run on `DispatchQueue.main`). Isolating the lock to the main actor
    // documents that invariant and clears the nonisolated-global-mutable-state
    // warning without changing the threading.
    private static var openingBooks = Set<String>()

    /// - parameter onLoadingShellPresented: audiobook-only early hook — fired the
    ///   moment the morphing player's loading shell is presented (before the
    ///   PP-4542 content-download wait) so a presenting caller can dismiss its
    ///   transient UI (BookDetail half-sheet) immediately rather than after full
    ///   playback readiness. Nil for EPUB/PDF/streaming (they present promptly and
    ///   rely on `onFinish`). fix/audiobook-first-open-hang.
    static func open(_ book: TPPBook,
                     bookRegistry: TPPBookRegistryProvider,
                     audiobookSession: AudiobookSessionManaging? = nil,
                     onFinish: (() -> Void)? = nil,
                     onLoadingShellPresented: (@MainActor () -> Void)? = nil) {
        guard !openingBooks.contains(book.identifier) else {
            Log.warn(#file, "Book \(book.title) is already being opened, ignoring duplicate request")
            onFinish?()
            return
        }

        openingBooks.insert(book.identifier)
        scheduleOpenLockSafetyRelease(for: book.identifier)
        let resolvedBook = bookRegistry.book(forIdentifier: book.identifier) ?? book

        dispatch(resolvedBook,
                 audiobookSession: audiobookSession,
                 onFinish: onFinish,
                 onLoadingShellPresented: onLoadingShellPresented)
    }

    /// Pushes the streaming-HTML route after storing the book payload so the
    /// destination resolver can look it up. Shared by `BookService`/this router's
    /// dispatch and by `BookDetailViewModel`'s direct `.readStreaming` action,
    /// which reaches the shell without going through the open lock.
    static func presentStreamingReader(_ book: TPPBook) {
        guard let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator else {
            // PP-5022 — a warn line is not a patron-visible outcome.
            ReaderService.presentUnreachableReaderAlert(for: book, source: "BookOpenRouter.presentStreamingReader")
            return
        }
        coordinator.store(book: book)
        coordinator.push(.streamingHTML(BookRoute(id: book.identifier)))
    }

    private static func scheduleOpenLockSafetyRelease(for identifier: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + openLockSafetyRelease) {
            // Runs on the main queue; `assumeIsolated` bridges the non-isolated
            // dispatch closure to the main actor so the `openingBooks` access is
            // statically safe without altering the existing timing behavior.
            MainActor.assumeIsolated {
                if openingBooks.remove(identifier) != nil {
                    Log.warn(#file, "⏱️ Open lock for \(identifier) auto-released after \(Int(openLockSafetyRelease))s — pipeline never reported completion")
                }
            }
        }
    }

    private static func dispatch(_ book: TPPBook,
                                 audiobookSession: AudiobookSessionManaging?,
                                 onFinish: (() -> Void)?,
                                 onLoadingShellPresented: (@MainActor () -> Void)?) {
        switch destination(for: book) {
        case .epubReader:
            Task { @MainActor in
                defer { finish(book.identifier, onFinish) }
                AppContainer.production().readerService.openEPUB(book)
            }
        case .pdfReader:
            Task { @MainActor in
                presentPDF(book) { finish(book.identifier, onFinish) }
            }
        case .audiobookSession:
            // Route through the single audiobook owner. The session manager
            // stops the previous session (releasing its DRM decryptor) before
            // loading the new audiobook — the ordering invariant that prevents
            // a stale LCP Publication from hanging publicationOpener.open().
            let session = audiobookSession ?? AppContainer.production().audiobookSession
            Task { @MainActor in
                defer { finish(book.identifier, onFinish) }
                _ = await session.openAudiobook(
                    book,
                    startPlaying: true,
                    onLoadingShellPresented: onLoadingShellPresented
                )
            }
        case .streamingReader:
            // PP-4161: streaming-HTML titles route through NavigationCoordinator
            // directly — no AudiobookSessionManager-style lifecycle owner,
            // no LCP / DRM grant, no on-disk asset.
            Task { @MainActor in
                defer { finish(book.identifier, onFinish) }
                presentStreamingReader(book)
            }
        case .unsupported:
            finish(book.identifier, onFinish)
        }
    }

    private static func finish(_ identifier: String, _ onFinish: (() -> Void)?) {
        openingBooks.remove(identifier)
        onFinish?()
    }

    private static func presentPDF(_ book: TPPBook, completion: (() -> Void)? = nil) {
        // Single PDF seam: `ReaderService.openPDF` gates LCP vs plain
        // internally. LCP-protected PDFs stream through Readium's
        // publication-open + disk-extract pipeline; plain (non-LCP) PDFs use
        // PDFKit's `PDFDocument(url:)` mmap path. Routing lives in one place
        // (ReaderService) so BookDetail, My Books, and the Continue-reading
        // card can't drift apart — the Continue card previously bypassed this
        // gate and failed to open plain PDFs. `completion` fires once the open
        // has been dispatched (immediately for plain; after the async
        // publication open for LCP — the caller typically holds a loading
        // indicator on it).
        AppContainer.production().readerService.openPDF(book) {
            completion?()
        }
    }
}

//
//  Routes a book to the reader that can render it. Lives in AppInfrastructure,
//  not Palace/Book/, because a router that knows every reader is composition;
//  this keeps Book from depending on PDF (cycle 8 in
//  docs/architecture/god-class-decomposition-plan.md).
//
//  `destination(for:)` is the pure, table-testable decision; `open(_:...)`
//  performs it, including the per-identifier lock that stops a second tap from
//  starting a parallel open. Callers pass the registry they were built with.
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
    /// `internal` and `nonisolated`, not private: `AudiobookOpenTrace.stallDeadline`
    /// reads it from outside the main actor so the stall report fires exactly
    /// when the lock lets a new open through.
    nonisolated static let openLockSafetyRelease: TimeInterval = 30

    // Main-actor-confined: every mutation already happens on the main thread
    // (callers are `@MainActor` view models; the safety-release and dispatch
    // hops run on `DispatchQueue.main`). Isolating the lock to the main actor
    // documents that invariant and clears the nonisolated-global-mutable-state
    // warning without changing the threading.
    //
    // Each open holds its own token, so a stale release (an earlier open's
    // safety timer, or its finish arriving after that timer fired) cannot
    // free the lock of a later open of the same book.
    private static var openingBooks = [String: UUID]()

    // MARK: - Test-only join for open tasks

    /// Gates retention below so a release build never populates the task list.
    private static let isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Open tasks whose body ends in `finish`, retained only under XCTest so a
    /// test can join the open instead of waiting on a wall-clock deadline that
    /// starves under parallel simulator clones.
    private static var retainedOpenTasks: [Task<Void, Never>] = []

    private static func spawnOpenTask(_ body: @escaping @MainActor () async -> Void) {
        let task = Task { @MainActor in await body() }
        if isRunningUnderXCTest {
            retainedOpenTasks.append(task)
        }
    }

    /// Awaits every retained open task, so `onFinish` has run for each open
    /// dispatched so far. Drains the list as it goes, repeating until no new
    /// task was added while awaiting. The PDF arm completes from the reader's
    /// callback rather than inside its task, so this does not cover it.
    static func _awaitOpenTasksForTesting() async {
        while !retainedOpenTasks.isEmpty {
            let tasks = retainedOpenTasks
            retainedOpenTasks.removeAll()
            for task in tasks { await task.value }
        }
    }

    /// - parameter onLoadingShellPresented: audiobook-only early hook — fired the
    ///   moment the morphing player's loading shell is presented (before the
    ///   PP-4542 content-download wait) so a presenting caller can dismiss its
    ///   transient UI (BookDetail half-sheet) immediately rather than after full
    ///   playback readiness. Nil for EPUB/PDF/streaming (they present promptly and
    ///   rely on `onFinish`). fix/audiobook-first-open-hang.
    /// - parameter scheduleSafetyRelease: runs the lock's safety release after
    ///   the given delay; tests pass a scheduler they fire by hand.
    static func open(_ book: TPPBook,
                     bookRegistry: TPPBookRegistryProvider,
                     audiobookSession: AudiobookSessionManaging? = nil,
                     onFinish: (() -> Void)? = nil,
                     onLoadingShellPresented: (@MainActor () -> Void)? = nil,
                     scheduleSafetyRelease: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = BookOpenRouter.scheduleOnMainQueue) {
        guard openingBooks[book.identifier] == nil else {
            Log.warn(#file, "Book \(book.title) is already being opened, ignoring duplicate request")
            onFinish?()
            return
        }

        let identifier = book.identifier
        let token = UUID()
        openingBooks[identifier] = token
        scheduleSafetyRelease(openLockSafetyRelease) {
            if releaseLock(identifier, token) {
                Log.warn(#file, "⏱️ Open lock for \(identifier) auto-released after \(Int(openLockSafetyRelease))s — pipeline never reported completion")
            }
        }
        let resolvedBook = bookRegistry.book(forIdentifier: book.identifier) ?? book

        dispatch(resolvedBook,
                 token: token,
                 audiobookSession: audiobookSession,
                 onFinish: onFinish,
                 onLoadingShellPresented: onLoadingShellPresented)
    }

    /// Pushes the streaming-HTML route after storing the book payload so the
    /// destination resolver can look it up. Shared by this router's dispatch and
    /// by `BookDetailViewModel`'s direct `.readStreaming` action, which reaches
    /// the shell without going through the open lock.
    static func presentStreamingReader(_ book: TPPBook) {
        guard let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator else {
            // PP-5022 — a warn line is not a patron-visible outcome.
            ReaderService.presentUnreachableReaderAlert(for: book, source: "BookOpenRouter.presentStreamingReader")
            return
        }
        coordinator.store(book: book)
        coordinator.push(.streamingHTML(BookRoute(id: book.identifier)))
    }

    /// The production scheduler for the open lock's safety release.
    static func scheduleOnMainQueue(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Runs on the main queue; `assumeIsolated` bridges the non-isolated
            // dispatch closure to the main actor so the `openingBooks` access is
            // statically safe.
            MainActor.assumeIsolated { work() }
        }
    }

    private static func dispatch(_ book: TPPBook,
                                 token: UUID,
                                 audiobookSession: AudiobookSessionManaging?,
                                 onFinish: (() -> Void)?,
                                 onLoadingShellPresented: (@MainActor () -> Void)?) {
        switch destination(for: book) {
        case .epubReader:
            spawnOpenTask {
                defer { finish(book.identifier, token, onFinish) }
                AppContainer.production().readerService.openEPUB(book)
            }
        case .pdfReader:
            Task { @MainActor in
                presentPDF(book) { finish(book.identifier, token, onFinish) }
            }
        case .audiobookSession:
            // Route through the single audiobook owner. The session manager
            // stops the previous session (releasing its DRM decryptor) before
            // loading the new audiobook — the ordering invariant that prevents
            // a stale LCP Publication from hanging publicationOpener.open().
            let session = audiobookSession ?? AppContainer.production().audiobookSession
            spawnOpenTask {
                defer { finish(book.identifier, token, onFinish) }
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
            spawnOpenTask {
                defer { finish(book.identifier, token, onFinish) }
                presentStreamingReader(book)
            }
        case .unsupported:
            finish(book.identifier, token, onFinish)
        }
    }

    private static func finish(_ identifier: String, _ token: UUID, _ onFinish: (() -> Void)?) {
        releaseLock(identifier, token)
        onFinish?()
    }

    /// Removes the lock only while it still belongs to the open that took it.
    @discardableResult
    private static func releaseLock(_ identifier: String, _ token: UUID) -> Bool {
        guard openingBooks[identifier] == token else { return false }
        openingBooks[identifier] = nil
        return true
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

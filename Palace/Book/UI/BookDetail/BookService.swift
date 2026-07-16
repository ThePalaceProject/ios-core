import Foundation
import SwiftUI
import Combine
import PalaceAudiobookToolkit
import PalaceLogging

/// Dispatches book-open requests to the right reader/player. Owns only the
/// EPUB and PDF paths directly; audiobook opens delegate to
/// `AudiobookSessionManager.openAudiobook`, which is the sole owner of the
/// audiobook lifecycle (manager, decryptor, playback, navigation).
///
/// Before this refactor, BookService was a static god-utility that built
/// audiobook managers and handed them off via AudiobookEvents.managerCreated.
/// That handoff ran the new open's DRM pipeline while the previous
/// AudiobookManager was still alive, which caused Readium's
/// publicationOpener.open() to hang after a few back-to-back audiobook opens.
/// See AudiobookLoader + AudiobookSessionManager for the new ownership model.
enum BookService {
    // Main-actor-confined: every mutation already happens on the main thread
    // (callers are `@MainActor` view models; the safety-release and dispatch
    // hops run on `DispatchQueue.main`). Isolating the lock to the main actor
    // documents that invariant and clears the nonisolated-global-mutable-state
    // warning without changing the threading.
    @MainActor private static var openingBooks = Set<String>()

    /// Safety cap: if the open pipeline never reports completion (hang, timeout,
    /// unhandled throw inside a Task), releasing after this window prevents the
    /// lock from latching permanently and silently swallowing every retry.
    private static let openLockSafetyRelease: TimeInterval = 30

    /// - parameter onLoadingShellPresented: audiobook-only early hook — fired the
    ///   moment the morphing player's loading shell is presented (before the
    ///   PP-4542 content-download wait) so a presenting caller can dismiss its
    ///   transient UI (BookDetail half-sheet) immediately rather than after full
    ///   playback readiness. Nil for EPUB/PDF/streaming (they present promptly and
    ///   rely on `onFinish`). fix/audiobook-first-open-hang.
    @MainActor
    static func open(_ book: TPPBook, bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry, audiobookSession: AudiobookSessionManaging? = nil, onFinish: (() -> Void)? = nil, onLoadingShellPresented: (@MainActor () -> Void)? = nil) {
        guard !openingBooks.contains(book.identifier) else {
            Log.warn(#file, "Book \(book.title) is already being opened, ignoring duplicate request")
            onFinish?()
            return
        }

        openingBooks.insert(book.identifier)
        scheduleOpenLockSafetyRelease(for: book.identifier)
        let resolvedBook = bookRegistry.book(forIdentifier: book.identifier) ?? book

        dispatchOpen(resolvedBook, audiobookSession: audiobookSession, onFinish: onFinish, onLoadingShellPresented: onLoadingShellPresented)
    }

    @MainActor
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

    @MainActor
    private static func dispatchOpen(_ book: TPPBook, audiobookSession: AudiobookSessionManaging? = nil, onFinish: (() -> Void)?, onLoadingShellPresented: (@MainActor () -> Void)? = nil) {
        switch book.defaultBookContentType {
        case .epub:
            Task { @MainActor in
                defer {
                    openingBooks.remove(book.identifier)
                    onFinish?()
                }
                AppContainer.production().readerService.openEPUB(book)
            }
        case .pdf:
            Task { @MainActor in
                presentPDF(book) {
                    openingBooks.remove(book.identifier)
                    onFinish?()
                }
            }
        case .audiobook:
            // Route through the single audiobook owner. The session manager
            // stops the previous session (releasing its DRM decryptor) before
            // loading the new audiobook — the ordering invariant that prevents
            // a stale LCP Publication from hanging publicationOpener.open().
            let session = audiobookSession ?? AppContainer.production().audiobookSession
            Task { @MainActor in
                defer {
                    openingBooks.remove(book.identifier)
                    onFinish?()
                }
                _ = await session.openAudiobook(
                    book,
                    startPlaying: true,
                    onLoadingShellPresented: onLoadingShellPresented
                )
            }
        case .streamingHTML:
            // PP-4161: streaming-HTML titles route through NavigationCoordinator
            // directly — no AudiobookSessionManager-style lifecycle owner,
            // no LCP / DRM grant, no on-disk asset.
            Task { @MainActor in
                defer {
                    openingBooks.remove(book.identifier)
                    onFinish?()
                }
                if let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator {
                    coordinator.store(book: book)
                    coordinator.push(.streamingHTML(BookRoute(id: book.identifier)))
                }
            }
        default:
            openingBooks.remove(book.identifier)
            onFinish?()
        }
    }

    @MainActor private static func presentPDF(_ book: TPPBook, completion: (() -> Void)? = nil) {
        // LCP-protected PDFs go through Readium's PDFNavigator — no temp
        // extract, pages stream on demand via the shared httpServer. Use
        // hasLCPAcquisition (walks all acquisitions + indirect chains)
        // rather than canOpenBook so OPDS-Catalog-wrapped LCP PDFs (where
        // the LCP MIME is a sibling acquisition rather than the default)
        // get routed correctly. Defer `completion?()` until the
        // publication opens — LCP open is async (~1–3s) and the caller
        // typically holds a loading indicator on this completion.
        #if LCP
        if LCPPDFs.hasLCPAcquisition(book) {
            AppContainer.production().readerService.openPDF(book) {
                completion?()
            }
            return
        }
        #endif

        // Plain (non-LCP) PDFs keep the PDFKit path: PDFDocument(url:) mmaps
        // the file and pages in on demand without the HTTP-server hop.
        guard let url = AppContainer.production().downloadCenter.fileUrl(for: book.identifier) else { completion?(); return }
        let metadata = TPPPDFDocumentMetadata(with: book)
        let document = TPPPDFDocument(url: url)
        if let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator {
            coordinator.storePDF(document: document, metadata: metadata, forBookId: book.identifier)
            coordinator.push(.pdf(BookRoute(id: book.identifier)))
        }
        completion?()
    }

    /// Shown when an audiobook open fails. Invoked by
    /// `AudiobookSessionManager` after a loader failure, and by the PP-3707
    /// retry path below.
    @MainActor
  static func showAudiobookTryAgainError(book: TPPBook? = nil, onFinish: (() -> Void)? = nil) {
        Log.warn(#file, "⚠️ [ERROR ALERT] Showing 'An error was encountered while trying to open this book' alert to user")

        let error = NSError(
            domain: "AudiobookOpenError",
            code: TPPErrorCode.audiobookCorrupted.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to open audiobook",
                "error_type": "audiobook_open_failure"
            ]
        )
        TPPErrorLogger.logError(
            error,
            summary: "Audiobook failed to open - showing try again error",
            metadata: ["user_message": Strings.Error.tryAgain]
        )

        // Offer retry for audiobook open failures (may be transient)
        let retryAction: (() -> Void)? = {
            guard let book = book else { return nil }
            let operationId = "audiobook-open-\(book.identifier)"
            guard UserRetryTracker.shared.canRetry(operationId: operationId) else { return nil }
            return {
                UserRetryTracker.shared.recordRetry(operationId: operationId)
                BookService.open(book, onFinish: onFinish)
            }
        }()

        if let retryAction = retryAction {
            let alert = UIAlertController(
                title: Strings.Error.openFailedError,
                message: Strings.Error.tryAgain,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: Strings.MyDownloadCenter.retry, style: .default) { _ in retryAction() })
            alert.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel))
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
        } else {
            let message: String
            if let book = book, !UserRetryTracker.shared.canRetry(operationId: "audiobook-open-\(book.identifier)") {
                message = Strings.MyDownloadCenter.tryAgainLater
            } else {
                message = Strings.Error.tryAgain
            }
            let alert = TPPAlertUtils.alert(title: Strings.Error.openFailedError, message: message)
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
        }
    }

    /// Two-step fulfill flow: once we have a book-specific bearer token from
    /// the CM fulfill endpoint, fetch the actual audiobook manifest from the
    /// token's `location` URL. Called by AudiobookLoader and covered by
    /// ManifestFetchTests / FetchManifestWithBearerTokenLCPSafetyTests.
    static func fetchManifestWithBearerToken(
        _ token: MyBooksSimplifiedBearerToken,
        for book: TPPBook,
        session: URLSession = .shared,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        var request = URLRequest(url: token.location)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.applyCustomUserAgent()
        request.cachePolicy = .reloadIgnoringLocalCacheData

        Log.info(#file, "  📡 Fetching manifest from bearer token location: \(token.location.host ?? "unknown")")

        // Box `completion` so the `@Sendable` `dataTask` handler captures a
        // Sendable carrier rather than the raw non-Sendable `([String: Any]?) ->
        // Void` closure. Boxing (vs. marking the parameter `@Sendable`) keeps this
        // static func's public signature unchanged — `@Sendable`ing it would
        // ripple onto the `BearerTokenManifestFetching` protocol and both its
        // production and test conformers in `Palace/Audiobooks/`. INVARIANT: the
        // completion is invoked exactly once, on the URLSession delegate queue,
        // per request — a single-consumer handoff, no shared mutation. Mirrors
        // `ImageCompletionBox` / `SyncCallbacks`.
        let completionBox = ManifestCompletionBox(completion)
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                Log.error(#file, "  ❌ Network error fetching manifest via bearer token: \(error.localizedDescription)")
                completionBox.completion(nil)
                return
            }
            guard let data = data, !data.isEmpty else {
                Log.error(#file, "  ❌ No data received from bearer token manifest fetch")
                completionBox.completion(nil)
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !httpResponse.isSuccess() {
                Log.error(#file, "  ❌ Bearer token manifest fetch failed with HTTP \(httpResponse.statusCode)")
                completionBox.completion(nil)
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                Log.error(#file, "  ❌ Failed to parse bearer token manifest as JSON")
                completionBox.completion(nil)
                return
            }
            Log.info(#file, "  ✅ Successfully fetched manifest via bearer token (\(data.count) bytes)")
            completionBox.completion(json)
        }
        task.resume()
    }
}

/// Sendable carrier for `fetchManifestWithBearerToken`'s non-Sendable
/// `([String: Any]?) -> Void` completion, so the `@Sendable` URLSession
/// `dataTask` handler can capture it under Swift 6 `complete` mode without
/// forcing `@Sendable` onto the public parameter (which would ripple onto the
/// `BearerTokenManifestFetching` protocol in `Palace/Audiobooks/`).
///
/// `@unchecked Sendable` invariant: `completion` is stored once and invoked
/// exactly once, on the URLSession delegate queue, for a single request — a
/// one-shot single-consumer handoff, never mutated or shared. Mirrors
/// `ImageCompletionBox`.
private final class ManifestCompletionBox: @unchecked Sendable {
    let completion: ([String: Any]?) -> Void
    init(_ completion: @escaping ([String: Any]?) -> Void) { self.completion = completion }
}

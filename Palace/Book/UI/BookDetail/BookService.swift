import Foundation
import SwiftUI
import Combine
import PalaceAudiobookToolkit
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry
import PalaceUtilities

/// The book-open entry point callers name, plus two audiobook helpers that are
/// not routing: the open-failure alert and the bearer-token manifest fetch.
///
/// The format -> destination decision and the reader wiring moved to
/// `BookOpenRouter` (Application layer) in Wave 5, so `open` is a forwarder and
/// the readers are reachable from one place. Audiobook opens still land on
/// `AudiobookSessionManager.openAudiobook`, the sole owner of the audiobook
/// lifecycle (manager, decryptor, playback, navigation) — that ownership is what
/// keeps a previous session's DRM decryptor from outliving the next open and
/// hanging Readium's `publicationOpener.open()`. See AudiobookLoader +
/// AudiobookSessionManager.
enum BookService {
    /// Book-open entry point for every caller (BookDetail, My Books, the
    /// audiobook retry action). Forwards to `BookOpenRouter`, which owns the
    /// format -> destination decision, the reader wiring and the per-identifier
    /// reentrancy lock. The signature is unchanged so call sites and
    /// `BookServiceAudiobookOpenTests` are unaffected by the relocation.
    ///
    /// - parameter onLoadingShellPresented: audiobook-only early hook — see
    ///   `BookOpenRouter.open`.
    @MainActor
    static func open(_ book: TPPBook, bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry, audiobookSession: AudiobookSessionManaging? = nil, onFinish: (() -> Void)? = nil, onLoadingShellPresented: (@MainActor () -> Void)? = nil) {
        BookOpenRouter.open(book,
                            bookRegistry: bookRegistry,
                            audiobookSession: audiobookSession,
                            onFinish: onFinish,
                            onLoadingShellPresented: onLoadingShellPresented)
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

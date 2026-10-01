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
/// Routing lives in `BookOpenRouter`. Audiobook opens land on
/// `AudiobookSessionManager.openAudiobook`, the sole owner of the audiobook
/// lifecycle — that ownership keeps a previous session's DRM decryptor from
/// outliving the next open and hanging Readium's `publicationOpener.open()`.
enum BookService {
    /// Book-open entry point for every caller. Forwards to `BookOpenRouter`,
    /// which owns the format -> destination decision, the reader wiring and the
    /// per-identifier reentrancy lock.
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
    /// retry path below. `failureMetadata` is added to the non-fatal's metadata.
    @MainActor
  static func showAudiobookTryAgainError(
    book: TPPBook? = nil,
    failureMetadata: [String: Any] = [:],
    onFinish: (() -> Void)? = nil
  ) {
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
            // PP-5242: the cause, loader step and content source from the
            // session manager (`openFailureMetadata`). The error above keeps its
            // fixed domain/code so the existing Crashlytics grouping holds.
            metadata: failureMetadata.merging(["user_message": Strings.Error.tryAgain]) { _, fixed in fixed }
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

        // Boxed rather than marking the parameter `@Sendable`, which would
        // ripple onto `BearerTokenManifestFetching` and its conformers.
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

/// Sendable carrier for `fetchManifestWithBearerToken`'s non-Sendable completion.
///
/// `@unchecked Sendable` invariant: `completion` is stored once and invoked
/// exactly once, on the URLSession delegate queue, for a single request.
private final class ManifestCompletionBox: @unchecked Sendable {
    let completion: ([String: Any]?) -> Void
    init(_ completion: @escaping ([String: Any]?) -> Void) { self.completion = completion }
}

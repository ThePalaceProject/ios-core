import Foundation
import PalaceBookModel
import PalaceBookRegistry

/// The book-open entry point `BookDetailViewModel` and `BookCellModel` still
/// name. It forwards to `BookOpenRouter` and is retired once they call the
/// router with their own registries (docs/architecture/god-class-decomposition-plan.md).
///
/// Routing lives in `BookOpenRouter`. Audiobook opens land on
/// `AudiobookSessionManager.openAudiobook`, the sole owner of the audiobook
/// lifecycle — that ownership keeps a previous session's DRM decryptor from
/// outliving the next open and hanging Readium's `publicationOpener.open()`.
enum BookService {
    /// Forwards to `BookOpenRouter`,
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
}

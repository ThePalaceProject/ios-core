import Foundation
import UIKit
// `@preconcurrency` on the Readium imports: `AssetRetriever` (ReadiumShared) and
// `PublicationOpener` (ReadiumStreamer) are non-`Sendable` classes whose async
// `retrieve(...)` / `open(...)` are `nonisolated`. `openPublication(...)` is
// `@MainActor`, so calling those methods on the stored `assetRetriever` /
// `publicationOpener` sends a non-Sendable value off the main actor —
// `complete`/archive mode reports "sending 'self.assetRetriever' /
// 'self.publicationOpener' risks causing data races". Both objects are created
// once in `init` and never mutated; `@preconcurrency import` is the honest
// ceiling for Readium types not yet Sendable-audited upstream — the same pattern
// the sibling Reader2 files use (AdobeDRMContentProtection, TPPReaderTOCBusinessLogic,
// TPPPublicationSpeechSynthesizer). No behavior change; when Readium annotates
// these `Sendable`, drop `@preconcurrency`.
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import PalaceBookModel

/// The LibraryService makes a book ready for presentation without dealing
/// with the specifics of how a book should be presented.
///
/// It sets up the various components necessary for presenting a book,
/// such as the DRM systems and publication opener.
final class LibraryService: Loggable {

    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener
    private var drmLibraryServices = [DRMLibraryService]()

    init() {
        let httpClient = DefaultHTTPClient()
        assetRetriever = AssetRetriever(httpClient: httpClient)

        // DRM configurations
        #if LCP
        drmLibraryServices.append(LCPLibraryService())
        #endif

        #if FEATURE_DRM_CONNECTOR
        drmLibraryServices.append(AdobeDRMLibraryService())
        #endif

        let contentProtections = drmLibraryServices.compactMap { $0.contentProtection }

        let parser = CompositePublicationParser([
            DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        ])

        publicationOpener = PublicationOpener(parser: parser, contentProtections: contentProtections)
    }

    @MainActor
    func openBook(_ book: TPPBook, sender: UIViewController, completion: @escaping (Result<Publication, LibraryServiceError>) -> Void) {

        guard let bookUrl = book.url else {
            completion(.failure(.invalidBook))
            return
        }

        openPublication(at: bookUrl, allowUserInteraction: true, sender: sender) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let publication):
                if !self.validatePublication(publication, for: book.identifier, completion: completion) {
                    return
                }
                completion(.success(publication))

            case .failure(let error):
                self.stopOpeningIndicator(identifier: book.identifier)
                completion(.failure(.openFailed(error)))
            }
        }
    }

    @MainActor
    func openSample(_ book: TPPBook,
                    sampleURL: URL,
                    sender: UIViewController,
                    completion: @escaping (Result<Publication, LibraryServiceError>) -> Void) {

        openPublication(at: sampleURL, allowUserInteraction: true, sender: sender) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let publication):
                if !self.validatePublication(publication, for: book.identifier, completion: completion) {
                    return
                }
                completion(.success(publication))

            case .failure(let error):
                self.stopOpeningIndicator(identifier: book.identifier)
                completion(.failure(.openFailed(error)))
            }
        }
    }

    @MainActor
    private func openPublication(at url: URL, allowUserInteraction: Bool, sender: UIViewController?, completion: @escaping (Result<Publication, Error>) -> Void) {
        Task {
            guard let fileURL = FileURL(url: url) else {
                log(.error, "Failed to convert URL to FileURL: \(url.absoluteString)")
                completion(.failure(LibraryServiceError.invalidBook))
                return
            }

            switch await assetRetriever.retrieve(url: fileURL) {
            case .success(let asset):
                let result = await self.publicationOpener.open(asset: asset, allowUserInteraction: allowUserInteraction, sender: sender)
                completion(result.mapError { $0 as Error })
            case .failure(let error):
                log(.error, "Asset retrieval failed: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    private func validatePublication(_ publication: Publication, for identifier: String, completion: (Result<Publication, LibraryServiceError>) -> Void) -> Bool {
        guard !publication.isRestricted else {
            stopOpeningIndicator(identifier: identifier)
            if let error = publication.protectionError {
                completion(.failure(.openFailed(error)))
            } else {
                completion(.failure(.invalidBook))
            }
            return false
        }
        return true
    }

    private func stopOpeningIndicator(identifier: String) {
        let userInfo: [String: Any] = [
            TPPNotificationKeys.bookProcessingBookIDKey: identifier,
            TPPNotificationKeys.bookProcessingValueKey: false
        ]
        NotificationCenter.default.post(name: NSNotification.TPPBookProcessingDidChange, object: nil, userInfo: userInfo)
    }
}


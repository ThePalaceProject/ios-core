import Foundation
import UIKit
import ReadiumShared
import ReadiumStreamer
import ReadiumAdapterGCDWebServer

/// The LibraryService makes a book ready for presentation without dealing
/// with the specifics of how a book should be presented.
///
/// It sets up the various components necessary for presenting a book,
/// such as the HTTP server, DRM systems, etc.
final class LibraryService: Loggable {

  private let assetRetriever: AssetRetriever
  private let publicationOpener: PublicationOpener
  private var drmLibraryServices = [DRMLibraryService]()

  let httpServer: GCDHTTPServer

  private lazy var documentDirectory = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

  init() {
    let httpClient = DefaultHTTPClient()
    assetRetriever = AssetRetriever(httpClient: httpClient)

    httpServer = GCDHTTPServer(assetRetriever: assetRetriever)

#if LCP
    drmLibraryServices.append(LCPLibraryService())
#endif

#if FEATURE_DRM_CONNECTOR
    drmLibraryServices.append(AdobeDRMLibraryService())
#endif

    let contentProtections = drmLibraryServices.compactMap { $0.contentProtection }

    publicationOpener = PublicationOpener(
      parser: DefaultPublicationParser(
        httpClient: httpClient,
        assetRetriever: assetRetriever,
        pdfFactory: DefaultPDFDocumentFactory()
      ),
      contentProtections: contentProtections
    )
  }

  // MARK: Opening a Book
  @MainActor
  func openBook(_ book: TPPBook,
                sender: UIViewController,
                completion: @escaping (Result<Publication, LibraryServiceError>) -> Void) {

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
        self.preparePresentation(of: publication, book: book)
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
        self.preparePresentation(of: publication, book: book)
        completion(.success(publication))

      case .failure(let error):
        self.stopOpeningIndicator(identifier: book.identifier)
        completion(.failure(.openFailed(error)))
      }
    }
  }

  // MARK: Open Publication

  /// Opens a publication using Readium's new AssetRetriever and PublicationOpener.
  @MainActor
  private func openPublication(at url: URL, allowUserInteraction: Bool, sender: UIViewController?, completion: @escaping (Result<Publication, Error>) -> Void) {
    Task {
      guard let fileURL = FileURL(url: url) else {
        completion(.failure(LibraryServiceError.invalidBook))
        return
      }

      switch await assetRetriever.retrieve(url: fileURL) {
      case .success(let asset):
        let result = await self.publicationOpener.open(asset: asset, allowUserInteraction: allowUserInteraction, sender: sender)

        completion(result.mapError { $0 as Error })

      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  // MARK: Presentation Preparation

  /// Prepares the publication for presentation, adding it to the GCDHTTPServer.
  private func preparePresentation(of publication: Publication, book: TPPBook) {
    // Check if the publication has a self link with an HTTP URL to identify if it's loaded remotely
    if let selfLink = publication.linkWithRel(.self), selfLink.href.isHTTPURL {
      return // Likely a web publication; no need to add to the server
    }

    let endpoint = "/publications/\(book.identifier)"

    do {
      try httpServer.serve(at: endpoint, publication: publication)
    } catch {
      log(.error, "Failed to serve publication at endpoint \(endpoint): \(error)")
    }
  }

  /// Stops activity indicator on the `Read` button.
  private func stopOpeningIndicator(identifier: String) {
    let userInfo: [String: Any] = [
      TPPNotificationKeys.bookProcessingBookIDKey: identifier,
      TPPNotificationKeys.bookProcessingValueKey: false
    ]
    NotificationCenter.default.post(name: NSNotification.TPPBookProcessingDidChange, object: nil, userInfo: userInfo)
  }

  /// Validates if the publication is restricted and handles errors if necessary.
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
}

extension String {
  var isHTTPURL: Bool {
    if let url = URL(string: self), url.scheme == "http" || url.scheme == "https" {
      return true
    }
    return false
  }
}

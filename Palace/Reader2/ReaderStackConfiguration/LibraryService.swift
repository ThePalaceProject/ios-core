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
    let lcpService = LCPLibraryService()
    drmLibraryServices.append(lcpService)
#endif

    // Set up content protections (DRM) for the PublicationOpener
    let contentProtections = drmLibraryServices.compactMap { $0.contentProtection }

    // Initialize PublicationOpener with content protection and HTTP client
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

  func openBook(_ book: TPPBook,
                sender: UIViewController,
                completion: @escaping (Result<Publication, LibraryServiceError>) -> Void) {

    guard let bookUrl = book.url else {
      completion(.failure(.invalidBook))
      return
    }

    openPublication(at: bookUrl, allowUserInteraction: true, sender: sender) { result in
      switch result {
      case .success(let publication):
        guard !publication.isRestricted else {
          self.stopOpeningIndicator(identifier: book.identifier)
          if let error = publication.protectionError {
            completion(.failure(LibraryServiceError.openFailed(error)))
          } else {
            completion(.failure(.invalidBook))
          }
          return
        }

        //        self.preparePresentation(of: publication, book: book)
        completion(.success(publication))

      case .failure(let error):
        self.stopOpeningIndicator(identifier: book.identifier)
        completion(.failure(.openFailed(error)))
      }
    }
  }

  func openSample(_ book: TPPBook,
                  sampleURL: URL,
                  sender: UIViewController,
                  completion: @escaping (Result<Publication, LibraryServiceError>) -> Void) {

    openPublication(at: sampleURL, allowUserInteraction: true, sender: sender) { result in
      switch result {
      case .success(let publication):
        guard !publication.isRestricted else {
          self.stopOpeningIndicator(identifier: book.identifier)
          if let error = publication.protectionError {
            completion(.failure(LibraryServiceError.openFailed(error)))
          } else {
            completion(.failure(.invalidBook))
          }
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
  private func openPublication(at url: URL, allowUserInteraction: Bool, sender: UIViewController?, completion: @escaping (Result<Publication, Error>) -> Void) {
    Task {
      // Convert the URL to a FileURL (Readium's type for file-based assets)
      guard let fileURL = FileURL(url: url) else {
        completion(.failure(LibraryServiceError.invalidBook))
        return
      }

      // Attempt to retrieve the asset from the URL
      let assetResult = await assetRetriever.retrieve(url: fileURL)

      switch assetResult {
      case .success(let asset):
        // Open the publication using the retrieved asset
        
        let result = await self.publicationOpener.open(asset: asset, allowUserInteraction: allowUserInteraction, sender: sender)
        switch result {
        case .success(let publication):
          completion(.success(publication))
        case .failure(let error):
          completion(.failure(error))

        }
      case .failure(let error):
        // Handle the asset retrieval error
        completion(.failure(error))
      }
    }
  }

  // MARK: Presentation Preparation

  //  /// Prepare the publication for presentation, adding it to the GCDHTTPServer.
  private func preparePresentation(of publication: Publication, book: TPPBook) {
    // Check if the publication has a self link with an HTTP URL to identify if it's loaded remotely
    if let selfLink = publication.linkWithRel(.self), selfLink.href.isHTTPURL {
      // This is likely a web publication, no need to add to the server
      return
    }

    let endpoint = "/publications/\(book.identifier)" 

    do {
      try httpServer.serve(at: endpoint, publication: publication)
    } catch {
      log(.error, error)
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
}

extension String {
  var isHTTPURL: Bool {
    if let url = URL(string: self), url.scheme == "http" || url.scheme == "https" {
      return true
    }
    return false
  }
}

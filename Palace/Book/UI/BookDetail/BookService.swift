import Foundation
import SwiftUI
import Combine
import PalaceAudiobookToolkit

enum BookService {
  static func open(_ book: TPPBook) {
    switch book.defaultBookContentType {
    case .epub:
      Task { @MainActor in
        ReaderService.shared.openEPUB(book)
      }
    case .pdf:
      presentPDF(book)
    case .audiobook:
      presentAudiobook(book)
    default:
      break
    }
  }

  private static func presentPDF(_ book: TPPBook) {
    guard let url = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else { return }
    let data = try? Data(contentsOf: url)
    let metadata = TPPPDFDocumentMetadata(with: book)
    let document = TPPPDFDocument(data: data ?? Data())
    if let coordinator = NavigationCoordinatorHub.shared.coordinator {
      coordinator.storePDF(document: document, metadata: metadata, forBookId: book.identifier)
      coordinator.push(.pdf(BookRoute(id: book.identifier)))
    }
  }

  private static func presentAudiobook(_ book: TPPBook) {
#if LCP
    if LCPAudiobooks.canOpenBook(book) {
      if let localURL = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier), FileManager.default.fileExists(atPath: localURL.path) {
        buildAndPresentAudiobook(book: book, lcpSourceURL: localURL)
        return
      }
      if let license = licenseURL(forBookIdentifier: book.identifier) {
        buildAndPresentAudiobook(book: book, lcpSourceURL: license)
        return
      }
    }
#endif
    // Non-LCP audiobook
    guard let url = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else { return }
    do {
      let data = try Data(contentsOf: url)
      guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return }
      presentAudiobookFrom(book: book, json: json, decryptor: nil)
    } catch { }
  }

#if LCP
  private static func buildAndPresentAudiobook(book: TPPBook, lcpSourceURL: URL) {
    guard let lcpAudiobooks = LCPAudiobooks(for: lcpSourceURL) else { return }
    if let cached = lcpAudiobooks.cachedContentDictionary() as? [String: Any] {
      presentAudiobookFrom(book: book, json: cached, decryptor: lcpAudiobooks)
      return
    }
    lcpAudiobooks.contentDictionary { dict, error in
      DispatchQueue.main.async {
        guard error == nil, let json = dict as? [String: Any] else { return }
        presentAudiobookFrom(book: book, json: json, decryptor: lcpAudiobooks)
      }
    }
  }
#endif

//  @MainActor
  private static func presentAudiobookFrom(
    book: TPPBook,
    json: [String: Any],
    decryptor: DRMDecryptor?
  ) {
    var jsonDict = json
    jsonDict["id"] = book.identifier

    let vendorCompletion: (Foundation.NSError?) -> Void = { (error: Foundation.NSError?) in
      Task { @MainActor in
        guard error == nil else { return }

        guard
          let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict, options: []),
          let manifest = try? Manifest.customDecoder().decode(Manifest.self, from: jsonData),
          let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: book.identifier,
            decryptor: decryptor,
            token: book.bearerToken
          )
        else { return }

        let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
        var timeTracker: AudiobookTimeTracker?
        if
          let libraryId = AccountsManager.shared.currentAccount?.uuid,
          let url = book.timeTrackingURL
        {
          timeTracker = AudiobookTimeTracker(libraryId: libraryId, bookId: book.identifier, timeTrackingUrl: url)
        }

        let networkService: AudiobookNetworkService = DefaultAudiobookNetworkService(
          tracks: audiobook.tableOfContents.allTracks,
          decryptor: decryptor
        )

        let manager = DefaultAudiobookManager(
          metadata: metadata,
          audiobook: audiobook,
          networkService: networkService,
          playbackTrackerDelegate: timeTracker
        )

        let bookmarkLogic = AudiobookBookmarkBusinessLogic(book: book)
        manager.bookmarkDelegate = bookmarkLogic

        let playbackModel = AudiobookPlaybackModel(audiobookManager: manager)
        if let cover = book.coverImage {
          playbackModel.updateCoverImage(cover)
        } else {
          Task {
            if let img = await TPPBookCoverRegistry.shared.coverImage(for: book) {
              await MainActor.run { playbackModel.updateCoverImage(img) }
            }
          }
        }

        if
          let dict = TPPBookRegistry.shared.location(forIdentifier: book.identifier)?.locationStringDictionary(),
          let localBookmark = AudioBookmark.create(locatorData: dict),
          let localPosition = TrackPosition(
            audioBookmark: localBookmark,
            toc: audiobook.tableOfContents.toc,
            tracks: audiobook.tableOfContents.tracks
          )
        {
          manager.audiobook.player.play(at: localPosition, completion: nil)
          // Ensure UI reflects restored location immediately
          playbackModel.jumpToInitialLocation(localPosition)
          // Suppress immediate save thrash while we reconcile with remote
          playbackModel.beginSaveSuppression(for: 3.0)
        } else {
          manager.audiobook.player.play()
        }

        if let coordinator = NavigationCoordinatorHub.shared.coordinator {
          let route = BookRoute(id: book.identifier)
          coordinator.storeAudioModel(playbackModel, forBookId: route.id)
          coordinator.push(.audio(route))

          TPPBookRegistry.shared.syncLocation(for: book) { (remoteBookmark: AudioBookmark?) in
            guard
              let remoteBookmark,
              let remotePosition = TrackPosition(
                audioBookmark: remoteBookmark,
                toc: audiobook.tableOfContents.toc,
                tracks: audiobook.tableOfContents.tracks
              )
            else { return }

            let localDict = TPPBookRegistry.shared.location(forIdentifier: book.identifier)?
              .locationStringDictionary()

            var shouldMove = true
            if
              let localDict,
              let local = AudioBookmark.create(locatorData: localDict),
              let localPos = TrackPosition(
                audioBookmark: local,
                toc: audiobook.tableOfContents.toc,
                tracks: audiobook.tableOfContents.tracks
              )
            {
              shouldMove = remotePosition.timestamp > localPos.timestamp
                && remotePosition.description != localPos.description
            }

            if shouldMove {
              manager.audiobook.player.play(at: remotePosition, completion: nil)
              // Extend suppression briefly after remote move
              playbackModel.beginSaveSuppression(for: 2.0)
            }
          }
        }
      }
    }

    AudioBookVendorsHelper.updateVendorKey(book: jsonDict, completion: vendorCompletion)
  }

  private static func licenseURL(forBookIdentifier identifier: String) -> URL? {
#if LCP
    guard let contentURL = MyBooksDownloadCenter.shared.fileUrl(for: identifier) else { return nil }
    let license = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
    return FileManager.default.fileExists(atPath: license.path) ? license : nil
#else
    return nil
#endif
  }
}



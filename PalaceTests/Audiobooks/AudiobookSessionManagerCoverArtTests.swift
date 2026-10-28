//  AudiobookSessionManagerCoverArtTests.swift
//
//  The player and lock-screen artwork come from `loadCoverArt`, so it uses the
//  registry's screen-width player decode. The generic cover decode is capped
//  by device tier (1024 px on the test host).

import XCTest
import UIKit
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookSessionManagerCoverArtTests: XCTestCase {

    private var sessionManager: AudiobookSessionManager!
    private var spyPresenter: SpyAudiobookSessionPresenter!
    private var appContainer: AppContainer!
    private let coverURL = URL(string: "https://covers.cover-art-test.example/full/book.jpg")!

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        let coverData = Self.jpeg(width: 2000, height: 3000)
        let coverURL = coverURL
        HTTPStubURLProtocol.register { request in
            guard request.url == coverURL else { return nil }
            return .init(statusCode: 200, headers: ["Content-Type": "image/jpeg"], body: coverData)
        }

        let registry = TPPBookCoverRegistry(imageCache: MockImageCache(), urlSession: .stubbedSession())
        spyPresenter = SpyAudiobookSessionPresenter()
        appContainer = makeTestAppContainer()
        sessionManager = AudiobookSessionManager(
            appContainer: appContainer,
            bookCoverRegistryProvider: { registry },
            navigationCoordinatorHubProvider: { NavigationCoordinatorHub(tabRouterHub: nil) },
            audiobookSessionPresenterProvider: { [unowned self] in self.spyPresenter },
            inAppPlaybackNavEnabledProvider: { true }
        )
    }

    override func tearDown() async throws {
        HTTPStubURLProtocol.reset()
        sessionManager = nil
        spyPresenter = nil
        appContainer = nil
        try await super.tearDown()
    }

    func testLoadCoverArt_usesScreenWidthPlayerDecode() throws {
        let expectedLongestSide = Int(min(UIScreen.main.bounds.width * UIScreen.main.scale, 1200))
        let book = makeBook()

        sessionManager.loadCoverArt(for: book, into: nil)

        let loaded = expectation(for: NSPredicate { [unowned self] _, _ in
            self.sessionManager.coverImage?.cgImage != nil
        }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 5)
        let artwork = try XCTUnwrap(sessionManager.coverImage?.cgImage)
        XCTAssertEqual(max(artwork.width, artwork.height), expectedLongestSide)
    }

    // MARK: - Helpers

    private func makeBook() -> TPPBook {
        TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: "cover-art-\(UUID().uuidString)",
            imageURL: coverURL,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    private static func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

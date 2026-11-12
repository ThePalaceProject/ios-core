//
//  BookFlowDependencySpies.swift
//  PalaceTests
//
//  Spies for the collaborators the book-open, book-detail and sign-in flows
//  are handed (`BookOpenDependencies`, `BookDetailDependencies`,
//  `SignInAppNetworking`), plus bundles built from them.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import PalaceAuth
@testable import Palace
import PalaceBookModel

@MainActor
final class BookReaderOpeningSpy: BookReaderOpening {
    private(set) var openedEPUBIdentifiers: [String] = []
    private(set) var openedPDFIdentifiers: [String] = []

    func openEPUB(_ book: TPPBook) {
        openedEPUBIdentifiers.append(book.identifier)
    }

    func openPDF(_ book: TPPBook, onFinish: (() -> Void)?) {
        openedPDFIdentifiers.append(book.identifier)
        onFinish?()
    }
}

@MainActor
final class BookCompletionSpy: BookCompletionNoting {
    private(set) var completedCount = 0

    func noteBookCompleted() {
        completedCount += 1
    }
}

@MainActor
final class SignInModalSheetPresenterSpy: ObservableObject, SignInModalSheetPresenting {
    @Published private(set) var presentationState: SignInPresentationState?
    private(set) var presentForCurrentAccountCount = 0
    private(set) var presentedLibraryAccountIDs: [String] = []

    func presentSignInModalForCurrentAccount(completion: (() -> Void)?) {
        presentForCurrentAccountCount += 1
    }

    func presentSignInModal(libraryAccountID: String, completion: (() -> Void)?) {
        presentedLibraryAccountIDs.append(libraryAccountID)
    }
}

/// Records every token exchange and cache clear. A token exchange fails with
/// `notConnectedToInternet` unless the test sets `tokenResult`.
final class SignInAppNetworkSpy: SignInAppNetworking, @unchecked Sendable {
    struct TokenRequest: Equatable {
        let username: String
        let password: String
        let tokenURL: URL
        let accountId: String?
    }

    private let lock = NSLock()
    private var _tokenRequests: [TokenRequest] = []
    private var _clearCacheCount = 0

    var tokenResult: Result<TokenResponse, Error> = .failure(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))

    var tokenRequests: [TokenRequest] { lock.withLock { _tokenRequests } }
    var clearCacheCount: Int { lock.withLock { _clearCacheCount } }

    func executeTokenRefresh(username: String,
                             password: String,
                             tokenURL: URL,
                             accountId: String?,
                             completion: @escaping (Result<TokenResponse, Error>) -> Void) {
        lock.withLock {
            _tokenRequests.append(TokenRequest(username: username, password: password,
                                               tokenURL: tokenURL, accountId: accountId))
        }
        completion(tokenResult)
    }

    func clearCache() {
        lock.withLock { _clearCacheCount += 1 }
    }
}

extension BookOpenDependencies {
    /// A bundle of spies; pass the ones a test asserts on.
    @MainActor
    static func testDouble(readers: BookReaderOpening = BookReaderOpeningSpy(),
                           audiobookSession: AudiobookSessionManaging = SpyShimSession(),
                           navigationHub: NavigationCoordinatorHub = NavigationCoordinatorHub(tabRouterHub: nil)) -> BookOpenDependencies {
        BookOpenDependencies(readers: readers,
                             audiobookSession: { audiobookSession },
                             navigationHub: navigationHub)
    }
}

extension BookDetailDependencies {
    @MainActor
    static func testDouble(bookOpen: BookOpenDependencies = .testDouble(),
                           signInPresenter: any SignInModalSheetPresenting = SignInModalSheetPresenterSpy(),
                           bookCompletion: BookCompletionNoting = BookCompletionSpy(),
                           signInNetwork: SignInAppNetworking = SignInAppNetworkSpy()) -> BookDetailDependencies {
        BookDetailDependencies(bookOpen: bookOpen,
                               signInPresenter: signInPresenter,
                               bookCompletion: bookCompletion,
                               signInNetwork: signInNetwork)
    }
}

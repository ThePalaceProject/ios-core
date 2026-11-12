//
//  BookOpenDependencies.swift
//  Palace
//
//  What `BookOpenRouter` and the screens that open books are handed instead
//  of reading the production container. Composed in `AppContainer.swift`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

/// The reader entry points the open router dispatches to.
@MainActor
protocol BookReaderOpening: AnyObject {
    func openEPUB(_ book: TPPBook)
    func openPDF(_ book: TPPBook, onFinish: (() -> Void)?)
}

extension ReaderService: BookReaderOpening {}

/// Records that the patron finished a book, which may schedule the rating prompt.
@MainActor
protocol BookCompletionNoting: AnyObject {
    func noteBookCompleted()
}

extension RatingPromptPresenter: BookCompletionNoting {}

/// The collaborators a book open needs: the readers, the audiobook session
/// and the navigation stacks the streaming reader is pushed onto.
@MainActor
struct BookOpenDependencies {
    let readers: BookReaderOpening
    /// Resolved on each audiobook open, not when the bundle is built: the
    /// production session is created lazily and builds a bundle of its own
    /// for its retry alert.
    let audiobookSession: @MainActor () -> AudiobookSessionManaging
    let navigationHub: NavigationCoordinatorHub
}

/// What the book detail screen hands its sign-in, open and end-of-book flows.
@MainActor
struct BookDetailDependencies {
    let bookOpen: BookOpenDependencies
    let signInPresenter: any SignInModalSheetPresenting
    let bookCompletion: BookCompletionNoting
    /// The app-wide executor the sign-in flow uses for the bearer-token
    /// exchange and the cache clear.
    let signInNetwork: SignInAppNetworking
}

//
//  TPPBookRegistry+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/17/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

/// Sendable carrier for `syncLocation`'s non-Sendable captures so the `@Sendable`
/// `Task` closure (Swift 6 `complete`) captures a Sendable box rather than the raw
/// `TPPBook` (a mutable `NSObject`, genuinely non-Sendable) and the raw completion
/// closure. The box is constructed synchronously in `syncLocation`, before the
/// `Task` is created, and only READ inside the Task (the book is forwarded to a
/// nonisolated async call; the completion is invoked once with the result). That
/// construct-then-read-once confinement is exactly what `@unchecked Sendable`
/// documents here — mirrors `ReadiumBookmarkBox` / `SyncCallbacks`.
private struct SyncLocationBox: @unchecked Sendable {
    let book: TPPBook
    let completion: (AudioBookmark?) -> Void
}

@objc extension TPPBookRegistry {
    func syncLocation(for book: TPPBook, completion: @escaping (AudioBookmark?) -> Void) {
        let box = SyncLocationBox(book: book, completion: completion)
        Task {
            let readPos = await TPPAnnotations.syncReadingPosition(ofBook: box.book, toURL: box.book.annotationsURL) as? AudioBookmark
            box.completion(readPos)
        }
    }
}

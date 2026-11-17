//
//  TPPBookRegistry+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/17/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit
import PalaceBookModel
import PalaceBookRegistry

/// Sendable carrier for `syncLocation`'s non-Sendable captures (`TPPBook` and the
/// completion). Built before the `Task` starts and only read inside it, which is
/// the confinement `@unchecked Sendable` relies on.
private struct SyncLocationBox: @unchecked Sendable {
    let book: TPPBook
    let completion: (AudioBookmark?) -> Void
}

extension TPPBookRegistry {
    func syncLocation(for book: TPPBook, completion: @escaping (AudioBookmark?) -> Void) {
        let box = SyncLocationBox(book: book, completion: completion)
        Task {
            let readPos = await TPPAnnotations.syncReadingPosition(ofBook: box.book, toURL: box.book.annotationsURL) as? AudioBookmark
            box.completion(readPos)
        }
    }
}

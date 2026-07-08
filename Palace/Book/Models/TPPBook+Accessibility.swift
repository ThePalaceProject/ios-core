//
//  TPPBook+Accessibility.swift
//  Palace
//
// Single source of truth for the VoiceOver label of a book cell.
//  Used by every list view (catalog lanes, My Books, Holds, etc.) so that
//  VoiceOver always announces a book the same way — title, author, and (for
//  audiobooks) narrator — and never leaks summaries, blurbs, or cover-art OCR.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

extension TPPBook {

  /// Audible/Libby-style VoiceOver label for a book cell. Format:
  ///
  ///   • Ebook with author:           "Title, by Author"
  ///   • Ebook without author:        "Title"
  ///   • Audiobook with narrator:     "Title, by Author, narrated by Narrator"
  ///   • Audiobook, no author:        "Title, narrated by Narrator"
  ///   • Audiobook, no narrator:      "Title, audiobook, by Author"
  ///   • Audiobook, neither:          "Title, audiobook"
  ///
  /// Cells should set this as the *single* `.accessibilityLabel` on the
  /// outermost element after `.accessibilityElement(children: .ignore)` so
  /// SwiftUI can't synthesize a label from the inner subviews and the
  /// underlying cover image cannot leak text via VoiceOver Image Recognition.
  @objc var voiceOverLabel: String {
    let cleanedAuthor = authors?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedNarrator = narrators?.trimmingCharacters(in: .whitespacesAndNewlines)
    if isAudiobook {
      if let author = cleanedAuthor, !author.isEmpty,
         let narrator = cleanedNarrator, !narrator.isEmpty {
        return Strings.Generic.audiobookByAuthorNarratedBy(
          title: title, author: author, narrator: narrator
        )
      } else if let author = cleanedAuthor, !author.isEmpty {
        return Strings.Generic.audiobookByAuthor(title: title, author: author)
      } else if let narrator = cleanedNarrator, !narrator.isEmpty {
        return Strings.Generic.audiobookNarratedBy(title: title, narrator: narrator)
      } else {
        return "\(title), \(Strings.Generic.audiobook)"
      }
    }

    if let author = cleanedAuthor, !author.isEmpty {
      return Strings.Generic.bookByAuthor(title: title, author: author)
    }
    return title
  }
}

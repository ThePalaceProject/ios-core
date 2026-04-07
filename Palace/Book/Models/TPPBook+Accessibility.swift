//
//  TPPBook+Accessibility.swift
//  Palace
//
//  PP-3968: Single source of truth for the VoiceOver label of a book cell.
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
    let hasAuthor = !(cleanedAuthor?.isEmpty ?? true)
    let hasNarrator = !(cleanedNarrator?.isEmpty ?? true)

    if isAudiobook {
      switch (hasAuthor, hasNarrator) {
      case (true, true):
        return Strings.Generic.audiobookByAuthorNarratedBy(
          title: title, author: cleanedAuthor!, narrator: cleanedNarrator!
        )
      case (true, false):
        return Strings.Generic.audiobookByAuthor(title: title, author: cleanedAuthor!)
      case (false, true):
        return Strings.Generic.audiobookNarratedBy(title: title, narrator: cleanedNarrator!)
      case (false, false):
        return "\(title), \(Strings.Generic.audiobook)"
      }
    }

    if hasAuthor {
      return Strings.Generic.bookByAuthor(title: title, author: cleanedAuthor!)
    }
    return title
  }
}

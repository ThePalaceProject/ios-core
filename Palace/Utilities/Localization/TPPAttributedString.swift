// Swift replacement for TPPAttributedString.m
//
// Creates styled NSAttributedStrings for author and title display.

import Foundation

/// Returns an attributed string styled for displaying author names.
@objc func TPPAttributedStringForAuthorsFromString(_ string: String?) -> NSAttributedString? {
  guard let string = string else { return nil }

  let paragraphStyle = NSMutableParagraphStyle()
  paragraphStyle.lineSpacing = 0.0
  paragraphStyle.minimumLineHeight = 0.0
  paragraphStyle.lineHeightMultiple = 0.9
  paragraphStyle.lineBreakMode = .byTruncatingTail
  paragraphStyle.hyphenationFactor = 0.85

  return NSAttributedString(
    string: string,
    attributes: [.paragraphStyle: paragraphStyle]
  )
}

/// Returns an attributed string styled for displaying titles,
/// with HTML entities decoded.
@objc func TPPAttributedStringForTitleFromString(_ string: String?) -> NSAttributedString? {
  guard let string = string else { return nil }

  // Decode twice to handle double-encoded entities like `&amp;#39;`
  let decodedString = string.stringByDecodingHTMLEntities.stringByDecodingHTMLEntities

  let paragraphStyle = NSMutableParagraphStyle()
  paragraphStyle.lineSpacing = 0.0
  paragraphStyle.minimumLineHeight = 0.0
  paragraphStyle.lineHeightMultiple = 0.85
  paragraphStyle.lineBreakMode = .byTruncatingTail
  paragraphStyle.hyphenationFactor = 0.75

  return NSAttributedString(
    string: decodedString,
    attributes: [.paragraphStyle: paragraphStyle]
  )
}

import UIKit

/// Creates an attributed string with author-style paragraph formatting.
func TPPAttributedStringForAuthorsFromString(_ string: String?) -> NSAttributedString? {
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

/// Creates an attributed string with title-style paragraph formatting.
/// Decodes HTML entities twice to handle double-encoded entities like `&amp;#39;`.
func TPPAttributedStringForTitleFromString(_ string: String?) -> NSAttributedString? {
  guard let string = string else { return nil }

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

import UIKit

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

func TPPAttributedStringForTitleFromString(_ string: String?) -> NSAttributedString? {
  guard let string = string else { return nil }

  // Decoding twice to mimic the behaviour of NSAttributedString that decodes entities like `&amp;#39;` correctly.
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

import SwiftUI
import UIKit

struct HTMLTextView: View {
  let htmlContent: String

  var body: some View {
    if let attributedString = htmlToAttributedString(htmlContent) {
      Text(attributedString)
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text(htmlContent)
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func htmlToAttributedString(_ html: String) -> AttributedString? {
    let cleanHTML = sanitizeHTML(html)

    guard let data = cleanHTML.data(using: .utf8) else { return nil }

    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html,
      .characterEncoding: String.Encoding.utf8.rawValue
    ]

    do {
      let nsAttributedString = try NSAttributedString(data: data, options: options, documentAttributes: nil)
      let mutableAttributedString = NSMutableAttributedString(attributedString: nsAttributedString)

      mutableAttributedString.addAttribute(
        .font,
        value: UIFont.palaceFont(ofSize: 15),
        range: NSRange(location: 0, length: mutableAttributedString.length)
      )

      mutableAttributedString.addAttribute(
        .foregroundColor,
        value: UIColor.label,
        range: NSRange(location: 0, length: mutableAttributedString.length)
      )

      return AttributedString(mutableAttributedString)
    } catch {
      return nil
    }
  }

  private func sanitizeHTML(_ html: String) -> String {
    var safeHTML = html

    let blacklist = [
      "<style[^>]*?>[\\s\\S]*?<\\/style>",
      "<script[^>]*?>[\\s\\S]*?<\\/script>"
    ]

    for pattern in blacklist {
      safeHTML = safeHTML.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    return safeHTML
  }
}

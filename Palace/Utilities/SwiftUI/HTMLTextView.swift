import SwiftUI
import UIKit

struct HTMLTextView: View {
  let htmlContent: String

  var body: some View {
    if let attributedString = htmlToAttributedString(htmlContent) {
      Text(attributedString)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text(htmlContent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func htmlToAttributedString(_ html: String) -> AttributedString? {
    guard let data = html.data(using: .utf8) else { return nil }

    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html,
      .characterEncoding: String.Encoding.utf8.rawValue
    ]

    if let nsAttributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
      let mutableAttributedString = NSMutableAttributedString(attributedString: nsAttributedString)
      mutableAttributedString.addAttribute(.font, value: UIFont.palaceFont(ofSize: 15), range: NSRange(location: 0, length: mutableAttributedString.length))
      return AttributedString(mutableAttributedString)
    }

    return nil
  }
}

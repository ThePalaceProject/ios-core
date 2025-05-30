import SwiftUI
import UIKit

struct HTMLTextView: View {
  let htmlContent: String

  var body: some View {
    Text(makeAttributedString(from: htmlContent))
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func makeAttributedString(from html: String) -> AttributedString {
    guard html.contains("<"), html.count < 10_000 else {
      return AttributedString(html)
    }

    guard let data = html.data(using: .utf8) else {
      return AttributedString(html)
    }

    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html,
      .characterEncoding: String.Encoding.utf8.rawValue
    ]

    do {
      let nsAttr = try NSAttributedString(data: data, options: options, documentAttributes: nil)
      let mutable = NSMutableAttributedString(attributedString: nsAttr)

      mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
         mutable.addAttribute(.font, value: UIFont.palaceFont(ofSize: 17), range: range)
      }

      mutable.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: mutable.length))

      return AttributedString(mutable)
    } catch {
      return AttributedString(html)
    }
  }
}

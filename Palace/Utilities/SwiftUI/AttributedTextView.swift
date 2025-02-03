import SwiftUI

struct AttributedTextView: UIViewRepresentable {
  let htmlContent: String

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.isEditable = false
    textView.isScrollEnabled = false   // <--- Disable scrolling
    textView.backgroundColor = .clear

    // Ensures text wraps properly inside the text container
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0

    // These priorities help the UITextView “shrink or grow” to fit content in SwiftUI
    textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textView.setContentHuggingPriority(.defaultLow, for: .vertical)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    return textView
  }

  func updateUIView(_ uiView: UITextView, context: Context) {
    let htmlTemplate = """
      <html>
        <head>
          <style>
            body { font-family: -apple-system, sans-serif; font-size: 14px; }
            p { margin: 0 0 10px; }
          </style>
        </head>
        <body>\(htmlContent.stringByDecodingHTMLEntities)</body>
      </html>
    """

    guard let data = htmlTemplate.data(using: .utf8) else {
      uiView.attributedText = nil
      return
    }

    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html,
      .characterEncoding: String.Encoding.utf8.rawValue
    ]

    if let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
      uiView.attributedText = attributedString
    } else {
      uiView.text = htmlContent
    }

    // Force the text view to recalculate its size
    uiView.sizeToFit()
  }
}

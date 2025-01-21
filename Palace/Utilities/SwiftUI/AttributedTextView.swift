import SwiftUI

struct AttributedTextView: UIViewRepresentable {
  let htmlContent: String

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.isEditable = false
    textView.isScrollEnabled = true
    textView.backgroundColor = .clear
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
  }
}

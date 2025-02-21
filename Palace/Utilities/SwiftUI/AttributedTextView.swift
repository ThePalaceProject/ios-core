import SwiftUI
import UIKit

struct AttributedTextView: UIViewRepresentable {
  @Binding var htmlContent: String

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.isEditable = false
    textView.isScrollEnabled = false
    textView.backgroundColor = .clear
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textView.setContentHuggingPriority(.defaultLow, for: .vertical)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    textView.isUserInteractionEnabled = true

    return textView
  }

  func updateUIView(_ uiView: UITextView, context: Context) {
    context.coordinator.updateTextView(uiView, with: htmlContent)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  class Coordinator: NSObject {
    var parent: AttributedTextView
    var lastHTMLContent: String = ""

    init(_ parent: AttributedTextView) {
      self.parent = parent
    }

    func updateTextView(_ textView: UITextView, with htmlContent: String) {
      guard htmlContent != lastHTMLContent else { return }

      let htmlTemplate = """
                <html>
                    <head>
                        <style>
                            body { font-family: -apple-system, sans-serif; font-size: 14px; }
                            p { margin: 0 0 10px; }
                        </style>
                    </head>
                    <body>\(htmlContent)</body>
                </html>
                """

      guard let data = htmlTemplate.stringByDecodingHTMLEntities.data(using: .utf8) else {
        textView.attributedText = nil
        return
      }

      let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue
      ]

      if let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
        textView.attributedText = attributedString
      } else {
        textView.text = htmlContent
      }

      textView.sizeToFit()

      lastHTMLContent = htmlContent
    }
  }
}

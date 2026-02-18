import SwiftUI
import UIKit

/// A view that renders HTML content as styled text.
/// Note: NSAttributedString HTML parsing uses WebKit internally and MUST run on the main thread.
struct HTMLTextView: View {
  let htmlContent: String
  
  @State private var attributedString = AttributedString("")
  @State private var isLoading = true
  
  var body: some View {
    Text(attributedString)
      .frame(maxWidth: .infinity, alignment: .leading)
      .opacity(isLoading ? 0.5 : 1.0)
      .onAppear {
        parseHTML()
      }
      .onChange(of: htmlContent) { _ in
        parseHTML()
      }
  }
  
  /// Parse HTML on the main thread to avoid WebKit threading crashes.
  /// NSAttributedString with .html documentType uses WebKit internally
  /// and will crash with EXC_BAD_ACCESS if called from a background thread.
  @MainActor
  private func parseHTML() {
    isLoading = true
    attributedString = Self.makeAttributedString(from: htmlContent)
    isLoading = false
  }
  
  /// Thread-safe HTML to AttributedString conversion.
  /// CRITICAL: This method must be called on the main thread when using .html document type.
  @MainActor
  static func makeAttributedString(from html: String) -> AttributedString {
    // Fast path: no HTML tags or content too long
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
      // NSAttributedString HTML parsing uses WebKit and must be on main thread
      let nsAttr = try NSAttributedString(data: data, options: options, documentAttributes: nil)
      let mutable = NSMutableAttributedString(attributedString: nsAttr)
      
      // Safely enumerate and update font attributes
      let fullRange = NSRange(location: 0, length: mutable.length)
      guard fullRange.length > 0 else {
        return AttributedString(html)
      }
      
      mutable.enumerateAttribute(.font, in: fullRange, options: .longestEffectiveRangeNotRequired) { _, range, _ in
        mutable.addAttribute(.font, value: UIFont.palaceFont(ofSize: 17), range: range)
      }
      
      mutable.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)
      
      return AttributedString(mutable)
    } catch {
      Log.warn(#file, "Failed to parse HTML: \(error.localizedDescription)")
      return AttributedString(html)
    }
  }
}

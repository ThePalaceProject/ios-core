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
    ///
    /// This method includes defensive measures against malformed HTML that could cause
    /// NSInternalInconsistencyException "unexpected start state" crashes in WebKit's HTML parser.
    @MainActor
    static func makeAttributedString(from html: String) -> AttributedString {
        // Fast path: empty string
        guard !html.isEmpty else {
            return AttributedString("")
        }

        // Fast path: no HTML tags or content too long
        guard html.contains("<"), html.count < 10_000 else {
            return AttributedString(html)
        }

        // Log the original HTML for crash diagnostics (truncated for performance)
        // This helps identify problematic content when crashes occur
        logHTMLForDiagnostics(html)

        // Sanitize input to prevent parser crashes
        let sanitizedHTML = sanitizeHTML(html)

        // Wrap in proper HTML structure to ensure valid start state
        let wrappedHTML = wrapInHTMLDocument(sanitizedHTML)

        guard let data = wrappedHTML.data(using: .utf8) else {
            Log.warn(#file, "Failed to encode HTML to UTF-8, falling back to plain text")
            return AttributedString(stripHTMLTags(from: html))
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
                return AttributedString(stripHTMLTags(from: html))
            }

            mutable.enumerateAttribute(.font, in: fullRange, options: .longestEffectiveRangeNotRequired) { _, range, _ in
                mutable.addAttribute(.font, value: UIFont.palaceFont(ofSize: 17), range: range)
            }

            mutable.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)

            return AttributedString(mutable)
        } catch {
            Log.warn(#file, "Failed to parse HTML: \(error.localizedDescription)")
            return AttributedString(stripHTMLTags(from: html))
        }
    }

    /// Logs HTML content for crash diagnostics.
    /// If the app crashes during HTML parsing, this log entry will appear in Crashlytics
    /// and help identify the problematic content.
    private static func logHTMLForDiagnostics(_ html: String) {
        // Only log in debug builds or if the content looks suspicious
        let suspicious = html.hasPrefix("<?") ||
            html.hasPrefix("<!") && !html.lowercased().hasPrefix("<!doctype") ||
            html.contains("\u{FEFF}") ||
            html.first?.isWhitespace == true

        if suspicious {
            // Log the first 500 chars of suspicious content for debugging
            let preview = String(html.prefix(500))
            let hexStart = html.prefix(20).unicodeScalars.map { String(format: "%02X", $0.value) }.joined(separator: " ")
            Log.info(#file, "Parsing potentially problematic HTML (len=\(html.count), hexStart=\(hexStart)): \(preview)")
        }
    }

    // MARK: - Testing Support

    /// Parses HTML WITHOUT any defensive sanitization or wrapping.
    /// This method is exposed for testing purposes only to verify that our defensive
    /// measures actually prevent crashes that would occur with raw parsing.
    ///
    /// - Warning: This method may crash with malformed input! Only use in tests
    ///   wrapped with ObjC exception handling.
    @MainActor
    static func makeAttributedStringUnsafe(from html: String) -> AttributedString {
        guard !html.isEmpty, html.contains("<"), html.count < 10_000 else {
            return AttributedString(html)
        }

        guard let data = html.data(using: .utf8) else {
            return AttributedString(html)
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        // No try/catch - let exceptions propagate for testing
        let nsAttr = try! NSAttributedString(data: data, options: options, documentAttributes: nil)
        return AttributedString(nsAttr)
    }

    // MARK: - Private Helpers

    /// Sanitizes HTML input by removing problematic characters that can cause parser crashes.
    ///
    /// The WebKit HTML parser can throw NSInternalInconsistencyException "unexpected start state"
    /// when encountering certain malformed input patterns including:
    /// - BOM (Byte Order Mark) characters
    /// - Null bytes and control characters
    /// - Invalid UTF-8 sequences
    private static func sanitizeHTML(_ html: String) -> String {
        var sanitized = html

        // Remove BOM (Byte Order Mark) if present at start
        if sanitized.hasPrefix("\u{FEFF}") {
            sanitized = String(sanitized.dropFirst())
        }

        // Remove null bytes and most control characters (keep tab, newline, carriage return)
        sanitized = sanitized.unicodeScalars.filter { scalar in
            // Allow printable characters, tab (0x09), newline (0x0A), carriage return (0x0D)
            scalar.value >= 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
        }.map { String($0) }.joined()

        // Trim leading whitespace that might confuse the parser
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized
    }

    /// Wraps HTML content in a proper document structure to ensure valid parser start state.
    ///
    /// This prevents "unexpected start state" errors by ensuring the parser always
    /// begins with a well-formed HTML document.
    private static func wrapInHTMLDocument(_ html: String) -> String {
        // If already has doctype or html tag, don't double-wrap
        let lowercased = html.lowercased()
        if lowercased.hasPrefix("<!doctype") || lowercased.hasPrefix("<html") {
            return html
        }

        // Wrap content in minimal HTML structure with UTF-8 encoding specified
        return """
      <!DOCTYPE html>
      <html>
      <head><meta charset="UTF-8"></head>
      <body>\(html)</body>
      </html>
      """
    }

    /// Strips HTML tags from a string as a fallback when parsing fails.
    ///
    /// This provides readable plain text when HTML parsing is not possible,
    /// rather than showing raw HTML tags to the user.
    private static func stripHTMLTags(from html: String) -> String {
        // Use regex to remove HTML tags
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) else {
            return html
        }

        let range = NSRange(html.startIndex..., in: html)
        var result = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")

        // Decode common HTML entities
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")

        // Collapse multiple whitespace into single space
        result = result.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

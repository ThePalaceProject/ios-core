//
//  TPPReaderBlockNavigation.swift
//  Palace
//
//  PP-4533 (DAISY reading-810): block-by-block VoiceOver navigation (paragraph,
//  heading, list item, quote …). Blocks live inline in the spine HTML, so they
//  are marked in the rendered DOM (see TPPEPUBViewController). This pure core
//  owns the block selector and builds the JavaScript that marks the outermost
//  matching elements as atomic stops and focus-walks them.
//

import Foundation

enum TPPReaderBlockNavigation {

  /// The CSS selector matching a logical block element. A block is a self-
  /// contained unit a non-visual reader should be able to step to atomically:
  /// paragraphs, headings, list items, quotes, definition terms/descriptions,
  /// preformatted text, figure captions, plus the ARIA equivalents.
  static let blockSelector =
    "p, h1, h2, h3, h4, h5, h6, li, blockquote, figcaption, dd, dt, pre, [role=\"heading\"], [role=\"listitem\"]"

  /// The lowercased tag names that constitute a logical block. Exposed (with
  /// `isBlockTag`) so the selector list is unit-testable without a DOM.
  static let blockTags: Set<String> = [
    "p", "h1", "h2", "h3", "h4", "h5", "h6",
    "li", "blockquote", "figcaption", "dd", "dt", "pre"
  ]

  /// Whether a bare HTML tag name is a logical block. Case-insensitive. Note:
  /// the ARIA `role`-based matches (`[role="heading"]` / `[role="listitem"]`)
  /// are selector-level, not tag-level, so they are not reflected here — this
  /// classifies the element tag only.
  static func isBlockTag(_ tag: String?) -> Bool {
    guard let tag else { return false }
    return blockTags.contains(tag.lowercased())
  }

  /// JavaScript that marks the logical block elements in the rendered Readium
  /// WKWebView so VoiceOver treats each as one atomic stop. It queries the block
  /// selector, skips NESTED blocks (only the OUTERMOST matching element is marked
  /// — an `<li>` containing a `<p>` is ONE stop, not two), and sets
  /// `tabindex="-1"` (so it is focusable for the rotor walk) and
  /// `data-pp-block="1"` on each. Idempotent: re-running only re-marks.
  ///
  /// Returns the count of marked blocks (for logging / verification).
  static func annotationJavaScript() -> String {
    let selector = jsString(blockSelector)
    return """
    (function() {
      var SELECTOR = \(selector);
      var nodes = document.querySelectorAll(SELECTOR);
      var n = 0;
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        // Only mark the OUTERMOST block: skip any element that has an ancestor
        // already matching the block selector (e.g. a <p> inside an <li>).
        if (el.parentElement && el.parentElement.closest(SELECTOR)) { continue; }
        el.setAttribute('tabindex', '-1');
        el.setAttribute('data-pp-block', '1');
        n++;
      }
      return n;
    })()
    """
  }

  /// JavaScript that moves focus to the next (`forward == true`) or previous
  /// (`forward == false`) marked block relative to the currently-focused element
  /// (`document.activeElement`) in document order, and calls `.focus()` on it.
  ///
  /// Returns the moved-to element's tag name (string) when it moved, or `null`
  /// when there is no further block in that direction. The non-null return is the
  /// signal the rotor uses to advance VoiceOver focus.
  static func nextBlockJavaScript(forward: Bool) -> String {
    let forwardLiteral = forward ? "true" : "false"
    return """
    (function() {
      var FORWARD = \(forwardLiteral);
      var blocks = Array.prototype.slice.call(document.querySelectorAll('[data-pp-block]'));
      if (blocks.length === 0) { return null; }
      var active = document.activeElement;
      // Find the index of the block at or containing the current focus.
      var current = -1;
      for (var i = 0; i < blocks.length; i++) {
        if (blocks[i] === active || blocks[i].contains(active)) { current = i; break; }
      }
      var target;
      if (current === -1) {
        // No marked block focused yet: start at the first (forward) or last (back).
        target = FORWARD ? blocks[0] : blocks[blocks.length - 1];
      } else {
        var next = FORWARD ? current + 1 : current - 1;
        if (next < 0 || next >= blocks.length) { return null; }
        target = blocks[next];
      }
      if (!target) { return null; }
      target.focus();
      return target.tagName;
    })()
    """
  }

  /// JSON-encode a Swift string into a JS string literal (safe interpolation).
  private static func jsString(_ s: String) -> String {
    let data = (try? JSONEncoder().encode(s)) ?? Data()
    return String(data: data, encoding: .utf8) ?? "\"\""
  }
}

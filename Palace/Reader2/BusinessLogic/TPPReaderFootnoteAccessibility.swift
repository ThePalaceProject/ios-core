//
//  TPPReaderFootnoteAccessibility.swift
//  Palace
//
//  PP-4531 — "Properly handle footnotes with VoiceOver in the iOS reader" (DAISY
//  reading-420). EPUBs mark a footnote reference with `epub:type="doc-noteref"`,
//  the note with `doc-footnote` (or `doc-endnote` / `doc-rearnote`), and the
//  return link with `doc-backlink`. These live INLINE in the spine HTML — not in
//  the Readium manifest — so they are surfaced to VoiceOver by annotating the
//  rendered DOM (see TPPEPUBViewController), not by parsing `publication`.
//
//  This type is the pure, dependency-free core: it classifies an element's
//  `epub:type` / ARIA `role` into a footnote Role and composes the VoiceOver
//  label for that role. It owns no UIKit/Readium state so it is unit-testable in
//  isolation; the WKWebView injection that applies these labels is a thin mirror
//  built by `annotationJavaScript()`.
//

import Foundation

enum TPPReaderFootnoteAccessibility {

  /// The footnote role a DOM element plays, derived from its `epub:type`
  /// (preferred) or ARIA `role`.
  enum Role: Equatable {
    /// An inline reference TO a note (`doc-noteref`). Activating it navigates to
    /// the note.
    case reference
    /// The note content itself (`doc-footnote` / `doc-endnote` / `doc-rearnote`).
    case note
    /// The return link back to the reference (`doc-backlink`).
    case backlink
  }

  /// Classify a footnote role from a (possibly space-separated, possibly
  /// `doc-`-prefixed) `epub:type` or ARIA `role` token list. Returns nil when no
  /// footnote-related token is present.
  ///
  /// EPUB `epub:type` and the matching DAISY ARIA `role` values share the same
  /// `doc-*` vocabulary, so one classifier serves both. Matching is
  /// case-insensitive and tolerant of the optional `doc-` prefix.
  static func role(forEPUBType epubType: String?) -> Role? {
    guard let epubType else { return nil }
    let tokens = epubType
      .lowercased()
      .split { $0 == " " || $0 == "\t" || $0 == "\n" }
      .map { $0.hasPrefix("doc-") ? String($0.dropFirst(4)) : String($0) }
    let set = Set(tokens)
    // Reference is checked first: a single element is never both a ref and a note.
    if set.contains("noteref") { return .reference }
    if set.contains("backlink") { return .backlink }
    if set.contains("footnote") || set.contains("endnote") || set.contains("rearnote") {
      return .note
    }
    return nil
  }

  /// The VoiceOver label for a footnote element.
  ///
  /// - `reference`: a marker (e.g. "3", "*", "a") yields `Footnote 3`; an empty
  ///   or whitespace-only marker yields the generic `Footnote reference`.
  ///   VoiceOver appends "link" itself because the element is an `<a>`.
  /// - `note`: `Footnote` (announced as focus reaches the note content).
  /// - `backlink`: `Back to reference`.
  static func accessibilityLabel(role: Role, marker: String?) -> String {
    switch role {
    case .reference:
      let trimmed = (marker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return Strings.TPPBaseReaderViewController.footnoteReferenceGeneric
      }
      return String(format: Strings.TPPBaseReaderViewController.footnoteReferenceNumbered, trimmed)
    case .note:
      return Strings.TPPBaseReaderViewController.footnoteContent
    case .backlink:
      return Strings.TPPBaseReaderViewController.footnoteBacklink
    }
  }

  /// JavaScript that annotates inline footnote elements in the rendered Readium
  /// WKWebView with `aria-label`s, so VoiceOver speaks the role + marker. It is a
  /// thin mirror of `accessibilityLabel(role:marker:)` — the Swift composer is
  /// the spec (and is unit-tested); this applies the same rule in the DOM, where
  /// the per-element marker text is known. Idempotent: re-running only re-labels.
  ///
  /// Returns the element count it labelled (for logging / verification).
  static func annotationJavaScript() -> String {
    // Localized label templates passed into the DOM so wording stays centralized.
    let numbered = jsString(Strings.TPPBaseReaderViewController.footnoteReferenceNumbered)
    let generic = jsString(Strings.TPPBaseReaderViewController.footnoteReferenceGeneric)
    let note = jsString(Strings.TPPBaseReaderViewController.footnoteContent)
    let backlink = jsString(Strings.TPPBaseReaderViewController.footnoteBacklink)
    return """
    (function() {
      var NUMBERED = \(numbered), GENERIC = \(generic), NOTE = \(note), BACKLINK = \(backlink);
      function roleOf(el) {
        var t = ((el.getAttribute('epub:type') || el.getAttribute('role') || '')).toLowerCase();
        if (!t) return null;
        var toks = t.split(/\\s+/).map(function(x){ return x.indexOf('doc-') === 0 ? x.slice(4) : x; });
        if (toks.indexOf('noteref') >= 0) return 'reference';
        if (toks.indexOf('backlink') >= 0) return 'backlink';
        if (toks.indexOf('footnote') >= 0 || toks.indexOf('endnote') >= 0 || toks.indexOf('rearnote') >= 0) return 'note';
        return null;
      }
      var nodes = document.querySelectorAll('[epub\\\\:type],[role]');
      var n = 0;
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i], r = roleOf(el);
        if (!r) continue;
        var label;
        if (r === 'reference') {
          var marker = (el.textContent || '').trim();
          label = marker ? NUMBERED.replace('%@', marker) : GENERIC;
        } else if (r === 'note') {
          label = NOTE;
        } else {
          label = BACKLINK;
        }
        el.setAttribute('aria-label', label);
        n++;
      }
      return n;
    })()
    """
  }

  /// JSON-encode a Swift string into a JS string literal (safe interpolation).
  private static func jsString(_ s: String) -> String {
    let data = (try? JSONEncoder().encode(s)) ?? Data()
    return String(data: data, encoding: .utf8) ?? "\"\""
  }
}

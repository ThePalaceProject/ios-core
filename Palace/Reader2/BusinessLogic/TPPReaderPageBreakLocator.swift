//
//  TPPReaderPageBreakLocator.swift
//  The Palace Project
//
//  Finds the print page the patron is currently on, for the DAISY nav-310
//  "Where am I?" announcement (PP-4527).
//
//  This replaces a page-list lookup that could never work. The previous approach
//  resolved every `publication.pageList` entry through
//  `publication.locate(link)` and compared `locations.totalProgression`. Readium's
//  `DefaultLocatorService.locate(_ link:)` builds that locator from an href and a
//  fragment and never sets `totalProgression` at all — for a fragmented
//  page-list href it sets neither `totalProgression` nor `progression`. Every
//  entry therefore resolved to nil and the comparison had nothing to match.
//  Measured on device 2026-09-18: `entries=182 resolved=0 nil=182`. The page
//  component had never once appeared since the feature shipped.
//
//  The page-break markers are present in the rendered chapter DOM — that is what
//  ReadiumCSS styles into the visible "Page ix" marker — so they are read from
//  there instead.
//

import Foundation

/// Builds and interprets the DOM query for the nearest preceding page-break.
enum TPPReaderPageBreakLocator {

    /// JavaScript returning the label of the nearest page-break at or before the
    /// current viewport, or `null` when none precedes it.
    ///
    /// - Parameter scrolled: true for scroll layout, false for paginated. The
    ///   axis matters: paginated layout lays content out in columns and
    ///   translates it horizontally, so preceding breaks sit at negative `x`,
    ///   while scrolled layout stacks vertically. Comparing on the wrong axis
    ///   returns the first break in the chapter forever.
    ///
    /// Deliberately walks elements and reads `epub:type` with `getAttribute`
    /// rather than selecting on it. Readium's spine documents are parsed as XML,
    /// where a namespaced CSS attribute selector such as `[epub\:type]` matches
    /// NOTHING. PP-4531 shipped that selector and silently annotated zero
    /// elements for four months; this must not repeat it.
    static func nearestPrecedingJavaScript(scrolled: Bool) -> String {
        let axis = scrolled ? "rect.top" : "rect.left"
        let limit = scrolled ? "window.innerHeight" : "window.innerWidth"
        return """
        (function() {
          var all = document.body ? document.body.getElementsByTagName('*') : [];
          var best = null, bestPos = -Infinity;
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            var type = (el.getAttribute('epub:type') || '') + ' ' + (el.getAttribute('role') || '');
            if (type.toLowerCase().indexOf('pagebreak') === -1) { continue; }
            var rect = el.getBoundingClientRect();
            var pos = \(axis);
            if (pos < \(limit) && pos > bestPos) { bestPos = pos; best = el; }
          }
          if (!best) { return null; }
          var label = best.getAttribute('title')
                   || best.getAttribute('aria-label')
                   || best.textContent
                   || '';
          return label;
        })();
        """
    }

    /// Normalises whatever `evaluateJavaScript` handed back into a page label.
    ///
    /// Returns nil for no-break-found, for a blank label, and for any non-string
    /// value (a JS `null` arrives as `NSNull`). Roman numerals are preserved as
    /// authored — front matter is numbered i, ii, iii and coercing those to
    /// integers would misreport the position.
    static func parse(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Some EPUBs author the marker text as "Page 42"; the announcement
        // composer adds its own "Page " prefix, so keeping it would speak
        // "Page Page 42".
        if let range = label.range(of: "^[Pp]age\\s+", options: .regularExpression) {
            label = String(label[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return label.isEmpty ? nil : label
    }
}

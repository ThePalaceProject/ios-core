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
//  SHAPE: the injected JavaScript only COLLECTS candidates; choosing between
//  them is pure Swift. An earlier draft did the choosing in JS, and mutation
//  testing scored it 0/12 — every operator in the JS string could be flipped
//  without failing a test, because a string-literal assertion cannot execute the
//  logic it quotes. Selection logic lives on this side of the boundary so it can
//  actually be tested.
//

import Foundation

/// Locates the nearest preceding print page-break in the rendered chapter.
enum TPPReaderPageBreakLocator {

    /// One page-break marker found in the rendered document, with its position
    /// in viewport coordinates.
    struct Candidate: Equatable {
        let label: String
        let left: Double
        let top: Double
    }

    /// JavaScript that collects every page-break marker in the rendered document
    /// as `{label, left, top}`, and makes no decisions.
    ///
    /// Deliberately walks elements and reads `epub:type` with `getAttribute`
    /// rather than selecting on it. Readium's spine documents are parsed as XML,
    /// where a namespaced CSS attribute selector such as `[epub\:type]` matches
    /// NOTHING. PP-4531 shipped that selector and silently annotated zero
    /// elements for four months; this must not repeat it.
    static func collectCandidatesJavaScript() -> String {
        """
        (function() {
          var all = document.body ? document.body.getElementsByTagName('*') : [];
          var out = [];
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            var type = (el.getAttribute('epub:type') && '') + ' ' + (el.getAttribute('role') || '');
            if (type.toLowerCase().indexOf('pagebreak') === -1) { continue; }
            var rect = el.getBoundingClientRect();
            var label = el.getAttribute('title') || el.getAttribute('aria-label') || el.textContent || '';
            out.push({ label: label, left: rect.left, top: rect.top });
          }
          return JSON.stringify(out);
        })();
        """
    }

    /// Decode what `evaluateJavaScript` handed back. Anything malformed yields no
    /// candidates rather than throwing — a book with no page-list is normal, and
    /// the AC requires the absence of a page number not to error.
    static func parseCandidates(_ value: Any?) -> [Candidate] {
        guard
            let json = value as? String,
            let data = json.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }

        return raw.compactMap { item in
            guard
                let label = normalize(item["label"]),
                let left = item["left"] as? Double,
                let top = item["top"] as? Double
            else {
                return nil
            }
            return Candidate(label: label, left: left, top: top)
        }
    }

    /// The label of the nearest page-break at or before the viewport, or nil when
    /// none precedes it.
    ///
    /// - Parameter scrolled: true for scroll layout, false for paginated. The
    ///   axis matters: paginated layout lays content out in columns and
    ///   translates it horizontally, so preceding breaks sit at negative `left`,
    ///   while scrolled layout stacks vertically. Comparing on the wrong axis
    ///   returns the first break in the chapter forever.
    /// - Parameter viewportExtent: `innerWidth` when paginated, `innerHeight`
    ///   when scrolled. A marker beyond it has not been reached yet.
    static func nearestPreceding(
        in candidates: [Candidate],
        scrolled: Bool,
        viewportExtent: Double
    ) -> String? {
        func position(_ candidate: Candidate) -> Double {
            scrolled ? candidate.top : candidate.left
        }

        // A marker exactly at the viewport edge has been reached; one beyond it
        // has not.
        let reached = candidates.filter { position($0) < viewportExtent }
        return reached.max { position($0) < position($1) }?.label
    }

    /// Normalise an authored label. Roman numerals are preserved as authored —
    /// front matter is numbered i, ii, iii, and coercing those to integers would
    /// misreport the position.
    static func normalize(_ value: Any?) -> String? {
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

//
//  TPPReaderPageBreakLocator.swift
//  The Palace Project
//
//  Finds the print page the patron is currently on, for the DAISY nav-310
//  "Where am I?" announcement (PP-4527).
//
//  Reads page-break markers from the rendered DOM, because Readium's
//  `locate(link)` sets no progression for fragmented page-list hrefs, so a
//  `publication.pageList` lookup cannot place them.
//
//  The injected JavaScript only collects candidates; choosing between them is
//  pure Swift so the selection logic is unit-testable.
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
    /// nothing (see PP-4531).
    static func collectCandidatesJavaScript() -> String {
        """
        (function() {
          var all = document.body ? document.body.getElementsByTagName('*') : [];
          var out = [];
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            var type = (el.getAttribute('epub:type') || '') + ' ' + (el.getAttribute('role') || '');
            if (type.toLowerCase().indexOf('pagebreak') === -1) { continue; }
            var rect = el.getBoundingClientRect();
            // Page-break markers are usually EMPTY elements with no title, no
            // aria-label and no text — measured on device: every label came back
            // "". The number then lives in the id (id="page63"). Without this
            // link in the chain every candidate is dropped as blank.
            var label = el.getAttribute('title')
                     || el.getAttribute('aria-label')
                     || el.textContent
                     || el.getAttribute('id')
                     || '';
            out.push({ label: label, left: rect.left, top: rect.top });
          }
          // The layout axis comes from the DOM, not from a preference. Measured
          // on device: with `scroll` reported false, the markers were spread over
          // 39,000pt of TOP and barely 60pt of LEFT — i.e. vertical. Comparing
          // the axis a preference claims rather than the one the document uses
          // picks a position at random.
          var horizontal = document.documentElement.scrollWidth > window.innerWidth + 1;
          return JSON.stringify({ horizontal: horizontal, marks: out });
        })();
        """
    }

    /// Decoded collector output: the markers plus the layout axis the document
    /// actually uses.
    struct Collection: Equatable {
        let horizontal: Bool
        let candidates: [Candidate]
    }

    static func parseCollection(_ value: Any?) -> Collection {
        guard
            let json = value as? String,
            let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Collection(horizontal: false, candidates: [])
        }
        return Collection(
            horizontal: root["horizontal"] as? Bool ?? false,
            candidates: parseCandidates(root["marks"])
        )
    }

    static func parseCandidates(_ value: Any?) -> [Candidate] {
        guard let raw = value as? [[String: Any]] else { return [] }

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

        // Strip an authored "Page 42" or id-derived "page42" / "page_42" /
        // "pg-42" prefix; the announcement adds its own "Page ".
        if let range = label.range(of: "^(?i)p(?:age|g)?[\\s_\\-]*(?=[0-9ivxlcdmIVXLCDM])",
                                   options: .regularExpression) {
            label = String(label[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return label.isEmpty ? nil : label
    }
}

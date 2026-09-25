---
name: pp4531-footnote-selector-namespace
created: 2026-09-16
author: Maurice Carrier
branch: fix/PP-4531-footnote-selector-namespace
priority: PP-4531 / Epic PP-833 EPUB Accessibility (DAISY reading-420)
---

# Intent: footnote VoiceOver labels never applied — namespaced-attribute selector

## Context

PP-4531 shipped in build 480 (PR #1106). QA (build 502, 2026-09-16) reports the
footnote reference still announces as "1, link" rather than "Footnote 1, link" —
i.e. the injected `aria-label`s are absent at runtime.

Measured root cause. `TPPReaderFootnoteAccessibility.annotationJavaScript()`
selects elements with:

    document.querySelectorAll('[epub\:type],[role]')

A CSS attribute selector with no namespace component matches ONLY attributes in
no namespace. Readium serves spine documents as `application/xhtml+xml`
(`MediaType.swift:271`), so WKWebView parses them as XML and
`xmlns:epub="http://www.idpf.org/2007/ops"` puts `epub:type` in the OPS
namespace. The selector therefore matches nothing and the loop labels zero
elements. `getAttribute('epub:type')` matches by QUALIFIED name and does work —
which is why the Swift classifier looks correct: the elements never reach it.

Measured against production bytes (`OPS/preface_001.xhtml` from
`readium-sdk/TestData/moby-dick-preview-collection.epub`, which contains
`<a epub:type="noteref" href="#n1">1</a>` and `<aside epub:type="footnote" id="n1">`),
running the production IIFE reconstructed from the Swift source:

  | parse mode                        | labelled | VoiceOver          |
  |-----------------------------------|----------|--------------------|
  | application/xhtml+xml (PRODUCTION)| 0        | "1, link"          |
  | text/html                         | 2        | "Footnote 1, link" |

Why no test caught it: the 16 existing tests exercise the Swift classifier and
label composer. The sole JS test substring-matches the JS source against itself
(`js.contains("noteref")`) and never executes it against a DOM, so it cannot
fail on this defect. The PP-4531 intent file recorded the runtime leg as
"Runtime (pending)" and the change shipped on that unit-only evidence.

## Claims

- `annotationJavaScript()` resolves `epub:type` namespace-agnostically:
  `getAttributeNS('http://www.idpf.org/2007/ops','type')` first, falling back to
  `getAttribute('epub:type')` for HTML-parsed resources. Element selection moves
  off the namespaced CSS selector to `document.querySelectorAll('*')`, which
  cannot silently match nothing.
- `epub:type` and `role` are CONCATENATED into one token list rather than
  `||`-short-circuited. The old expression never consulted `role` whenever
  `epub:type` was present-but-unrelated (e.g. `epub:type="chapter"
  role="doc-noteref"`).
- New `TPPReaderFootnoteAccessibilityDOMTests` EXECUTES the production JS in a
  real `WKWebView` against XHTML-parsed and HTML-parsed fixtures and asserts the
  resulting `aria-label`s — the leg that was pending.

## Anti-claims

- Does NOT add a return-to-reference affordance. No such logic exists anywhere
  (`grep backlink Palace/` outside the label composer returns only comments), so
  AC #4 still fails on EPUBs lacking `doc-backlink` — Moby Dick has none. Filed
  as a separate follow-up.
- Does NOT address QA's "the audio just stops / no audio resumes". That is not
  explained by this defect and is not diagnosed yet.
- Does NOT change `role(forEPUBType:)`'s signature or the label wording.

## Verification

- Unit: existing 16 classifier/composer tests unchanged.
- DOM: new WKWebView tests, asserted RED before the fix and green after.
- Full suite: `scripts/verify-pr.sh --quick` (full-scheme single pass).

## Files in scope

- `Palace/Reader2/BusinessLogic/TPPReaderFootnoteAccessibility.swift`
- `PalaceTests/Reader2/TPPReaderFootnoteAccessibilityDOMTests.swift` (new)
- `PalaceTests/Reader2/Fixtures/` (new XHTML fixture)
- `Palace.xcodeproj/project.pbxproj`

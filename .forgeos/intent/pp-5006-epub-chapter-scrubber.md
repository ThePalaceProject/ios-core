---
name: pp-5006-epub-chapter-scrubber
created: 2026-08-24
author: claude-opus-5
type: feature
tracking: PP-5006 — prototype a chapter scrubber in the iOS EPUB reader behind a Testing menu flag. Reporter David Wilcox; design support via Alissa Bankowski (BiblioBoard has an equivalent affordance; Libby comparable). Prototype only — shipping it is a separate decision.
related_prs: []
---

# Intent: PP-5006 — EPUB chapter scrubber (prototype)

Patrons navigating an EPUB can turn pages one at a time or open the table of
contents. There is no way to drag through a book. This adds a working scrubber
to the iOS EPUB reader behind a Testing-menu flag so the interaction can be
judged on a real book before anyone commits to shipping it.

## Claims

- Adds a continuous, chapter-labelled drag-to-navigate control to the EPUB
  reader, shown only when the "EPUB Chapter Scrubber" Testing-menu toggle is on.
- The control is CONTINUOUS over the book (its value is a Readium
  `totalProgression` in `0...1`) and LABELS the drag with the chapter it falls
  inside. That is what lets the readout carry page and percent as well as a
  chapter name, and what keeps it meaningful on a book with no usable table of
  contents — the chapter line drops out and the rest still works.
- The control performs NO navigation while the finger is down. It moves its own
  thumb and readout only, and asks the reader to navigate exactly once, on
  release (or on a VoiceOver adjustment, which has no drag).
- All position arithmetic lives in a pure, `Sendable` `ChapterScrubberModel`
  that normalizes (sorts, clamps, de-duplicates) at construction and answers a
  drag with two binary searches. Nothing on the drag path awaits anything.
- The expensive Readium work — `publication.positionsByReadingOrder()`, which
  walks every spine resource on first call — happens once when the reader opens,
  off the drag path.
- The control is a single `.adjustable` accessibility element whose VoiceOver
  increment/decrement move by CHAPTER and whose spoken value is composed by the
  reader's existing `TPPReaderPositionReport`.

## Anti-claims

- Does NOT ship the feature or remove the flag. With the flag off the control is
  never constructed, so the reader's view hierarchy and layout are unchanged.
- Does NOT touch the PDF reader (Reader3), the audiobook player, the table of
  contents / chapter select, or the reader's static progress indicators
  (PP-5005's scope).
- Does NOT change page-turn, bookmark, TTS, search, or last-read-position
  behavior.
- Adds NO new patron-facing copy beyond one VoiceOver label ("Reading position").
  The readout is assembled from strings the reader already ships.
- Adds no remote feature flag — the toggle is a local Testing-menu override only.
- Does not add a post-jump "return to where you were" affordance. Cancelling a
  drag restores the position (free, since nothing navigated); a deliberate jump
  is not undoable. Confirmed as the intended scope for the prototype.

## Files in scope

- Palace/Reader2/BusinessLogic/ChapterScrubberModel.swift (new)
- Palace/Reader2/BusinessLogic/ChapterScrubberModel+Publication.swift (new)
- Palace/Reader2/BusinessLogic/ChapterScrubberReadout.swift (new)
- Palace/Reader2/UI/ChapterScrubberView.swift (new)
- Palace/Reader2/UI/TPPBaseReaderViewController.swift
- Palace/Reader2/UI/TPPEPUBViewController.swift
- Palace/FeatureFlags/RemoteFeatureFlags.swift
- Palace/Packages/PalaceFeatureFlags/Sources/PalaceFeatureFlags/FeatureFlagProviding.swift
- Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift
- Palace/Settings/DeveloperSettings/DeveloperSettingsView.swift
- Palace/Utilities/Localization/Strings.swift
- PalaceTests/Mocks/MockFeatureFlagProvider.swift
- PalaceTests/Reader2/ChapterScrubberModelTests.swift (new)
- PalaceTests/Reader2/ChapterScrubberReadoutTests.swift (new)
- PalaceTests/Reader2/ChapterScrubberViewTests.swift (new)

## Verification

- Unit: model (page/chapter resolution, boundary cells, NaN and out-of-range
  input, normalization, chapter stepping), readout composition, control state
  machine (drag does not commit; release commits once; cancel restores and
  commits nothing; a location update mid-drag is ignored), chrome visibility.
- Mutation: `ChapterScrubberModel.swift` 14 killed / 0 survived / 1 errored (the
  errored mutant makes the binary search non-terminating, which no assertion can
  kill). `ChapterScrubberReadout.swift` has no mutation surface after an
  unreachable guard was removed.
- Long books: property tests over a 5,000-position / 400-chapter model — a full
  track sweep must stay monotonic in page and percent, and the exact page and
  chapter at a known fraction must be right. Measured drag-update cost 37 µs,
  ~0.2% of a 60fps frame.
- Device: driven on the simulator against the A1QA test library with a real
  borrowed EPUB. Confirmed the control renders with chapter ticks, the readout
  previews chapter + page + percent mid-drag while the reader's own position
  label stays put, and release lands where the drag indicated.

## Known limits (carried to the ticket as prototype findings)

- Several table-of-contents entries pointing at FRAGMENTS of one spine resource
  all resolve to that resource's start and collapse to a single tick, because
  `publication.locate(_ link:)` yields no `totalProgression` and the fraction has
  to be read out of the positions list by reading-order index. Books that put
  many chapters in one XHTML file get a coarser track than their table of
  contents suggests.

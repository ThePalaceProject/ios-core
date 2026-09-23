# Intent: UI polish P2 delight + P3 empty/loading/error states (PP-4747)

## Claims
- Adds numeric-text roll to the four `StatsCardView` value labels via
  `.contentTransition(.numericText())` + `accessibleAnimation(PalaceMotion.emphasized, value:)`.
- Animates `ReadingChartView` marks on data/period change via
  `accessibleAnimation(PalaceMotion.standard, value: dataPoints)`.
- Replaces the fragile `asyncAfter` badge-unlock reset in `BadgesView` with a
  `PhaseAnimator` idle->pop->settle sequence (reduce-motion gated) via a new
  pure `BadgeUnlockPhase` enum.
- Adds `.symbolEffect(.bounce, value: currentStreakDays)` to the streak flame in `StatsView`.
- Swaps the app-rating card's linear `easeInOut` for `PalaceMotion.emphasized`,
  adds a soft shadow, and gates the card's scale transition on Reduce Motion
  (new pure `usesScaleTransition`/`cardTransition`/`stepAnimation` seams).
- Adds PDF micro-interactions: bookmark symbol bounce/replace + success haptic
  (`TPPPDFNavigation`), numeric page-number transition (`TPPPDFView`), and
  view-aligned scroll snapping + selection haptic (`PDFThumbnailStrip`).
- Replaces bare/blank empty + error states with iOS-17 `ContentUnavailableView`
  in `HoldsView`, `MyBooksView` (adds a "Browse the catalog" button wired to the
  catalog tab), `TPPPDFSearchView`, `CatalogContentView`, `CatalogLaneMoreView`.
- Adds opacity cross-fades between skeleton and content in `CatalogView`,
  `CatalogLaneRowView`, `MyBooksView`.
- Tidies Holds: sync-error banner gets a move+opacity transition; drops the
  competing black `ProgressView` overlay in favor of the existing skeleton.
- Adds `Strings.MyBooksView.browseCatalog`/`.emptyViewTitle`,
  `Strings.HoldsView.emptyTitle`, `Strings.Catalog.emptyFeedTitle`/`.emptyFeedMessage`.

## Anti-claims
- No redesigns; presentation/animation-only. No business-logic, data-flow, or
  navigation-graph changes (the one new nav action is the MyBooks empty-state
  "Browse the catalog" tab jump, an additive convenience via the existing
  `tabRouterHub`).
- Does NOT touch any sibling-owned file: `TPPBaseReaderViewController.swift`,
  `TPPReaderSettingsView.swift`, `TypographySettingsView.swift`,
  `AccountDetailView.swift`, `ActionButtonView.swift`, `NormalBookCell.swift`,
  `AppTabHostView.swift`, `AudiobookMiniPlayerView.swift`,
  `AudiobookFullPlayerCoverContainer.swift`, `TPPSettingsView.swift`.
- Does NOT recreate PR2 primitives; routes all animation through
  `PalaceMotion`/`accessibleAnimation` and haptics through `.palaceHaptic`.
- Does not regress the SentimentGateView dark-mode contrast fix (button colors untouched).

## Files in scope
- Palace/Stats/Views/{StatsCardView,ReadingChartView,BadgesView,StatsView}.swift
- Palace/AppRating/SentimentGateView.swift
- Palace/PDF/Views/{TPPPDFNavigation,TPPPDFView,PDFThumbnailStrip,TPPPDFSearchView}.swift
- Palace/Holds/HoldsView.swift
- Palace/MyBooks/MyBooks/MyBooksView.swift
- Palace/CatalogUI/Views/{CatalogContentView,CatalogView,CatalogLaneRowView,CatalogLaneMoreView}.swift
- Palace/Utilities/Localization/Strings.swift
- PalaceTests/UIPolish/{RatingCardMotionGateTests,BadgeUnlockPhaseTests,PDFSearchEmptyStateTests}.swift (new)

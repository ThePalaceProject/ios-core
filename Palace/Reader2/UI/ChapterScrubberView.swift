//
//  ChapterScrubberView.swift
//  The Palace Project
//
//  PP-5006: the drag-to-navigate control for the EPUB reader, behind the
//  "EPUB Chapter Scrubber" Testing-menu flag.
//
//  Shape: a rail at rest, a card in hand.
//
//  At rest the control is a hairline progress rail and a small thumb — no text,
//  no tick marks, nothing that competes with the page. The reader's existing
//  position label sits just below it and says where you are. While a finger is
//  down, a card rises above the rail carrying the chapter and the page/percent
//  of the place the drag would land; the card may cover page text freely,
//  because the patron is not reading at that moment.
//
//  The rail carries NO text deliberately. What the reader states at rest — and
//  how each figure is labelled — is PP-5005's open design question, owned by a
//  designer. Keeping the persistent object wordless means this prototype can
//  ship without pre-empting that decision.
//
//  There are no chapter tick marks. An earlier draft drew one per chapter; on a
//  338-page novel with ~35 chapters that is a mark every ten points, which
//  reads as a ruler rather than as structure, and chapters sharing one spine
//  file collapse into an illegible smudge. Chapter structure is delivered
//  instead where it can be read: the card names the chapter, a haptic marks
//  crossing into a new one, and VoiceOver steps chapter by chapter.
//
//  The control owns NO navigation. While the finger is down it moves only its
//  own thumb and card; it asks its owner to navigate exactly once, on release
//  (`onCommit`). That split is what makes "cancelling a drag returns the patron
//  to their original position" free rather than an undo feature: nothing has
//  moved yet, so a cancelled drag only has to put the thumb back.
//
//  All position arithmetic lives in `ChapterScrubberModel`, which is pure and
//  synchronous. Nothing here awaits anything, so a drag cannot be stalled by a
//  Readium position lookup regardless of how long the book is.
//

import UIKit

/// A continuous drag-to-navigate progress rail with a drag-time position card.
final class ChapterScrubberView: UIControl {

    typealias Target = ChapterScrubberModel.Target

    // MARK: - Callbacks

    /// Fires once, when a scrub completes: on release, or on a VoiceOver
    /// adjustment. The owner navigates here, and only here.
    var onCommit: ((Target) -> Void)?

    /// Fires when a drag crosses into a different chapter — the one moment in a
    /// scrub worth marking. The owner decides what that means (the reader plays
    /// a preference-gated haptic); the control does not reach for a singleton
    /// to do it itself.
    var onChapterCrossed: (() -> Void)?

    /// Fires when a drag starts and ends. The reader uses it to hide its own
    /// position label for the duration: the card states where the drag would
    /// land while the label states where the patron still is, and showing both
    /// at once reads as a contradiction.
    var onScrubbingChanged: ((Bool) -> Void)?

    // MARK: - State

    /// The book's shape: where the chapters start and where the pages fall.
    var model: ChapterScrubberModel = .empty {
        didSet {
            guard model != oldValue else { return }
            setNeedsLayout()
            updateAccessibilityValue()
        }
    }

    /// Where the patron actually is. Ignored while a drag is in flight so the
    /// reader's own location updates cannot yank the thumb out from under the
    /// finger.
    private(set) var progression: Double = 0 {
        didSet { setNeedsLayout() }
    }

    private(set) var isScrubbing = false

    /// The progression to restore to if the drag is cancelled.
    private var progressionBeforeScrub: Double = 0

    /// The chapter under the thumb at the previous drag update, used to fire
    /// haptics only when the drag crosses into a different chapter.
    private var previewedChapter: String?
    private var hasPreviewedChapter = false

    // MARK: - Metrics

    private enum Metrics {
        static let trackHeight: CGFloat = 2
        static let trackHeightScrubbing: CGFloat = 3
        static let thumbDiameter: CGFloat = 11
        static let thumbDiameterScrubbing: CGFloat = 19
        /// Deliberately shorter than the touch target: the rail should occupy
        /// as little of the reading surface as it can while still being easy to
        /// grab. `point(inside:)` makes up the difference.
        static let intrinsicHeight: CGFloat = 24
        static let minimumTouchTarget: CGFloat = 44

        static let cardCornerRadius: CGFloat = 12
        static let cardBorderWidth: CGFloat = 1
        static let cardPaddingHorizontal: CGFloat = 14
        static let cardPaddingVertical: CGFloat = 10
        static let cardRowSpacing: CGFloat = 2
        /// Gap between the top of the rail and the bottom of the card.
        static let cardGap: CGFloat = 8
    }

    // MARK: - Subviews

    private let trackView = UIView()
    private let fillView = UIView()
    private let thumbView = UIView()

    private let cardView = UIView()
    private let chapterLabel = UILabel()
    private let detailLabel = UILabel()

    /// Palace chrome is monochrome: every colour below is an alpha of the
    /// reading theme's text colour, blended against its background. No hue is
    /// introduced — Libby's blue progress fill becomes a heavier grey here.
    private var themeTextColor: UIColor = .label {
        didSet { applyChromeColors() }
    }

    private var themeBackgroundColor: UIColor = .systemBackground {
        didSet { applyChromeColors() }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        clipsToBounds = false
        backgroundColor = .clear

        trackView.isUserInteractionEnabled = false
        addSubview(trackView)

        fillView.isUserInteractionEnabled = false
        addSubview(fillView)

        thumbView.isUserInteractionEnabled = false
        thumbView.layer.shadowColor = UIColor.black.cgColor
        thumbView.layer.shadowOpacity = 0.25
        thumbView.layer.shadowRadius = 2
        thumbView.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(thumbView)

        cardView.layer.cornerRadius = Metrics.cardCornerRadius
        cardView.layer.borderWidth = Metrics.cardBorderWidth
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.18
        cardView.layer.shadowRadius = 10
        cardView.layer.shadowOffset = CGSize(width: 0, height: 3)
        cardView.alpha = 0
        cardView.isUserInteractionEnabled = false
        // The card is the visual echo of the value VoiceOver already speaks.
        cardView.isAccessibilityElement = false
        addSubview(cardView)

        chapterLabel.font = .preferredFont(forTextStyle: .footnote)
        chapterLabel.adjustsFontForContentSizeCategory = true
        chapterLabel.numberOfLines = 2
        // The chapter title is the book's own words and the only token here
        // that may be arbitrarily long, so it is the only one allowed to
        // truncate. The figures below it never do.
        chapterLabel.lineBreakMode = .byTruncatingTail
        cardView.addSubview(chapterLabel)

        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 0
        cardView.addSubview(detailLabel)

        applyChromeColors()

        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        accessibilityLabel = Strings.TPPBaseReaderViewController.readingPosition
        updateAccessibilityValue()
    }

    // MARK: - Theming

    /// Match the reader's current theme. Called from the EPUB controller's
    /// `setUIColor(for:)` so the rail and card change with light / sepia /
    /// solarized / dark / night.
    func apply(textColor: UIColor, backgroundColor: UIColor) {
        themeTextColor = textColor
        themeBackgroundColor = backgroundColor
    }

    private func applyChromeColors() {
        let text = themeTextColor

        trackView.backgroundColor = text.withAlphaComponent(0.15)
        // 0.70 matches the alpha the reader's own overlay labels use, so the
        // rail reads as the same family of chrome rather than a louder one.
        fillView.backgroundColor = text.withAlphaComponent(0.70)
        thumbView.backgroundColor = text.withAlphaComponent(0.90)

        // Opaque, not translucent: the card sits over body text and has to be
        // readable, so it is the theme's background nudged toward its text
        // colour rather than a see-through panel.
        cardView.backgroundColor = Self.blend(themeBackgroundColor, toward: text, amount: 0.08)
        // On the night theme the background is near-black and the drop shadow
        // is invisible; the border is what carries the card's elevation there.
        cardView.layer.borderColor = text.withAlphaComponent(0.20).cgColor

        chapterLabel.textColor = text
        detailLabel.textColor = text.withAlphaComponent(0.75)
    }

    /// Mixes `amount` of `target` into `base`, staying fully opaque.
    static func blend(_ base: UIColor, toward target: UIColor, amount: CGFloat) -> UIColor {
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        guard base.getRed(&br, green: &bg, blue: &bb, alpha: &ba),
              target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta) else {
            return base
        }
        let t = min(max(amount, 0), 1)
        return UIColor(
            red: br + (tr - br) * t,
            green: bg + (tg - bg) * t,
            blue: bb + (tb - bb) * t,
            alpha: 1
        )
    }

    // MARK: - External position updates

    /// Move the thumb to the patron's real position. Ignored mid-drag.
    func setProgression(_ value: Double, animated: Bool) {
        guard !isScrubbing else { return }
        let clamped = min(max(value.isNaN ? 0 : value, 0), 1)
        guard abs(clamped - progression) > .ulpOfOne else { return }
        progression = clamped
        updateAccessibilityValue()
        if animated {
            UIView.animate(withDuration: 0.2) { self.layoutIfNeeded() }
        }
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.intrinsicHeight)
    }

    /// Grow the hit area vertically to a comfortable touch target without
    /// making the control take that much room on the reading surface.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let slop = max(0, (Metrics.minimumTouchTarget - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -slop).contains(point)
    }

    /// Points of slack at each end of the track, so the thumb at 0% or 100% is
    /// fully inside the control. Sized to the LARGER (scrubbing) thumb so the
    /// rail's geometry does not shift when the thumb grows.
    private var trackInset: CGFloat { Metrics.thumbDiameterScrubbing / 2 }

    private var trackWidth: CGFloat { max(0, bounds.width - trackInset * 2) }

    override func layoutSubviews() {
        super.layoutSubviews()

        let inset = trackInset
        let width = trackWidth
        let centerY = bounds.midY
        let trackHeight = isScrubbing ? Metrics.trackHeightScrubbing : Metrics.trackHeight

        trackView.frame = CGRect(
            x: inset,
            y: centerY - trackHeight / 2,
            width: width,
            height: trackHeight
        )
        trackView.layer.cornerRadius = trackHeight / 2

        let thumbOffset = Self.thumbOffset(
            forFraction: progression,
            trackWidth: width,
            isRightToLeft: isRightToLeftLayout
        )

        // The fill runs from the reading-start edge to the thumb, so in an RTL
        // layout it grows from the right.
        fillView.frame = CGRect(
            x: isRightToLeftLayout ? inset + thumbOffset : inset,
            y: trackView.frame.minY,
            width: isRightToLeftLayout ? width - thumbOffset : thumbOffset,
            height: trackHeight
        )
        fillView.layer.cornerRadius = trackHeight / 2

        let diameter = isScrubbing ? Metrics.thumbDiameterScrubbing : Metrics.thumbDiameter
        thumbView.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        thumbView.layer.cornerRadius = diameter / 2
        thumbView.center = CGPoint(x: inset + thumbOffset, y: centerY)

        layoutCard(above: trackView.frame.minY)
    }

    /// The card is CENTRED on the control, not pinned to the thumb. A card that
    /// chases the finger makes the patron's eyes chase it too, and at the ends
    /// of the track it would have to be clamped anyway; a fixed position lets
    /// the eyes park in one place and read.
    private func layoutCard(above railTop: CGFloat) {
        guard cardView.alpha > 0 || isScrubbing else { return }

        let maxWidth = bounds.width
        let textWidth = maxWidth - Metrics.cardPaddingHorizontal * 2
        guard textWidth > 0 else { return }

        let hasChapter = !(chapterLabel.text ?? "").isEmpty
        let chapterSize = hasChapter
            ? chapterLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            : .zero
        let detailSize = detailLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))

        let rowsHeight = (hasChapter ? chapterSize.height + Metrics.cardRowSpacing : 0) + detailSize.height
        let cardHeight = rowsHeight + Metrics.cardPaddingVertical * 2
        let contentWidth = max(hasChapter ? chapterSize.width : 0, detailSize.width)
        let cardWidth = min(maxWidth, contentWidth + Metrics.cardPaddingHorizontal * 2)

        cardView.frame = CGRect(
            x: (maxWidth - cardWidth) / 2,
            y: railTop - Metrics.cardGap - cardHeight,
            width: cardWidth,
            height: cardHeight
        )

        // At accessibility text sizes the rows go leading-aligned so long
        // figures read as text rather than as a squeezed centred block; at
        // ordinary sizes the card is compact and centred.
        let isAccessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let alignment: NSTextAlignment = isAccessibilitySize ? .natural : .center
        chapterLabel.textAlignment = alignment
        detailLabel.textAlignment = alignment

        var y = Metrics.cardPaddingVertical
        if hasChapter {
            chapterLabel.frame = CGRect(
                x: Metrics.cardPaddingHorizontal,
                y: y,
                width: cardWidth - Metrics.cardPaddingHorizontal * 2,
                height: chapterSize.height
            )
            y += chapterSize.height + Metrics.cardRowSpacing
        } else {
            chapterLabel.frame = .zero
        }
        detailLabel.frame = CGRect(
            x: Metrics.cardPaddingHorizontal,
            y: y,
            width: cardWidth - Metrics.cardPaddingHorizontal * 2,
            height: detailSize.height
        )
    }

    private var isRightToLeftLayout: Bool {
        effectiveUserInterfaceLayoutDirection == .rightToLeft
    }

    // MARK: - Pure geometry

    /// Where along the track a given book fraction sits, in points from the
    /// track's leading edge in VIEW coordinates (mirrored for RTL layouts).
    static func thumbOffset(forFraction fraction: Double, trackWidth: CGFloat, isRightToLeft: Bool) -> CGFloat {
        guard trackWidth > 0 else { return 0 }
        let clamped = min(max(fraction.isNaN ? 0 : fraction, 0), 1)
        let visual = isRightToLeft ? 1 - clamped : clamped
        return trackWidth * CGFloat(visual)
    }

    /// The book fraction a touch at `x` (in view coordinates) corresponds to.
    /// A zero-width track has no meaningful answer and yields the start of the
    /// book rather than a division by zero.
    static func fraction(forTouchX x: CGFloat, trackOrigin: CGFloat, trackWidth: CGFloat, isRightToLeft: Bool) -> Double {
        guard trackWidth > 0 else { return 0 }
        let raw = Double((x - trackOrigin) / trackWidth)
        let clamped = min(max(raw.isNaN ? 0 : raw, 0), 1)
        return isRightToLeft ? 1 - clamped : clamped
    }

    // MARK: - Touch tracking
    //
    // The `UIControl` overrides do nothing but unwrap the touch. The scrub
    // itself is driven by the four `…Scrub` methods below, which take plain
    // coordinates — so the state machine (does a cancel restore the position?
    // does a release commit exactly once?) is exercisable without fabricating
    // a `UITouch`.

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        beginScrub(atX: touch.location(in: self).x)
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateScrub(toX: touch.location(in: self).x)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        endScrub(atX: touch?.location(in: self).x)
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelScrub()
    }

    /// Start a scrub. Returns false — declining the touch — when the book has
    /// nowhere to scrub to.
    @discardableResult
    func beginScrub(atX x: CGFloat) -> Bool {
        guard model.isUsable else { return false }

        isScrubbing = true
        progressionBeforeScrub = progression
        hasPreviewedChapter = false
        updateScrub(toX: x)
        setCardVisible(true)
        onScrubbingChanged?(true)
        return true
    }

    /// Move the thumb and the card. Deliberately does NOT navigate.
    func updateScrub(toX x: CGFloat) {
        guard isScrubbing else { return }

        progression = Self.fraction(
            forTouchX: x,
            trackOrigin: trackInset,
            trackWidth: trackWidth,
            isRightToLeft: isRightToLeftLayout
        )

        let target = model.target(atFraction: progression)
        chapterLabel.text = ChapterScrubberReadout.chapterLine(for: target)
        detailLabel.text = ChapterScrubberReadout.detailLine(for: target)
        accessibilityValue = ChapterScrubberReadout.accessibilityValue(for: target)

        if hasPreviewedChapter, previewedChapter != target.chapterTitle {
            onChapterCrossed?()
        }
        previewedChapter = target.chapterTitle
        hasPreviewedChapter = true

        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Finish a scrub and ask the owner to navigate — the only place a drag
    /// commits.
    func endScrub(atX x: CGFloat?) {
        guard isScrubbing else { return }
        if let x {
            updateScrub(toX: x)
        }
        let target = model.target(atFraction: progression)
        finishScrub()
        onCommit?(target)
    }

    /// Abandon a scrub. Nothing was navigated, so restoring the patron's
    /// position is only a matter of putting the thumb back.
    func cancelScrub() {
        guard isScrubbing else { return }
        progression = progressionBeforeScrub
        finishScrub()
    }

    private func finishScrub() {
        isScrubbing = false
        hasPreviewedChapter = false
        previewedChapter = nil
        setCardVisible(false)
        updateAccessibilityValue()
        onScrubbingChanged?(false)

        setNeedsLayout()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        // The thumb and rail shrink back rather than snapping.
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            self.layoutIfNeeded()
        }
    }

    private func setCardVisible(_ visible: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            // Reduce Motion gets the fade without the scale.
            cardView.transform = .identity
            UIView.animate(withDuration: 0.15) { self.cardView.alpha = visible ? 1 : 0 }
            return
        }
        if visible {
            cardView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        }
        UIView.animate(withDuration: 0.15) {
            self.cardView.alpha = visible ? 1 : 0
            self.cardView.transform = visible ? .identity : CGAffineTransform(scaleX: 0.96, y: 0.96)
        }
    }

    // MARK: - Accessibility

    /// VoiceOver has no drag, so an adjustment is a complete scrub: it moves
    /// the thumb by a chapter AND navigates. The new value is assigned before
    /// returning so VoiceOver speaks where the patron just landed.
    override func accessibilityIncrement() {
        adjust(forward: true)
    }

    override func accessibilityDecrement() {
        adjust(forward: false)
    }

    private func adjust(forward: Bool) {
        guard model.isUsable else { return }
        progression = model.step(from: progression, forward: forward)
        let target = model.target(atFraction: progression)
        accessibilityValue = ChapterScrubberReadout.accessibilityValue(for: target)
        setNeedsLayout()
        onCommit?(target)
    }

    private func updateAccessibilityValue() {
        accessibilityValue = ChapterScrubberReadout.accessibilityValue(
            for: model.target(atFraction: progression)
        )
    }
}

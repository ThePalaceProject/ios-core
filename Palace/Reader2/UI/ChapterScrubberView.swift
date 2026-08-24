//
//  ChapterScrubberView.swift
//  The Palace Project
//
//  PP-5006: the drag-to-navigate control for the EPUB reader, behind the
//  "EPUB Chapter Scrubber" Testing-menu flag.
//
//  The control owns NO navigation. While the finger is down it only moves its
//  own thumb and readout; it asks its owner to navigate exactly once, on
//  release (`onCommit`). That split is what makes "cancelling a drag returns the
//  patron to their original position" free rather than an undo feature: nothing
//  has moved yet, so a cancelled drag only has to put the thumb back.
//
//  All position arithmetic lives in `ChapterScrubberModel`, which is pure and
//  synchronous. Nothing here awaits anything, so a drag cannot be stalled by a
//  Readium position lookup regardless of how long the book is.
//

import UIKit

/// A continuous drag-to-navigate track with chapter tick marks.
final class ChapterScrubberView: UIControl {

    typealias Target = ChapterScrubberModel.Target

    // MARK: - Callbacks

    /// Fires once, when a scrub completes: on release, or on a VoiceOver
    /// adjustment. The owner navigates here, and only here.
    var onCommit: ((Target) -> Void)?

    // MARK: - State

    /// The book's shape. Setting it redraws the ticks and re-enables the control.
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
        static let trackHeight: CGFloat = 3
        static let thumbDiameter: CGFloat = 13
        static let thumbDiameterScrubbing: CGFloat = 19
        static let tickHeight: CGFloat = 7
        static let tickWidth: CGFloat = 1
        static let intrinsicHeight: CGFloat = 34
        /// Minimum comfortable touch target; the control is shorter than this
        /// visually, so `point(inside:)` grows the hit area to meet it.
        static let minimumTouchTarget: CGFloat = 44
        static let readoutGap: CGFloat = 8
    }

    // MARK: - Subviews

    private let trackView = UIView()
    private let thumbView = UIView()
    private let tickContainer = UIView()
    private let readoutLabel = PaddedLabel()

    /// Palace chrome is monochrome; the reader tints it to the reading theme's
    /// text color via `apply(textColor:)` rather than picking its own hue.
    private var tintColorForChrome: UIColor = .label {
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

        trackView.layer.cornerRadius = Metrics.trackHeight / 2
        trackView.isUserInteractionEnabled = false
        addSubview(trackView)

        tickContainer.isUserInteractionEnabled = false
        addSubview(tickContainer)

        thumbView.layer.cornerRadius = Metrics.thumbDiameter / 2
        thumbView.isUserInteractionEnabled = false
        thumbView.layer.shadowColor = UIColor.black.cgColor
        thumbView.layer.shadowOpacity = 0.25
        thumbView.layer.shadowRadius = 2
        thumbView.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(thumbView)

        readoutLabel.font = .preferredFont(forTextStyle: .caption1)
        readoutLabel.adjustsFontForContentSizeCategory = true
        readoutLabel.textAlignment = .center
        readoutLabel.numberOfLines = 2
        readoutLabel.layer.cornerRadius = 6
        readoutLabel.layer.masksToBounds = true
        readoutLabel.alpha = 0
        readoutLabel.isUserInteractionEnabled = false
        // The bubble is the visual echo of the value VoiceOver already speaks.
        readoutLabel.isAccessibilityElement = false
        addSubview(readoutLabel)

        applyChromeColors()

        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        accessibilityLabel = Strings.TPPBaseReaderViewController.readingPosition
        updateAccessibilityValue()
    }

    // MARK: - Theming

    /// Match the reader's current theme. Called from the EPUB controller's
    /// `setUIColor(for:)` so the scrubber changes with sepia / dark / light.
    func apply(textColor: UIColor) {
        tintColorForChrome = textColor
    }

    private func applyChromeColors() {
        trackView.backgroundColor = tintColorForChrome.withAlphaComponent(0.25)
        thumbView.backgroundColor = tintColorForChrome.withAlphaComponent(0.9)
        readoutLabel.textColor = tintColorForChrome
        readoutLabel.backgroundColor = tintColorForChrome.withAlphaComponent(0.12)
        tickContainer.subviews.forEach {
            $0.backgroundColor = tintColorForChrome.withAlphaComponent(0.45)
        }
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
    /// making the control take that much room in the reader's letterbox.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let slop = max(0, (Metrics.minimumTouchTarget - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -slop).contains(point)
    }

    /// Points of slack at each end of the track, so the thumb at 0% or 100%
    /// is fully inside the control.
    private var trackInset: CGFloat { Metrics.thumbDiameterScrubbing / 2 }

    private var trackWidth: CGFloat { max(0, bounds.width - trackInset * 2) }

    override func layoutSubviews() {
        super.layoutSubviews()

        let inset = trackInset
        let trackWidth = self.trackWidth
        let centerY = bounds.midY

        trackView.frame = CGRect(
            x: inset,
            y: centerY - Metrics.trackHeight / 2,
            width: trackWidth,
            height: Metrics.trackHeight
        )
        tickContainer.frame = trackView.frame

        layoutTicks(in: trackWidth)

        let diameter = isScrubbing ? Metrics.thumbDiameterScrubbing : Metrics.thumbDiameter
        thumbView.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        thumbView.layer.cornerRadius = diameter / 2
        thumbView.center = CGPoint(
            x: inset + Self.thumbOffset(
                forFraction: progression,
                trackWidth: trackWidth,
                isRightToLeft: isRightToLeftLayout
            ),
            y: centerY
        )

        layoutReadout()
    }

    private func layoutTicks(in trackWidth: CGFloat) {
        let marks = model.chapterMarks
        // Reuse tick views across layouts; books do not change chapter count
        // mid-read, so this settles after the first pass.
        while tickContainer.subviews.count > marks.count {
            tickContainer.subviews.last?.removeFromSuperview()
        }
        while tickContainer.subviews.count < marks.count {
            let tick = UIView()
            tick.isUserInteractionEnabled = false
            tick.backgroundColor = tintColorForChrome.withAlphaComponent(0.45)
            tickContainer.addSubview(tick)
        }

        for (tick, mark) in zip(tickContainer.subviews, marks) {
            let x = Self.thumbOffset(
                forFraction: mark,
                trackWidth: trackWidth,
                isRightToLeft: isRightToLeftLayout
            )
            tick.frame = CGRect(
                x: x - Metrics.tickWidth / 2,
                y: tickContainer.bounds.midY - Metrics.tickHeight / 2,
                width: Metrics.tickWidth,
                height: Metrics.tickHeight
            )
        }
    }

    private func layoutReadout() {
        guard readoutLabel.alpha > 0 || isScrubbing else { return }

        let maxWidth = max(0, bounds.width)
        let size = readoutLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let width = min(size.width, maxWidth)
        // Follow the thumb, but stay inside the control's width.
        let x = min(max(thumbView.center.x - width / 2, 0), max(0, bounds.width - width))
        readoutLabel.frame = CGRect(
            x: x,
            y: -(size.height + Metrics.readoutGap),
            width: width,
            height: size.height
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
        setReadoutVisible(true)
        updateScrub(toX: x)
        return true
    }

    /// Move the thumb and the readout. Deliberately does NOT navigate.
    func updateScrub(toX x: CGFloat) {
        guard isScrubbing else { return }

        progression = Self.fraction(
            forTouchX: x,
            trackOrigin: trackInset,
            trackWidth: trackWidth,
            isRightToLeft: isRightToLeftLayout
        )

        let target = model.target(atFraction: progression)
        readoutLabel.text = ChapterScrubberReadout.displayText(for: target)
        accessibilityValue = ChapterScrubberReadout.accessibilityValue(for: target)

        // Crossing into a different chapter is the one moment worth marking.
        // Routed through `AccessibilityService` — preference- and reduce-motion-
        // gated — rather than a raw feedback generator, matching the reader's
        // existing bookmark-confirmation haptic.
        if hasPreviewedChapter, previewedChapter != target.chapterTitle {
            Task { await AccessibilityService.shared.triggerHaptic(.selection) }
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
        setReadoutVisible(false)
        setNeedsLayout()
        updateAccessibilityValue()
    }

    private func setReadoutVisible(_ visible: Bool) {
        let apply = { self.readoutLabel.alpha = visible ? 1 : 0 }
        if UIAccessibility.isReduceMotionEnabled {
            apply()
        } else {
            UIView.animate(withDuration: 0.15, animations: apply)
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

// MARK: - Padded label

/// A label with interior padding, so the readout bubble's background is not
/// flush against its text.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        padded(super.intrinsicContentSize)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let available = CGSize(
            width: max(0, size.width - insets.left - insets.right),
            height: size.height
        )
        return padded(super.sizeThatFits(available))
    }

    private func padded(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }
}

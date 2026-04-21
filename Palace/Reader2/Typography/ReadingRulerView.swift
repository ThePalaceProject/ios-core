//
//  ReadingRulerView.swift
//  Palace
//
//  Typography system — translucent overlay highlighting the current reading line.
//

import SwiftUI
import UIKit

/// A translucent overlay that highlights a horizontal band (the "ruler"),
/// dimming content above and below to help the reader focus on the current line.
///
/// Implemented as a UIKit `CALayer`-based overlay for performance, wrapped
/// in `UIViewRepresentable` for SwiftUI integration.
struct ReadingRulerView: UIViewRepresentable {

    /// Whether the ruler is currently visible.
    var isEnabled: Bool

    /// Number of text lines the ruler should highlight (1-3).
    var lineCount: Int

    /// Approximate line height in points (derived from font size * line spacing).
    var lineHeight: CGFloat

    /// Vertical position of the ruler center, as a fraction of the view height (0-1).
    /// The reader updates this as the user reads.
    var positionFraction: CGFloat

    /// Background dim color.
    var dimColor: UIColor

    /// Ruler highlight tint (transparent center).
    var rulerTintColor: UIColor

    func makeUIView(context: Context) -> ReadingRulerOverlayView {
        let view = ReadingRulerOverlayView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: ReadingRulerOverlayView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            lineCount: lineCount,
            lineHeight: lineHeight,
            positionFraction: positionFraction,
            dimColor: dimColor,
            rulerTintColor: rulerTintColor
        )
    }
}

/// The UIKit overlay that renders the reading ruler using CALayers for smooth performance.
final class ReadingRulerOverlayView: UIView {

    private let topDimLayer = CALayer()
    private let bottomDimLayer = CALayer()
    private let rulerBorderTop = CALayer()
    private let rulerBorderBottom = CALayer()

    private var currentEnabled = false
    private var currentPositionFraction: CGFloat = 0.4

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        layer.addSublayer(topDimLayer)
        layer.addSublayer(bottomDimLayer)
        layer.addSublayer(rulerBorderTop)
        layer.addSublayer(rulerBorderBottom)

        topDimLayer.opacity = 0
        bottomDimLayer.opacity = 0
        rulerBorderTop.opacity = 0
        rulerBorderBottom.opacity = 0
    }

    func update(
        isEnabled: Bool,
        lineCount: Int,
        lineHeight: CGFloat,
        positionFraction: CGFloat,
        dimColor: UIColor,
        rulerTintColor: UIColor
    ) {
        currentEnabled = isEnabled
        currentPositionFraction = positionFraction

        let targetOpacity: Float = isEnabled ? 1.0 : 0.0

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        topDimLayer.opacity = targetOpacity
        bottomDimLayer.opacity = targetOpacity
        rulerBorderTop.opacity = targetOpacity
        rulerBorderBottom.opacity = targetOpacity

        CATransaction.commit()

        topDimLayer.backgroundColor = dimColor.cgColor
        bottomDimLayer.backgroundColor = dimColor.cgColor
        rulerBorderTop.backgroundColor = rulerTintColor.withAlphaComponent(0.3).cgColor
        rulerBorderBottom.backgroundColor = rulerTintColor.withAlphaComponent(0.3).cgColor

        setNeedsLayout()
    }

    override func layoutSublayers(of layer: CALayer) {
        super.layoutSublayers(of: layer)
        guard currentEnabled else { return }

        let viewHeight = bounds.height
        let viewWidth = bounds.width

        // Default line height if not provided
        let effectiveLineHeight = max(20, 0) // will be overridden below
        _ = effectiveLineHeight

        // The ruler position and height
        let rulerCenterY = viewHeight * currentPositionFraction
        let rulerHeight: CGFloat = 60 // placeholder, overridden by parent
        let rulerTop = rulerCenterY - rulerHeight / 2
        let rulerBottom = rulerCenterY + rulerHeight / 2

        let borderHeight: CGFloat = 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        topDimLayer.frame = CGRect(x: 0, y: 0, width: viewWidth, height: max(0, rulerTop))
        bottomDimLayer.frame = CGRect(x: 0, y: rulerBottom, width: viewWidth, height: max(0, viewHeight - rulerBottom))
        rulerBorderTop.frame = CGRect(x: 0, y: max(0, rulerTop), width: viewWidth, height: borderHeight)
        rulerBorderBottom.frame = CGRect(x: 0, y: rulerBottom - borderHeight, width: viewWidth, height: borderHeight)

        CATransaction.commit()
    }

    /// Recalculates layout with explicit ruler dimensions.
    func layoutRuler(lineCount: Int, lineHeight: CGFloat) {
        guard currentEnabled else { return }

        let viewHeight = bounds.height
        let viewWidth = bounds.width
        let clampedLineCount = max(1, min(3, lineCount))
        let rulerHeight = lineHeight * CGFloat(clampedLineCount)
        let rulerCenterY = viewHeight * currentPositionFraction
        let rulerTop = max(0, rulerCenterY - rulerHeight / 2)
        let rulerBottom = min(viewHeight, rulerCenterY + rulerHeight / 2)
        let borderHeight: CGFloat = 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        topDimLayer.frame = CGRect(x: 0, y: 0, width: viewWidth, height: rulerTop)
        bottomDimLayer.frame = CGRect(x: 0, y: rulerBottom, width: viewWidth, height: max(0, viewHeight - rulerBottom))
        rulerBorderTop.frame = CGRect(x: 0, y: rulerTop, width: viewWidth, height: borderHeight)
        rulerBorderBottom.frame = CGRect(x: 0, y: rulerBottom - borderHeight, width: viewWidth, height: borderHeight)

        CATransaction.commit()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Pass through all touches — the ruler is purely visual.
        return nil
    }
}

// MARK: - Convenience Initializer

extension ReadingRulerView {
    /// Creates a reading ruler with default configuration.
    /// - Parameters:
    ///   - isEnabled: Whether the ruler is visible.
    ///   - settings: Typography settings to derive line height from.
    ///   - position: Vertical position fraction (0-1).
    init(isEnabled: Bool, settings: TypographySettings, position: CGFloat = 0.4) {
        self.isEnabled = isEnabled
        self.lineCount = 2
        self.lineHeight = settings.fontSize * settings.lineSpacing
        self.positionFraction = position
        self.dimColor = settings.theme.backgroundColor.withAlphaComponent(0.6)
        self.rulerTintColor = settings.theme.textColor
    }
}

#if DEBUG
struct ReadingRulerView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            // Simulated reading content
            VStack(spacing: 8) {
                ForEach(0..<20, id: \.self) { _ in
                    Text("Lorem ipsum dolor sit amet, consectetur adipiscing elit.")
                        .font(.body)
                }
            }
            .padding()

            ReadingRulerView(
                isEnabled: true,
                lineCount: 2,
                lineHeight: 24,
                positionFraction: 0.4,
                dimColor: UIColor.black.withAlphaComponent(0.5),
                rulerTintColor: .white
            )
        }
    }
}
#endif

//
//  AccessibilityTraversalAuditTests.swift
//  PalaceTests
//
//  Proves the runtime audit can fail. Each defect shape it exists to catch is
//  built as a small synthetic screen and the audit must report it; each clean
//  counterpart must pass and fire its action. Without these, a green
//  `CriticalScreensVoiceOverAuditTests` run would not show the audit had
//  looked at anything.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import UIKit
@testable import Palace

@MainActor
final class AccessibilityTraversalAuditTests: XCTestCase {

    private var host: AccessibilityAuditHost?

    override class func tearDown() {
        MainActor.assumeIsolated { AccessibilityRuntime.restore() }
        super.tearDown()
    }

    override func tearDown() {
        host?.tearDown()
        host = nil
        super.tearDown()
    }

    // MARK: - SwiftUI

    func testSwiftUIButton_labeled_activatesAndReportsNoViolation() {
        var taps = 0
        let report = audit(swiftUI: Button("Borrow") { taps += 1 })

        XCTAssertEqual(report.actionable.map(\.label), ["Borrow"])
        XCTAssertEqual(report.violations, [])
        XCTAssertEqual(taps, 1, "the double-tap must reach the button's action exactly once")
    }

    func testSwiftUIButton_withoutAnyLabel_isReportedAsMissingLabel() {
        let report = audit(swiftUI: Button(action: {}, label: { Color.red.frame(width: 44, height: 44) }))

        XCTAssertEqual(report.actionable.count, 1)
        XCTAssertEqual(report.violations.map(\.kind), [.missingLabel])
    }

    /// The "double-tap does nothing" shape: a view announced as a button that
    /// has no action behind it.
    func testSwiftUIText_withButtonTraitButNoAction_isReportedAsNotActivating() {
        let report = audit(swiftUI: Text("Listen").accessibilityAddTraits(.isButton))

        XCTAssertEqual(report.actionable.map(\.label), ["Listen"])
        guard case .activationFailed? = report.violations.first?.kind else {
            return XCTFail("expected an activation failure, got \(report.violations)")
        }
    }

    func testSwiftUIAccessibilityHidden_subtreeIsNotTraversed() {
        let report = audit(swiftUI: VStack {
            Button("Visible") {}
            Button("Hidden") {}.accessibilityHidden(true)
        })

        XCTAssertEqual(report.labels, ["Visible"])
    }

    // MARK: - UIKit

    func testUIKitControl_withoutActivateOverride_isActivatedByTapAtItsActivationPoint() {
        let control = TapCountingControl(frame: CGRect(x: 40, y: 200, width: 120, height: 44))
        control.accessibilityLabel = "Return"
        let report = audit(uiKit: [control])

        XCTAssertEqual(report.violations, [])
        XCTAssertEqual(control.taps, 1)
        guard case .activated(let via)? = report.activations.first?.result else {
            return XCTFail("expected an activation, got \(report.activations)")
        }
        XCTAssertTrue(via.hasPrefix("tap at activation point"), "activation took the unexpected path: \(via)")
    }

    /// A control whose activation point is covered by another control: the
    /// VoiceOver tap lands on the cover, not on the control announced.
    func testUIKitControl_coveredByAnotherControl_isReportedAndItsActionDoesNotFire() {
        let control = TapCountingControl(frame: CGRect(x: 40, y: 200, width: 120, height: 44))
        control.accessibilityLabel = "Return"
        let cover = TapCountingControl(frame: CGRect(x: 0, y: 150, width: 400, height: 200))
        cover.isAccessibilityElement = false
        let report = audit(uiKit: [control, cover])

        XCTAssertEqual(control.taps, 0)
        guard case .activationFailed(let reason)? = report.violations.first?.kind else {
            return XCTFail("expected an activation failure, got \(report.violations)")
        }
        XCTAssertTrue(reason.contains("different control"), reason)
    }

    func testUIKitControl_withZeroSize_isReportedAsUnfocusable() {
        let control = TapCountingControl(frame: CGRect(x: 40, y: 200, width: 0, height: 0))
        control.accessibilityLabel = "Return"
        let report = audit(uiKit: [control], activate: false)

        XCTAssertEqual(report.violations.map(\.kind), [.zeroSizeFrame])
    }

    func testModalSibling_hidesTheOtherSiblingsFromTraversal() {
        let behind = TapCountingControl(frame: CGRect(x: 40, y: 100, width: 120, height: 44))
        behind.accessibilityLabel = "Behind"
        let modal = UIView(frame: CGRect(x: 0, y: 300, width: 400, height: 300))
        modal.accessibilityViewIsModal = true
        let inModal = TapCountingControl(frame: CGRect(x: 40, y: 20, width: 120, height: 44))
        inModal.accessibilityLabel = "In sheet"
        modal.addSubview(inModal)
        let report = audit(uiKit: [behind, modal], activate: false)

        XCTAssertEqual(report.labels, ["In sheet"])
    }

    func testAdjustable_whoseValueNeverChanges_isReported() {
        let stuck = AdjustableView(frame: CGRect(x: 40, y: 200, width: 300, height: 44), step: 0)
        let working = AdjustableView(frame: CGRect(x: 40, y: 300, width: 300, height: 44), step: 1)
        stuck.accessibilityLabel = "Stuck"
        working.accessibilityLabel = "Working"
        let report = audit(uiKit: [stuck, working])

        XCTAssertEqual(report.violations.map(\.element), ["\"Stuck\""])
        XCTAssertEqual(report.violations.map(\.kind), [.adjustableDoesNotAdjust])
        XCTAssertNotEqual(working.level, 0, "a working adjustable must have been adjusted")
    }

    // MARK: - Accessibility runtime flag

    func testValueToRestore_withoutAMarker_isTheValueFoundAtEnable() {
        XCTAssertEqual(AccessibilityRuntime.valueToRestore(current: 1, markerFromUnfinishedRun: false), 1)
        XCTAssertEqual(AccessibilityRuntime.valueToRestore(current: 0, markerFromUnfinishedRun: false), 0)
    }

    /// A marker left by a run that never restored means the flag's "on" is a
    /// leftover, so restore turns it off.
    func testValueToRestore_withAMarkerFromAnUnfinishedRun_isOff() {
        XCTAssertEqual(AccessibilityRuntime.valueToRestore(current: 1, markerFromUnfinishedRun: true), 0)
    }

    func testRestore_afterAnUnfinishedRunsMarker_turnsTheFlagOffAndRemovesTheMarker() throws {
        let savedDirectory = AccessibilityRuntime.markerDirectory
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AccessibilityRuntime.markerDirectory = savedDirectory
            try? FileManager.default.removeItem(at: directory)
        }
        AccessibilityRuntime.restore() // start from no captured state
        AccessibilityRuntime.markerDirectory = directory
        FileManager.default.createFile(atPath: AccessibilityRuntime.markerURL.path, contents: nil)

        XCTAssertTrue(AccessibilityRuntime.enable())
        AccessibilityRuntime.restore()

        XCTAssertFalse(AccessibilityRuntime.isEnabled, "the leftover flag must be turned off")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AccessibilityRuntime.markerURL.path))
    }

    // MARK: - Helpers

    private func audit<V: View>(swiftUI view: V) -> AXAuditReport {
        let host = AccessibilityAuditHost(UIHostingController(rootView: view))
        self.host = host
        return AccessibilityTraversalAudit.audit(screen: "fixture", root: host.window, window: host.window)
    }

    private func audit(uiKit views: [UIView], activate: Bool = true) -> AXAuditReport {
        let controller = UIViewController()
        controller.view.backgroundColor = .white
        views.forEach(controller.view.addSubview)
        let host = AccessibilityAuditHost(controller)
        self.host = host
        return AccessibilityTraversalAudit.audit(screen: "fixture", root: host.window, window: host.window,
                                                 activate: { _ in activate })
    }
}

/// A plain `UIControl` exposed as a button. It does not override
/// `accessibilityActivate()`, so VoiceOver (and the audit) fall back to a tap
/// at its activation point.
private final class TapCountingControl: UIControl {
    private(set) var taps = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { taps += 1 }
}

/// An adjustable element whose increment/decrement moves `level` by `step`.
private final class AdjustableView: UIView {
    private(set) var level = 0
    private let step: Int

    init(frame: CGRect, step: Int) {
        self.step = step
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var accessibilityValue: String? {
        get { "\(level)" }
        set {}
    }

    override func accessibilityIncrement() { level += step }
    override func accessibilityDecrement() { level -= step }
}

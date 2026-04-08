//
//  AccessibilityAuditHelpers.swift
//  PalaceUITests
//
//  Helpers wrapping XCUIApplication.performAccessibilityAudit (iOS 17+).
//

import XCTest

/// Scope of an accessibility audit run.
///
/// - quick: Only blocking visual issues (contrast, hit region size).
/// - full:  Comprehensive audit covering labels, traits, descriptions, etc.
enum AccessibilityAuditScope {
    case quick
    case full

    @available(iOS 17.0, *)
    var auditTypes: XCUIAccessibilityAuditType {
        switch self {
        case .quick:
            return [.contrast, .hitRegion]
        case .full:
            return [
                .dynamicType,
                .contrast,
                .elementDetection,
                .hitRegion,
                .sufficientElementDescription,
                .parentChild,
                .trait,
                .action
            ]
        }
    }
}

extension XCUIApplication {

    /// Runs a full accessibility audit using the default set of audit types.
    ///
    /// On iOS < 17 this is a no-op (audit API unavailable). Failures are
    /// auto-attached to the test report by XCTest.
    func runFullAudit(file: StaticString = #filePath, line: UInt = #line) throws {
        if #available(iOS 17.0, *) {
            try performAccessibilityAudit(for: AccessibilityAuditScope.full.auditTypes)
        } else {
            throw XCTSkip("Accessibility audit requires iOS 17+", file: file, line: line)
        }
    }

    /// Runs an audit at the requested scope and attaches a screenshot of the
    /// current app state to the active test activity for visual review.
    func auditAndAttach(
        scope: AccessibilityAuditScope,
        name: String = "audit",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let attachment = XCTAttachment(screenshot: screenshot())
        attachment.name = "\(name)-screenshot"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Attach \(name) screenshot") { activity in
            activity.add(attachment)
        }

        if #available(iOS 17.0, *) {
            try performAccessibilityAudit(for: scope.auditTypes)
        } else {
            throw XCTSkip("Accessibility audit requires iOS 17+", file: file, line: line)
        }
    }
}

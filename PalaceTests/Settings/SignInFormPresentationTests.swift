//
//  SignInFormPresentationTests.swift
//  PalaceTests
//
//  PR3 (PP-4746) — sign-in button + inline error PRESENTATION seams.
//
//  Pins the pure, presentation-only decisions extracted for the sign-in polish.
//  No authentication / credential / network logic is exercised or changed here
//  — these functions only map existing @Published inputs to display state.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class SignInFormPresentationTests: XCTestCase {

    // MARK: - ActionButtonView.titleOpacity

    /// While loading, the title is fully hidden (0) so the centered spinner
    /// reads cleanly — it is no longer dimmed-and-overlapping (was 0.5).
    func test_titleOpacity_hidesTitleWhileLoading() {
        XCTAssertEqual(ActionButtonView.titleOpacity(isLoading: true), 0,
                       "Loading must fully hide the title (0) so the spinner doesn't overlap dimmed text.")
    }

    /// Idle shows the title at full opacity.
    func test_titleOpacity_showsTitleWhenIdle() {
        XCTAssertEqual(ActionButtonView.titleOpacity(isLoading: false), 1,
                       "Idle must show the title at full opacity (1) — kills the constant-return mutation.")
    }

    // MARK: - AccountDetailView.shouldShowInlineFormError

    /// The inline error appears only when there is an active alert AND a
    /// non-empty message — mirrors the existing @Published state, adds no logic.
    func test_shouldShowInlineFormError_requiresAlertAndMessage() {
        XCTAssertTrue(AccountDetailView.shouldShowInlineFormError(showingAlert: true, message: "Bad PIN"),
                      "Active alert + non-empty message → inline row shows.")
        XCTAssertFalse(AccountDetailView.shouldShowInlineFormError(showingAlert: false, message: "Bad PIN"),
                       "No active alert → inline row hidden even if a stale message lingers. KEY ROW for the `&&`.")
        XCTAssertFalse(AccountDetailView.shouldShowInlineFormError(showingAlert: true, message: ""),
                       "Empty message → no inline row (nothing to display) — kills the drop-`!isEmpty` mutation.")
        XCTAssertFalse(AccountDetailView.shouldShowInlineFormError(showingAlert: false, message: ""),
                       "Neither condition met → hidden.")
    }
}

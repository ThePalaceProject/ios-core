//
//  TPPReturnPromptHelperTests.swift
//  PalaceTests
//
//  Tests for TPPReturnPromptHelper alert creation.
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// SRS: AUDIO-006 -- Return prompt displays correctly after audiobook completion
final class TPPReturnPromptHelperTests: XCTestCase {

    /// SRS: AUDIO-006 -- Return prompt displays correctly after audiobook completion
    func testAudiobookPrompt_createsAlertController() {
        let alert = TPPReturnPromptHelper.audiobookPrompt { _ in }

        XCTAssertNotNil(alert)
        XCTAssertEqual(alert.preferredStyle, .alert)
    }

    /// SRS: AUDIO-006 -- Return prompt displays correctly after audiobook completion
    func testAudiobookPrompt_hasExactlyKeepAndReturnActionsWithTitles() {
        // Two actions must be present and each tagged with a non-empty title —
        // a regression that collapsed them into one (or added a third) would
        // hide Return or confuse users with a stray action; a blank title
        // would strand VoiceOver users with no readable label.
        let alert = TPPReturnPromptHelper.audiobookPrompt { _ in }

        XCTAssertEqual(alert.actions.count, 2,
                        "Alert should have exactly two actions (keep + return)")
        for action in alert.actions {
            XCTAssertFalse(action.title?.isEmpty ?? true,
                           "Every action must have a non-empty title for VoiceOver")
        }
        XCTAssertNotNil(alert.title,
                        "Alert must have a title so the prompt is self-describing")
    }

    /// SRS: AUDIO-006 -- Return prompt displays correctly after audiobook completion
    func testAudiobookPrompt_hasKeepAction_withCancelStyle() {
        let alert = TPPReturnPromptHelper.audiobookPrompt { _ in }

        let keepAction = alert.actions.first { $0.style == .cancel }
        XCTAssertNotNil(keepAction, "Should have a cancel-style keep action")
        XCTAssertFalse(keepAction?.title?.isEmpty ?? true,
                        "Keep action should have a title")
    }

    /// SRS: AUDIO-006 -- Return prompt displays correctly after audiobook completion
    func testAudiobookPrompt_hasReturnAction_withDefaultStyle() {
        let alert = TPPReturnPromptHelper.audiobookPrompt { _ in }

        let returnAction = alert.actions.first { $0.style == .default }
        XCTAssertNotNil(returnAction, "Should have a default-style return action")
        XCTAssertFalse(returnAction?.title?.isEmpty ?? true,
                        "Return action should have a title")
    }

    /// SRS: AUDIO-006 -- Return prompt displays correctly after audiobook completion
    func testAudiobookPrompt_hasTitleAndMessage() {
        let alert = TPPReturnPromptHelper.audiobookPrompt { _ in }

        XCTAssertNotNil(alert.title, "Alert should have a title")
        XCTAssertFalse(alert.title?.isEmpty ?? true, "Alert title should not be empty")
        XCTAssertNotNil(alert.message, "Alert should have a message")
        XCTAssertFalse(alert.message?.isEmpty ?? true, "Alert message should not be empty")
    }
}

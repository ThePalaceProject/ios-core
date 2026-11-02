//
//  AudiobookMorphingPlayerView+VoiceOverFocus.swift
//  Palace
//
//  Where VoiceOver focus goes when the full player opens (PP-5450).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import SwiftUI

extension AudiobookMorphingPlayerView {
    /// Where VoiceOver focus goes when the player opens.
    enum VoiceOverFocusTarget: Hashable {
        case title
        case playPause
        case loading
    }

    enum OpeningFocusStep: Equatable {
        case none
        case focus(VoiceOverFocusTarget)
        case focusLoadingThenPlay
    }

    /// The full player is opened to listen, so VoiceOver starts on Play. While the
    /// loading overlay covers the controls a focus request on Play is dropped, so
    /// focus goes to the overlay, which says it is loading, and moves to Play once
    /// the overlay clears. The mini player sits under other content and takes no focus.
    nonisolated static func openingVoiceOverFocusStep(
        isExpanded: Bool,
        overlayCoversControls: Bool
    ) -> OpeningFocusStep {
        guard isExpanded else { return .none }
        return overlayCoversControls ? .focusLoadingThenPlay : .focus(.playPause)
    }

    /// The focus owed by an open that waited, once the overlay stops covering the controls.
    nonisolated static func focusWhenControlsUncovered(
        waiting: Bool,
        overlayCoversControls: Bool
    ) -> VoiceOverFocusTarget? {
        waiting && !overlayCoversControls ? .playPause : nil
    }
}

/// Applies `openingVoiceOverFocusStep` on open, and the deferred focus when the
/// loading overlay clears.
struct AudiobookPlayerOpeningFocus: ViewModifier {
    let focus: AccessibilityFocusState<AudiobookMorphingPlayerView.VoiceOverFocusTarget?>.Binding
    let isExpanded: Bool
    let overlayCoversControls: Bool
    @State private var waiting = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                switch AudiobookMorphingPlayerView.openingVoiceOverFocusStep(
                    isExpanded: isExpanded, overlayCoversControls: overlayCoversControls
                ) {
                case .none:
                    break
                case .focusLoadingThenPlay:
                    waiting = true
                    // Skip if the overlay already cleared and focus moved on to Play.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if waiting { focus.wrappedValue = .loading } }
                case .focus(let target):
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { focus.wrappedValue = target }
                }
            }
            .onChange(of: overlayCoversControls) { _, covered in
                guard let target = AudiobookMorphingPlayerView.focusWhenControlsUncovered(
                    waiting: waiting, overlayCoversControls: covered
                ) else { return }
                waiting = false
                // Let the overlay's removal settle before focus moves onto the controls.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus.wrappedValue = target }
            }
    }
}

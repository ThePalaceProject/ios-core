//
//  IsReaderActiveTrackingModifier.swift
//  Palace
//
//  Flips the audiobook presenter's `isReaderActive` flag on appear /
//  disappear so the mini-player hides while a reader is on screen.
//  Applied per rendered sub-branch in `NavigationHostView`, not per case
//  label: each reader case has several `if let` views with their own
//  lifecycles. See docs/architecture/in-app-navigation-during-playback.md §7.3.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Wraps a view's `onAppear` / `onDisappear` lifecycle so reader render
/// paths flip `AudiobookSessionPresenter.isReaderActive` symmetrically.
///
/// Without it the root-mounted mini-player flashes over Reader2 / Reader3.
struct IsReaderActiveTrackingModifier: ViewModifier {
    let presenter: AudiobookSessionPresenter

    func body(content: Content) -> some View {
        content
            .onAppear { presenter.isReaderActive = true }
            .onDisappear { presenter.isReaderActive = false }
    }
}

extension View {
    /// Apply to a reader-render sub-branch (EPUB, PDF, presented EPUB
    /// sample) so the audiobook mini-player suppresses while the reader
    /// is on-screen. MUST be applied per sub-branch, NOT per case label —
    /// see the type-level docs above for why.
    func tracksReaderActive(_ presenter: AudiobookSessionPresenter) -> some View {
        modifier(IsReaderActiveTrackingModifier(presenter: presenter))
    }
}

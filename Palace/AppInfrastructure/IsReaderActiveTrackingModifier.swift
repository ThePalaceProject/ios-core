//
//  IsReaderActiveTrackingModifier.swift
//  Palace
//
//  Module D (swarm_0b7616e7) — view modifier that flips the audiobook
//  session presenter's `isReaderActive` flag on view appear / disappear.
//
//  Applied per-sub-branch on each reader render path in
//  `NavigationHostView` (see §7.3 Option α and the architect's A3
//  clarification). When a reader sub-branch's view appears, the
//  mini-player suppresses; on disappear (pop, dismiss, route swap), the
//  mini-player returns.
//
//  Why per-sub-branch instead of per-case label: each reader case has
//  multiple `if let` rendered views, each with its own appearance
//  lifecycle. Applying the modifier to the case label only would cover
//  one branch; the others would leak the mini-player when their `if let`
//  binds. Applying per sub-branch is the structural fix.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Wraps a view's `onAppear` / `onDisappear` lifecycle so reader render
/// paths flip `AudiobookSessionPresenter.isReaderActive` symmetrically.
///
/// This is the §7.3 Option α load-bearing piece — without it, the
/// root-mounted mini-player flashes over Reader2 / Reader3 during a
/// reading session. The modifier is intentionally a thin closure pair
/// so the wiring is mechanical and grep-able from
/// `NavigationHostView.swift` via the `tracksReaderActive(_:)`
/// convenience extension below.
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

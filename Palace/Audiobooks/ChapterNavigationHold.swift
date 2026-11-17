//
//  ChapterNavigationHold.swift
//  Palace
//
//  PP-5205. The hold an explicit chapter selection keeps on the displayed chapter
//  until the seek it started actually produces a position for that chapter.
//
//  Without it, the chapter label stays on the previous chapter until the seek
//  produces a position. This owns the mechanism (target key + timeout); the
//  decisions are pure in `ChapterNavigationPolicy`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit
import PalaceLogging

@MainActor
final class ChapterNavigationHold {

    /// How long an explicit selection holds the label against reactive updates for
    /// other tracks. Matches the toolkit playback model's own navigation timeout so
    /// the two layers cannot disagree about when a seek is considered abandoned.
    static let defaultTimeoutSeconds: TimeInterval = 3.0

    /// Injected so tests need not sleep for the production duration.
    private let timeoutSeconds: TimeInterval

    private var targetTrackKey: String?
    private var timeout: DispatchWorkItem?

    init(timeoutSeconds: TimeInterval = ChapterNavigationHold.defaultTimeoutSeconds) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Records an explicit selection and returns the chapter to publish now, or
    /// `nil` when the label already names it (re-tapping the playing chapter must
    /// not re-announce it to CarPlay and the presenter).
    func beginSelection(of chapter: Chapter, replacing current: Chapter?) -> Chapter? {
        beginSelection(
            selectedKey: chapter.position.track.key,
            selectedTitle: chapter.title,
            currentKey: current?.position.track.key,
            currentTitle: current?.title
        ) ? chapter : nil
    }

    /// Consumes a reactive chapter update and returns the chapter to publish, or
    /// `nil` to change nothing. Releases the hold once the seek has landed.
    func chapterToPublish(from incoming: Chapter?, replacing current: Chapter?) -> Chapter? {
        guard let incoming, shouldPublish(
            incomingKey: incoming.position.track.key,
            incomingTitle: incoming.title,
            currentKey: current?.position.track.key,
            currentTitle: current?.title
        ) else { return nil }
        return incoming
    }

    // MARK: - The same two decisions, keyed on identity rather than on `Chapter`
    //
    // `Chapter` has no public initialiser, so the logic lives in these
    // String-keyed forms; the two wrappers above only delegate.

    func beginSelection(
        selectedKey: String,
        selectedTitle: String,
        currentKey: String?,
        currentTitle: String?
    ) -> Bool {
        arm(forTrackKey: selectedKey)
        return ChapterNavigationPolicy.selectionNeedsImmediatePublish(
            currentKey: currentKey,
            currentTitle: currentTitle,
            selectedKey: selectedKey,
            selectedTitle: selectedTitle
        )
    }

    /// `playAtPosition` is fire-and-forget, so an update arriving in the gap between
    /// the tap and the player accepting the target still names the chapter just
    /// left. Applying it flips the label back, and the seek landing flips it forward
    /// again — the visible switch. The hold makes that gap unobservable.
    func shouldPublish(
        incomingKey: String,
        incomingTitle: String,
        currentKey: String?,
        currentTitle: String?
    ) -> Bool {
        switch ChapterNavigationPolicy.reactiveUpdate(
            navigationTargetTrackKey: targetTrackKey,
            currentKey: currentKey,
            currentTitle: currentTitle,
            newKey: incomingKey,
            newTitle: incomingTitle
        ) {
        case .ignore:
            return false
        case .releaseHold:
            release()
            return false
        case .applyAndRelease:
            release()
            Log.debug(#file, "Chapter changed to: '\(incomingTitle)'")
            return true
        }
    }

    /// Drops any hold. A hold belongs to the session that armed it — leaving one
    /// armed across a teardown would suppress the next book's first chapter update.
    func release() {
        timeout?.cancel()
        timeout = nil
        targetTrackKey = nil
    }

    /// Replaces any hold already in flight (a second tap supersedes the first) and
    /// re-arms the bound. The bound is not a fallback: a seek that never lands must
    /// not leave the label pinned to a chapter that is not playing.
    private func arm(forTrackKey trackKey: String) {
        timeout?.cancel()
        targetTrackKey = trackKey
        let work = DispatchWorkItem { [weak self] in
            self?.targetTrackKey = nil
            self?.timeout = nil
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
    }
}

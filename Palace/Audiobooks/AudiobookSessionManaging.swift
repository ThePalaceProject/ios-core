//
//  AudiobookSessionManaging.swift
//  Palace
//
//  Created for dependency injection support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import PalaceAudiobookToolkit
import UIKit

/// Protocol for managing audiobook playback sessions, enabling dependency injection for testing.
///
/// This protocol extracts the consumer-facing interface from `AudiobookSessionManager`,
/// allowing tests to inject mock implementations instead of relying on the singleton.
@MainActor
protocol AudiobookSessionManaging: AnyObject {

    // MARK: - Published State

    /// The current state of the audiobook session.
    var state: AudiobookSessionState { get }

    /// The book currently loaded for playback, if any.
    var currentBook: TPPBook? { get }

    /// The list of chapters for the current audiobook.
    var currentChapters: [Chapter] { get }

    /// The currently playing chapter.
    var currentChapter: Chapter? { get }

    /// The current playback position.
    var currentPosition: TrackPosition? { get }

    /// Whether playback is currently active.
    var isPlaying: Bool { get }

    /// The cover image for the current audiobook.
    var coverImage: UIImage? { get }

    // MARK: - Publishers

    /// Emits when playback state changes (for CarPlay UI updates, etc.).
    var playbackStatePublisher: PassthroughSubject<AudiobookSessionState, Never> { get }

    /// Emits when the chapter list or current chapter changes.
    var chapterUpdatePublisher: PassthroughSubject<(chapters: [Chapter], current: Chapter?), Never> { get }

    /// Emits errors for UI display.
    var errorPublisher: PassthroughSubject<AudiobookSessionError, Never> { get }

    // MARK: - Playback Control

    /// Opens and starts playing an audiobook.
    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool) async -> Result<Void, AudiobookSessionError>

    /// Plays the current audiobook.
    func play()

    /// Pauses the current audiobook.
    func pause()

    /// Toggles play/pause.
    func togglePlayPause()

    /// Skips to a specific chapter by index.
    func skipToChapter(at index: Int)

    /// Cycles through available playback rates and returns the new rate.
    func cyclePlaybackRate() -> PlaybackRate

    /// Stops playback and clears the current session.
    func stopPlayback(dismissPhoneUI: Bool) async

    /// Updates the cover image for Now Playing display.
    func updateCoverImage(_ image: UIImage?)
}

// MARK: - AudiobookSessionManager Conformance

extension AudiobookSessionManager: AudiobookSessionManaging {}

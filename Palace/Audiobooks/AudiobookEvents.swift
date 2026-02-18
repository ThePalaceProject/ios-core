//
//  AudiobookEvents.swift
//  Palace
//
//  Combine-based event publishing for audiobook lifecycle events.
//

import Combine
import PalaceAudiobookToolkit

/// Centralized publisher for audiobook-related events.
/// Provides type-safe Combine publishers instead of NotificationCenter.
enum AudiobookEvents {
  
  /// Emits when a new AudiobookManager is created and ready for playback.
  /// Subscribers receive the strongly-typed manager instance directly.
  static let managerCreated = PassthroughSubject<AudiobookManager, Never>()
}

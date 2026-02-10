//
//  NowPlayingCoordinator.swift
//  Palace
//
//  Coordinates all updates to MPNowPlayingInfoCenter.
//  Eliminates race conditions by providing a single update path with debouncing.
//
//  Note: Remote commands (play/pause/skip) are handled by the toolkit's MediaControlPublisher.
//  This coordinator only manages Now Playing INFO, not commands.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import MediaPlayer
import PalaceAudiobookToolkit
import UIKit

// MARK: - NowPlayingCoordinator

/// Coordinates all updates to MPNowPlayingInfoCenter.
/// This is the ONLY class that should update Now Playing info to prevent race conditions.
/// 
/// Note: Remote commands are handled by the toolkit's MediaControlPublisher, not here.
/// This avoids conflicts where multiple handlers try to manage the same commands.
@MainActor
public final class NowPlayingCoordinator {
  
  // MARK: - Configuration
  
  private enum Configuration {
    /// Minimum interval between Now Playing updates (debounce)
    static let updateDebounceInterval: TimeInterval = 0.3
  }
  
  // MARK: - Properties
  
  private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
  
  private var currentInfo: [String: Any] = [:]
  private var currentArtwork: MPMediaItemArtwork?
  private var lastUpdateTime: Date = .distantPast
  private var pendingUpdate: DispatchWorkItem?
  
  // MARK: - Initialization
  
  public init() {
    Log.info(#file, "NowPlayingCoordinator initialized")
  }
  
  deinit {
    Log.info(#file, "NowPlayingCoordinator deinitialized")
  }
  
  // MARK: - Public API
  
  /// Updates Now Playing info with all metadata.
  /// This is the primary update method - handles debouncing automatically.
  public func updateNowPlaying(
    title: String,
    artist: String?,
    album: String?,
    elapsed: TimeInterval,
    duration: TimeInterval,
    isPlaying: Bool,
    playbackRate: PlaybackRate
  ) {
    // Build the info dictionary
    var info: [String: Any] = [:]
    info[MPMediaItemPropertyTitle] = title
    
    if let artist = artist {
      info[MPMediaItemPropertyArtist] = artist
    }
    if let album = album {
      info[MPMediaItemPropertyAlbumTitle] = album
    }
    
    // Ensure valid timing values
    let safeElapsed = max(0, min(elapsed, duration))
    let safeDuration = max(1.0, abs(duration))
    
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = safeElapsed
    info[MPMediaItemPropertyPlaybackDuration] = safeDuration
    
    // Set playback rate
    let rateValue = Double(PlaybackRate.convert(rate: playbackRate))
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rateValue
    info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rateValue : 0.0
    
    // Set media type for CarPlay
    info[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
    
    // Preserve artwork if set
    if let artwork = currentArtwork {
      info[MPMediaItemPropertyArtwork] = artwork
    }
    
    // Apply update with debouncing
    applyUpdate(info, isPlaying: isPlaying)
  }
  
  /// Updates only the playback state (playing/paused)
  /// Use this for quick state toggles without full info update
  public func setPlaybackState(playing: Bool) {
    var info = currentInfo
    
    // Update rate based on playing state
    let currentRate = info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double ?? 1.0
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? currentRate : 0.0
    
    // Apply immediately (no debounce for state changes)
    currentInfo = info
    nowPlayingInfoCenter.nowPlayingInfo = info
    nowPlayingInfoCenter.playbackState = playing ? .playing : .paused
    
    Log.debug(#file, "Playback state set: \(playing ? "playing" : "paused")")
  }
  
  /// Updates playback rate
  public func updatePlaybackRate(_ rate: PlaybackRate) {
    var info = currentInfo
    let rateValue = Double(PlaybackRate.convert(rate: rate))
    
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rateValue
    
    // If playing, also update current rate
    let isPlaying = nowPlayingInfoCenter.playbackState == .playing
    if isPlaying {
      info[MPNowPlayingInfoPropertyPlaybackRate] = rateValue
    }
    
    currentInfo = info
    nowPlayingInfoCenter.nowPlayingInfo = info
    
    Log.debug(#file, "Playback rate updated: \(rateValue)x")
  }
  
  /// Updates artwork separately from other info
  /// This prevents artwork updates from being debounced
  public func updateArtwork(_ image: UIImage?) {
    guard let image = image else {
      currentArtwork = nil
      return
    }
    
    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    currentArtwork = artwork
    
    var info = currentInfo
    info[MPMediaItemPropertyArtwork] = artwork
    currentInfo = info
    nowPlayingInfoCenter.nowPlayingInfo = info
    
    Log.debug(#file, "Artwork updated")
  }
  
  /// Clears all Now Playing info
  public func clearNowPlaying() {
    pendingUpdate?.cancel()
    pendingUpdate = nil
    
    currentInfo = [:]
    currentArtwork = nil
    nowPlayingInfoCenter.nowPlayingInfo = nil
    nowPlayingInfoCenter.playbackState = .stopped
    
    Log.info(#file, "Now Playing cleared")
  }
  
  // MARK: - Private Methods
  
  private func applyUpdate(_ info: [String: Any], isPlaying: Bool) {
    // Cancel any pending update
    pendingUpdate?.cancel()
    
    // Check if we should debounce
    let now = Date()
    let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
    
    if timeSinceLastUpdate >= Configuration.updateDebounceInterval {
      // Apply immediately
      performUpdate(info, isPlaying: isPlaying)
    } else {
      // Schedule debounced update
      let workItem = DispatchWorkItem { [weak self] in
        Task { @MainActor in
          self?.performUpdate(info, isPlaying: isPlaying)
        }
      }
      pendingUpdate = workItem
      
      let delay = Configuration.updateDebounceInterval - timeSinceLastUpdate
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
  }
  
  private func performUpdate(_ info: [String: Any], isPlaying: Bool) {
    currentInfo = info
    lastUpdateTime = Date()
    
    nowPlayingInfoCenter.nowPlayingInfo = info
    nowPlayingInfoCenter.playbackState = isPlaying ? .playing : .paused
    
    let title = info[MPMediaItemPropertyTitle] as? String ?? "Unknown"
    let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
    let duration = info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
    let hasArtwork = info[MPMediaItemPropertyArtwork] != nil
    
    Log.debug(#file, "Now Playing updated - title: '\(title)', elapsed: \(Int(elapsed))s/\(Int(duration))s, playing: \(isPlaying)")
  }
}

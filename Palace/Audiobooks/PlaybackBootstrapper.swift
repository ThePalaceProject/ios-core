//
//  PlaybackBootstrapper.swift
//  Palace
//
//  Ensures audio playback infrastructure is ready for CarPlay cold starts.
//  This class sets up AVAudioSession and MPRemoteCommandCenter handlers
//  BEFORE any book is opened, enabling remote controls to work immediately.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation
import MediaPlayer
import PalaceAudiobookToolkit

// MARK: - PlaybackBootstrapper

/// Singleton that bootstraps audio playback infrastructure for CarPlay cold starts.
/// 
/// On iOS, CarPlay can launch the app in the background (cold start) without any UI.
/// For remote controls (play/pause/skip) to work, we must:
/// 1. Configure AVAudioSession early
/// 2. Register MPRemoteCommandCenter handlers BEFORE a book is opened
/// 3. Route commands to the active AudiobookManager when one exists
///
/// This class ensures these requirements are met, independent of UI lifecycle.
///
/// ## Usage
/// Call `PlaybackBootstrapper.shared.ensureInitialized()` early in:
/// - `TPPAppDelegate.application(_:didFinishLaunchingWithOptions:)`
/// - `CarPlaySceneDelegate.templateApplicationScene(_:didConnect:)`
///
/// ## Regression Test Plan
/// 1. Force-quit the Palace app on your phone
/// 2. Connect to CarPlay (car or Xcode simulator)
/// 3. Launch Palace from CarPlay
/// 4. Select an audiobook and play
/// 5. Verify: Play/Pause works via CarPlay buttons
/// 6. Verify: Skip forward/backward (30s) works
/// 7. Verify: Steering wheel media buttons work
/// 8. Lock phone screen during playback - verify controls still work
/// 9. Disconnect and reconnect CarPlay - verify no duplicate handlers
///
@MainActor
public final class PlaybackBootstrapper {
  
  // MARK: - Singleton
  
  public static let shared = PlaybackBootstrapper()
  
  // MARK: - State
  
  private var isInitialized = false
  private var commandTargets: [Any] = []
  private let commandCenter = MPRemoteCommandCenter.shared()
  
  // MARK: - Initialization
  
  private init() {
    Log.info(#file, "🚀 PlaybackBootstrapper created - app launch context")
    
    // Log the launch context for debugging cold start issues
    let launchReason = determineLaunchContext()
    Log.info(#file, "🚀 Launch context: \(launchReason)")
  }
  
  /// Determines how the app was launched (for diagnostic logging)
  private func determineLaunchContext() -> String {
    var context: [String] = []
    
    // Check if app has any connected scenes
    let application = UIApplication.shared
    let connectedScenes = application.connectedScenes
    
    for scene in connectedScenes {
      switch scene.session.role {
      case .carTemplateApplication:
        context.append("CarPlay")
      case .windowApplication:
        context.append("MainApp")
      default:
        context.append("Other(\(scene.session.role.rawValue))")
      }
    }
    
    if context.isEmpty {
      context.append("NoScenesYet")
    }
    
    // Check if running in background
    if application.applicationState == .background {
      context.append("Background")
    }
    
    return context.joined(separator: ", ")
  }
  
  // MARK: - Public API
  
  /// Ensures playback infrastructure is ready.
  /// Safe to call multiple times - will only initialize once.
  /// 
  /// Call this early in app lifecycle:
  /// - App launch (didFinishLaunchingWithOptions)
  /// - CarPlay scene connect
  ///
  /// ## Why This Matters for CarPlay Cold Start
  /// When CarPlay launches the app without the phone UI ever being shown:
  /// 1. Only CarPlaySceneDelegate receives lifecycle callbacks
  /// 2. No ViewControllers or SwiftUI views are created
  /// 3. Remote commands must work BEFORE any book is selected
  ///
  /// This method ensures MPRemoteCommandCenter is ready to receive commands
  /// even though there's no active playback yet. Commands received before
  /// a book is opened will return .noActionableNowPlayingItem, which is correct.
  public func ensureInitialized() {
    guard !isInitialized else {
      Log.info(#file, "🚀 PlaybackBootstrapper.ensureInitialized() - already initialized, skipping")
      return
    }
    
    let startTime = CFAbsoluteTimeGetCurrent()
    Log.info(#file, "🚀 PlaybackBootstrapper.ensureInitialized() - STARTING audio infrastructure setup")
    
    // 1. Configure audio session for playback
    Log.info(#file, "🚀 Step 1/3: Configuring AVAudioSession...")
    configureAudioSession()
    
    // 2. Set up remote command handlers
    Log.info(#file, "🚀 Step 2/3: Setting up MPRemoteCommandCenter handlers...")
    setupRemoteCommands()
    
    // 3. Ensure AudiobookSessionManager exists
    // This guarantees it's subscribed to AudiobookEvents.managerCreated
    Log.info(#file, "🚀 Step 3/3: Initializing AudiobookSessionManager...")
    _ = AudiobookSessionManager.shared
    
    isInitialized = true
    
    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    Log.info(#file, "🚀 PlaybackBootstrapper.ensureInitialized() - COMPLETE in \(String(format: "%.1f", elapsed))ms")
    Log.info(#file, "🚀 Remote commands are now ready to receive input (manager binding happens when book opens)")
  }
  
  /// Call when CarPlay connects to ensure audio session is active.
  /// This is the primary entry point for CarPlay cold starts.
  ///
  /// ## Idempotent Behavior
  /// Safe to call multiple times:
  /// - First call: Full initialization
  /// - Subsequent calls: Re-activates audio session and re-applies command config
  public func ensureInitializedForCarPlay() {
    Log.info(#file, "🚀 PlaybackBootstrapper.ensureInitializedForCarPlay() - CarPlay scene connected")
    
    // CRITICAL: Ensure book registry is loaded BEFORE CarPlay tries to show books
    // On cold start, the registry loads asynchronously and may not be ready yet
    _ = TPPBookRegistry.shared
    
    // Full initialization if not done yet
    ensureInitialized()
    
    // Re-activate audio session in case it was deactivated
    activateAudioSession()
    
    // Re-apply command configuration to ensure correctness after reconnect
    configureCommandSettings()
    
    Log.info(#file, "🚀 PlaybackBootstrapper.ensureInitializedForCarPlay() - CarPlay ready")
  }
  
  // MARK: - Audio Session
  
  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    
    do {
      // .playback category: continues in background
      // .spokenAudio mode: optimized for audiobooks, enables proper skip buttons
      try session.setCategory(
        .playback,
        mode: .spokenAudio,
        options: [.allowBluetoothA2DP, .allowAirPlay]
      )
      
      Log.info(#file, "🔊 Audio session configured (category: playback, mode: spokenAudio)")
    } catch {
      Log.error(#file, "🔊 Failed to configure audio session: \(error)")
    }
  }
  
  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    
    do {
      if !session.isOtherAudioPlaying {
        try session.setActive(true)
        Log.info(#file, "🔊 Audio session activated")
      }
    } catch {
      Log.error(#file, "🔊 Failed to activate audio session: \(error)")
    }
  }
  
  // MARK: - Remote Commands
  
  private func setupRemoteCommands() {
    Log.info(#file, "🎮 Setting up MPRemoteCommandCenter handlers")
    
    // Clear any existing targets first
    removeAllTargets()
    
    // Configure which commands are enabled
    configureCommandSettings()
    
    // Add our targets
    addCommandTargets()
    
    Log.info(#file, "🎮 Remote command handlers registered")
  }
  
  private func configureCommandSettings() {
    // Enable audiobook-specific commands
    commandCenter.playCommand.isEnabled = true
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.skipForwardCommand.isEnabled = true
    commandCenter.skipForwardCommand.preferredIntervals = [30]
    commandCenter.skipBackwardCommand.isEnabled = true
    commandCenter.skipBackwardCommand.preferredIntervals = [30]
    commandCenter.changePlaybackRateCommand.isEnabled = true
    
    // CRITICAL: Disable track navigation commands
    // Without this, CarPlay interprets skip as next/previous track
    commandCenter.nextTrackCommand.isEnabled = false
    commandCenter.previousTrackCommand.isEnabled = false
    commandCenter.seekForwardCommand.isEnabled = false
    commandCenter.seekBackwardCommand.isEnabled = false
    commandCenter.changeRepeatModeCommand.isEnabled = false
    commandCenter.changeShuffleModeCommand.isEnabled = false
    
    Log.debug(#file, "🎮 Command settings configured (skip intervals: 30s)")
  }
  
  private func addCommandTargets() {
    Log.info(#file, "🎮 Adding remote command targets...")
    
    // Play command
    let playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
      Log.info(#file, "🎮 ▶️ PLAY command received from remote")
      return self?.handlePlay() ?? .noActionableNowPlayingItem
    }
    commandTargets.append(playTarget)
    Log.debug(#file, "🎮 ✓ playCommand target registered")
    
    // Pause command
    let pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
      Log.info(#file, "🎮 ⏸️ PAUSE command received from remote")
      return self?.handlePause() ?? .noActionableNowPlayingItem
    }
    commandTargets.append(pauseTarget)
    Log.debug(#file, "🎮 ✓ pauseCommand target registered")
    
    // Toggle play/pause (headphone button, steering wheel)
    let toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      Log.info(#file, "🎮 ⏯️ TOGGLE command received from remote")
      return self?.handleTogglePlayPause() ?? .noActionableNowPlayingItem
    }
    commandTargets.append(toggleTarget)
    Log.debug(#file, "🎮 ✓ togglePlayPauseCommand target registered")
    
    // Skip forward (30 seconds)
    let skipForwardTarget = commandCenter.skipForwardCommand.addTarget { [weak self] event in
      guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
        Log.error(#file, "🎮 skipForward event cast failed")
        return .commandFailed
      }
      Log.info(#file, "🎮 ⏩ SKIP FORWARD \(skipEvent.interval)s command received from remote")
      return self?.handleSkipForward(interval: skipEvent.interval) ?? .noActionableNowPlayingItem
    }
    commandTargets.append(skipForwardTarget)
    Log.debug(#file, "🎮 ✓ skipForwardCommand target registered (30s interval)")
    
    // Skip backward (30 seconds)
    let skipBackwardTarget = commandCenter.skipBackwardCommand.addTarget { [weak self] event in
      guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
        Log.error(#file, "🎮 skipBackward event cast failed")
        return .commandFailed
      }
      Log.info(#file, "🎮 ⏪ SKIP BACKWARD \(skipEvent.interval)s command received from remote")
      return self?.handleSkipBackward(interval: skipEvent.interval) ?? .noActionableNowPlayingItem
    }
    commandTargets.append(skipBackwardTarget)
    Log.debug(#file, "🎮 ✓ skipBackwardCommand target registered (30s interval)")
    
    // Change playback rate
    let rateTarget = commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
      guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
        Log.error(#file, "🎮 changePlaybackRate event cast failed")
        return .commandFailed
      }
      Log.info(#file, "🎮 🔄 PLAYBACK RATE command received: \(rateEvent.playbackRate)x")
      return self?.handleChangePlaybackRate(rate: Float(rateEvent.playbackRate)) ?? .noActionableNowPlayingItem
    }
    commandTargets.append(rateTarget)
    Log.debug(#file, "🎮 ✓ changePlaybackRateCommand target registered")
    
    Log.info(#file, "🎮 All \(commandTargets.count) remote command targets registered successfully")
  }
  
  private func removeAllTargets() {
    // Remove specific targets we added (not all targets, which could affect other components)
    for target in commandTargets {
      commandCenter.playCommand.removeTarget(target)
      commandCenter.pauseCommand.removeTarget(target)
      commandCenter.togglePlayPauseCommand.removeTarget(target)
      commandCenter.skipForwardCommand.removeTarget(target)
      commandCenter.skipBackwardCommand.removeTarget(target)
      commandCenter.changePlaybackRateCommand.removeTarget(target)
    }
    commandTargets.removeAll()
  }
  
  // MARK: - Command Handlers
  
  /// Routes commands to the active AudiobookManager via AudiobookSessionManager.
  /// Returns .noActionableNowPlayingItem if no playback is active.
  ///
  /// Note: These handlers must work even when the phone UI has never been opened.
  /// The AudiobookSessionManager.shared.manager will be nil until a book is opened,
  /// at which point AudiobookEvents.managerCreated fires and binds the manager.
  
  private func handlePlay() -> MPRemoteCommandHandlerStatus {
    let manager = AudiobookSessionManager.shared.manager
    let state = AudiobookSessionManager.shared.state
    Log.info(#file, "🎮 handlePlay - manager: \(manager != nil), state: \(state)")
    
    guard let manager = manager else {
      Log.warn(#file, "🎮 Play command received but no active manager - book may not be loaded yet")
      return .noActionableNowPlayingItem
    }
    
    manager.play()
    Log.info(#file, "🎮 Play command executed successfully")
    return .success
  }
  
  private func handlePause() -> MPRemoteCommandHandlerStatus {
    let manager = AudiobookSessionManager.shared.manager
    Log.info(#file, "🎮 handlePause - manager: \(manager != nil)")
    
    guard let manager = manager else {
      Log.warn(#file, "🎮 Pause command received but no active manager")
      return .noActionableNowPlayingItem
    }
    
    manager.pause()
    Log.info(#file, "🎮 Pause command executed successfully")
    return .success
  }
  
  private func handleTogglePlayPause() -> MPRemoteCommandHandlerStatus {
    let manager = AudiobookSessionManager.shared.manager
    Log.info(#file, "🎮 handleTogglePlayPause - manager: \(manager != nil)")
    
    guard let manager = manager else {
      Log.warn(#file, "🎮 TogglePlayPause command received but no active manager")
      return .noActionableNowPlayingItem
    }
    
    let wasPlaying = manager.audiobook.player.isPlaying
    if wasPlaying {
      manager.pause()
    } else {
      manager.play()
    }
    Log.info(#file, "🎮 TogglePlayPause executed: wasPlaying=\(wasPlaying) -> \(!wasPlaying)")
    return .success
  }
  
  private func handleSkipForward(interval: TimeInterval) -> MPRemoteCommandHandlerStatus {
    let manager = AudiobookSessionManager.shared.manager
    Log.info(#file, "🎮 handleSkipForward(\(interval)s) - manager: \(manager != nil)")
    
    guard let manager = manager else {
      Log.warn(#file, "🎮 SkipForward command received but no active manager")
      return .noActionableNowPlayingItem
    }
    
    manager.audiobook.player.skipPlayhead(interval, completion: nil)
    Log.info(#file, "🎮 SkipForward \(interval)s executed successfully")
    return .success
  }
  
  private func handleSkipBackward(interval: TimeInterval) -> MPRemoteCommandHandlerStatus {
    let manager = AudiobookSessionManager.shared.manager
    Log.info(#file, "🎮 handleSkipBackward(\(interval)s) - manager: \(manager != nil)")
    
    guard let manager = manager else {
      Log.warn(#file, "🎮 SkipBackward command received but no active manager")
      return .noActionableNowPlayingItem
    }
    
    manager.audiobook.player.skipPlayhead(-interval, completion: nil)
    Log.info(#file, "🎮 SkipBackward \(interval)s executed successfully")
    return .success
  }
  
  private func handleChangePlaybackRate(rate: Float) -> MPRemoteCommandHandlerStatus {
    let manager = AudiobookSessionManager.shared.manager
    Log.info(#file, "🎮 handleChangePlaybackRate(\(rate)x) - manager: \(manager != nil)")
    
    guard let manager = manager else {
      Log.warn(#file, "🎮 ChangePlaybackRate command received but no active manager")
      return .noActionableNowPlayingItem
    }
    
    if let playbackRate = PlaybackRate.allCases.min(by: {
      abs(PlaybackRate.convert(rate: $0) - rate) < abs(PlaybackRate.convert(rate: $1) - rate)
    }) {
      manager.audiobook.player.playbackRate = playbackRate
      Log.info(#file, "🎮 PlaybackRate changed to \(PlaybackRate.convert(rate: playbackRate))x")
    }
    return .success
  }
}

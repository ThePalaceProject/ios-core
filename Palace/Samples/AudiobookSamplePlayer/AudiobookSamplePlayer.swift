//
//  SamplePlayer.swift
//  Palace
//
//  Created by Maurice Carrier on 8/14/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine

enum AudiobookSamplePlayerState {
  case initialized
  case loading
  case paused
  case playing
}

class AudiobookSamplePlayer: NSObject, ObservableObject {

  @Published var remainingTime = 0.0
  @Published var isLoading = false
  @Published var state: AudiobookSamplePlayerState = .initialized {
    didSet {
      DispatchQueue.main.async {
        self.isLoading = self.state == .loading
      }
    }
  }

  private var sample: AudiobookSample
  private var player: AVAudioPlayer?
  private var timer: Timer?

  init(sample: AudiobookSample) {
    self.sample = sample
    super.init()

    configureAudioSession()
    downloadFile()
  }
  
  private func configureAudioSession() {
    // AVAudioSession configuration MUST be done on the main thread to avoid -50 errors
    let configure: () -> Void = {
      do {
        let session = AVAudioSession.sharedInstance()
        // Only set category if it's different to avoid unnecessary operations
        if session.category != .playback || session.mode != .spokenAudio {
          try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowAirPlay])
        }
        // Only activate if not already playing audio elsewhere
        if !session.isOtherAudioPlaying {
          try session.setActive(true)
        }
      } catch let error as NSError {
        // Error -50 (kAudio_ParamError) is a known issue that can occur during
        // audio session configuration in certain app states. Don't spam Crashlytics
        // with these recoverable errors - log at debug level instead.
        // -50 = kAudio_ParamError, 560557684 = kAudioServicesNoHardwareError
        let knownRecoverableErrors: Set<Int> = [-50, 560557684]
        if knownRecoverableErrors.contains(error.code) {
          Log.debug(#file, "Audio session configuration deferred: \(error.localizedDescription)")
        } else {
      TPPErrorLogger.logError(error, summary: "Failed to set audio session category")
        }
      }
    }
    
    if Thread.isMainThread {
      configure()
    } else {
      DispatchQueue.main.async { configure() }
    }
  }

  deinit {
    self.timer?.invalidate()
    timer = nil
    self.player?.stop()
    self.player = nil
  }

  func playAudiobook() throws {
    player?.play()
    state = .playing
  }

  private func setupPlayer(data: Data) throws {
    player = try AVAudioPlayer(data: data)

    player?.delegate = self
    player?.volume = 1.0
    startTimer()
    player?.play()
    state = .playing
  }

  func pauseAudiobook() {
    player?.pause()
    state = .paused
  }

  func goBack() {
    guard let player = player, player.currentTime > 0 else { return }
    timer?.invalidate()

    self.player?.pause()
    let currentTime = remainingTime
    let newLocation = min(player.duration, currentTime + 30)
    remainingTime = newLocation
    self.player?.play(atTime: remainingTime)
    startTimer()
  }

  @objc private func setDuration() {
    guard let player = player,
          player.currentTime < player.duration
    else { return }

    DispatchQueue.main.async {
      self.remainingTime = player.duration - player.currentTime
    }
  }

  private func startTimer() {
    timer?.invalidate()
    timer = nil

    timer = Timer.scheduledTimer(
      timeInterval: 1.0,
      target: self,
      selector: #selector(setDuration),
      userInfo: nil,
      repeats: true
    )
  }

  private func downloadFile() {
    state = .loading

    let _ = sample.fetchSample { [weak self]  result in
      guard let self = self else { return }

      switch result {
      case let .failure(error, _):
        TPPErrorLogger.logError(error, summary: "Failed to download sample")
        return
      case let .success(result, _):
        DispatchQueue.main.async {
          try? self.setupPlayer(data: result)
        }
      }
    }
  }
}

extension AudiobookSamplePlayer: AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    state = .paused
  }
}

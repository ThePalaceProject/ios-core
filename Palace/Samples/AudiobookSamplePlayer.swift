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

    downloadFile()
  }

  deinit {
    self.timer?.invalidate()
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
    self.timer = Timer.scheduledTimer(
      timeInterval: 1.0,
      target: self,
      selector: #selector(setDuration),
      userInfo: nil,
      repeats: true
    )
  }

  private func downloadFile() {
    state = .loading

    let _ = TPPNetworkExecutor.shared.GET(sample.url) { [unowned self]  result in
      switch result {
      case let .failure(error, _):
        // TODO: Surface error and display alert
        TPPErrorLogger.logError(error, summary: "Failed to download sample")
        return
      case let .success(result, _):
        DispatchQueue.main.async {
          self.state = .paused
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

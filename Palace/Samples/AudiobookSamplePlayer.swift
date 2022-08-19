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
  @Published var state: AudiobookSamplePlayerState = .initialized {
    didSet {
      DispatchQueue.main.async {
        self.isLoading = self.state == .loading
      }
    }
  }
  @Published var isLoading = false

  private var sample: AudiobookSample
  private var player: AVAudioPlayer?
  private var sampleData: Data?
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

  // TODO: Handle error here
  private func downloadFile() {
    state = .loading

    let _ = TPPNetworkExecutor.shared.GET(sample.url) { [unowned self]  result,_,_ in
      DispatchQueue.main.async {
        self.state = .paused
        self.sampleData = result
        try? self.setupPlayer()
      }
    }
  }

  func playAudiobook() throws {
    player?.play()
    state = .playing
  }

  private func setupPlayer() throws {
    guard let sampleData = sampleData else {
      throw SamplePlayerError.sampleDownloadFailed(nil)
    }

    player = try AVAudioPlayer(data: sampleData)

    player?.delegate = self
    player?.prepareToPlay()
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
    let newLocation = min(player.duration, self.remainingTime + 30)
    remainingTime = newLocation
    self.player?.play(atTime: remainingTime)
    startTimer()
  }

  @objc private func setDuration() {
    guard let player = player else { return }

    DispatchQueue.main.async {
      self.remainingTime = min(abs(player.duration - player.currentTime), player.duration)
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
}

extension AudiobookSamplePlayer: AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    state = .paused
  }
}

//
//  SamplePlayer.swift
//  Palace
//
//  Created by Maurice Carrier on 8/14/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

@preconcurrency import AVFoundation
import Combine
import PalaceLogging

enum AudiobookSamplePlayerState {
    case initialized
    case loading
    case paused
    case playing
}

// `@MainActor`: `AudiobookSamplePlayer` is an `ObservableObject` whose
// `@Published` state (`state`, `remainingTime`, `isLoading`) is only ever
// observed from SwiftUI (`AudiobookSampleToolbar` holds it as `@ObservedObject`,
// itself owned by the `@MainActor SamplePreviewManager`). Every existing state
// mutation already hopped to main via `DispatchQueue.main.async`, so isolating
// the type is behavior-preserving and removes the manual hops. The framework
// delegate callbacks (`AVAudioPlayerDelegate`, the `Timer` selector) are all
// delivered on the main run loop because the player and timer are created on
// main (see `setupPlayer(data:)` / `startTimer()`).
@MainActor
class AudiobookSamplePlayer: NSObject, ObservableObject {

    @Published var remainingTime = 0.0
    @Published var isLoading = false
    @Published var state: AudiobookSamplePlayerState = .initialized {
        didSet {
            isLoading = state == .loading
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
        let configure: @Sendable () -> Void = {
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

    // `isolated deinit` (SE-0371, Xcode 26 / Swift 6.2): the class is
    // `@MainActor`, so `timer` and `player` are main-actor-isolated,
    // non-Sendable stored properties. A plain nonisolated `deinit` cannot touch
    // them, and `MainActor.assumeIsolated` in a deinit is banned (deinit is not
    // guaranteed to run on the main thread). Isolating the deinit lets it clean
    // up the timer and player on the main actor exactly as before.
    isolated deinit {
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

        // The Timer fires on the main run loop (scheduled on main), so we are
        // already on the main actor here. Compute the new value now — capturing
        // the non-Sendable `AVAudioPlayer` inside a `@Sendable` main-hop closure
        // would be a concurrency violation — then assign directly.
        remainingTime = player.duration - player.currentTime
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
        Log.debug(#file, "Downloading sample from: \(sample.url.absoluteString)")

        _ = sample.fetchSample { [weak self]  result in
            guard let self = self else { return }

            switch result {
            case let .failure(error, _):
                Log.error(#file, "Sample download failed for \(self.sample.url): \(error.localizedDescription)")
                TPPErrorLogger.logError(error, summary: "Failed to download sample")
                DispatchQueue.main.async { self.state = .paused }
                return
            case let .success(data, _):
                DispatchQueue.main.async {
                    do {
                        try self.setupPlayer(data: data)
                    } catch {
                        Log.error(#file, "Sample player setup failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

// `@preconcurrency`: `AVAudioPlayerDelegate` requirements are nonisolated, but
// AVFoundation delivers this callback on the run loop where the player was
// created — here always the main run loop (`setupPlayer(data:)` runs inside a
// `DispatchQueue.main.async`). Satisfying the nonisolated requirement with a
// main-actor-isolated method is therefore safe; `@preconcurrency` silences the
// isolation-mismatch warning without changing the (main-thread) call behavior.
extension AudiobookSamplePlayer: @preconcurrency AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        state = .paused
    }
}

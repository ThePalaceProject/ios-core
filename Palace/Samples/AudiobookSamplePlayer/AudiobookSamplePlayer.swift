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

/// The playback calls the sample player makes. `AVAudioPlayer` provides them
/// as is; tests pass a fake so position handling runs without audio.
protocol SampleAudioEngine: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: SampleAudioEngine {}

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

    private var sample: any Sample & Sendable
    private var player: (any SampleAudioEngine)?
    private var timer: Timer?
    private let makeEngine: (Data, AVAudioPlayerDelegate) throws -> any SampleAudioEngine

    init(
        sample: any Sample & Sendable,
        makeEngine: @escaping (Data, AVAudioPlayerDelegate) throws -> any SampleAudioEngine = AudiobookSamplePlayer.makeAudioPlayer
    ) {
        self.sample = sample
        self.makeEngine = makeEngine
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

    nonisolated static func makeAudioPlayer(data: Data, delegate: AVAudioPlayerDelegate) throws -> any SampleAudioEngine {
        let player = try AVAudioPlayer(data: data)
        player.delegate = delegate
        player.volume = 1.0
        return player
    }

    private func setupPlayer(data: Data) throws {
        player = try makeEngine(data, self)
        startTimer()
        player?.play()
        state = .playing
    }

    func pauseAudiobook() {
        player?.pause()
        state = .paused
    }

    nonisolated static let skipBackInterval: TimeInterval = 30

    /// Where the playhead lands after a skip back from `currentTime`: never
    /// before the start of the preview.
    nonisolated static func skipBackTarget(from currentTime: TimeInterval) -> TimeInterval {
        max(0, currentTime - skipBackInterval)
    }

    /// Moves the playhead back and keeps playing or paused as it was (PP-4027).
    /// Seeks through `currentTime`: `AVAudioPlayer.play(atTime:)` schedules a
    /// start on the device clock and does not move the playhead.
    func goBack() {
        guard let player else { return }
        player.currentTime = Self.skipBackTarget(from: player.currentTime)
        remainingTime = player.duration - player.currentTime
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

        // Awaited, so both arms resume on this `@MainActor` type and neither
        // needs the `DispatchQueue.main.async` they used to carry (PP-5301).
        //
        // `[weak self]` with a re-check after the suspension, matching what the
        // completion handler did. Holding `self` across the fetch would keep a
        // dismissed sample player alive to reach `setupPlayer` and start
        // playing audio for a sheet the patron already closed. Only the sample
        // itself is held across the await, as the closure did.
        Task { @MainActor [weak self] in
            guard let sample = self?.sample else { return }

            let result = await sample.fetchSample()

            guard let self else { return }
            switch result {
            case let .failure(error, _):
                Log.error(#file, "Sample download failed for \(sample.url): \(error.localizedDescription)")
                TPPErrorLogger.logError(error, summary: "Failed to download sample")
                self.state = .paused
            case let .success(data, _):
                do {
                    try self.setupPlayer(data: data)
                } catch {
                    Log.error(#file, "Sample player setup failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// `@preconcurrency`: `AVAudioPlayerDelegate` requirements are nonisolated, but
// AVFoundation delivers this callback on the run loop where the player was
// created — here always the main run loop (`setupPlayer(data:)` runs inside the
// `Task { @MainActor }` in `downloadFile()`; it was a `DispatchQueue.main.async`
// until PP-5301). Satisfying the nonisolated requirement with a
// main-actor-isolated method is therefore safe; `@preconcurrency` silences the
// isolation-mismatch warning without changing the (main-thread) call behavior.
extension AudiobookSamplePlayer: @preconcurrency AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        state = .paused
    }
}

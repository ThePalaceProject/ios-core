import Combine
import Foundation
import ReadiumNavigator
import ReadiumShared

class TPPTextToSpeech: ObservableObject {
  private let publication: Publication
  private let navigator: Navigator
  private let synthesizer: TPPPublicationSpeechSynthesizer

  @Published private(set) var isPlaying: Bool = false
  @Published private(set) var playingUtterance: Locator?

  private let playingWordRangeSubject = PassthroughSubject<Locator, Never>()

  private var subscriptions: Set<AnyCancellable> = []

  /// Actor to manage isMoving state for thread safety
  actor MovingState {
    private(set) var isMoving = false

    func startMoving() {
      isMoving = true
    }

    func stopMoving() {
      isMoving = false
    }

    func getIsMoving() -> Bool {
      isMoving
    }
  }

  private let movingState = MovingState()

  /// Initialize text-to-speech engine
  init?(navigator: Navigator, publication: Publication) {
    guard let synthesizer = TPPPublicationSpeechSynthesizer(publication: publication) else {
      return nil
    }
    self.synthesizer = synthesizer
    self.navigator = navigator
    self.publication = publication

    synthesizer.delegate = self

    // Highlight currently spoken utterance.
    setupHighlighting(for: navigator)

    // Navigate to the currently spoken utterance word.
    setupWordNavigation(for: navigator)
  }

  // MARK: - Public API

  func start(from startLocator: Locator? = nil) {
    if let locator = startLocator {
      synthesizer.start(from: locator)
    } else if let navigator = navigator as? VisualNavigator {
      // Gets the locator of the element at the top of the page.
      Task {
        if let locator = await navigator.firstVisibleElementLocator() {
          synthesizer.start(from: locator)
        }
      }
    } else {
      synthesizer.start(from: navigator.currentLocation)
    }
  }

  @objc func stop() {
    synthesizer.stop()
  }

  @objc func pauseOrResume() {
    synthesizer.pauseOrResume()
  }

  @objc func pause() {
    synthesizer.pause()
  }

  @objc func previous() {
    synthesizer.previous()
  }

  @objc func next() {
    synthesizer.next()
  }

  // MARK: - Private Helpers

  private func setupHighlighting(for navigator: Navigator) {
    guard let navigator = navigator as? DecorableNavigator else { return }

    $playingUtterance
      .removeDuplicates()
      .sink { locator in
        var decorations: [Decoration] = []
        if let locator = locator {
          decorations.append(
            Decoration(
              id: "tts-utterance",
              locator: locator,
              style: .highlight(tint: .red)
            )
          )
        }
        navigator.apply(decorations: decorations, in: "tts")
      }
      .store(in: &subscriptions)
  }

  private func setupWordNavigation(for navigator: Navigator) {
    playingWordRangeSubject
      .removeDuplicates()
      .throttle(for: 1, scheduler: RunLoop.main, latest: true)
      .sink { [weak self] locator in
        guard let self = self else { return }
        Task {
          let isCurrentlyMoving = await self.movingState.getIsMoving()
          guard !isCurrentlyMoving else { return }

          await self.movingState.startMoving()
          await self.navigator.go(to: locator, options: NavigatorGoOptions(animated: true))
          await self.movingState.stopMoving()
        }
      }
      .store(in: &subscriptions)
  }
}

extension TPPTextToSpeech: TPPPublicationSpeechSynthesizerDelegate {
  func publicationSpeechSynthesizer(
    _ synthesizer: TPPPublicationSpeechSynthesizer,
    stateDidChange synthesizerState: TPPPublicationSpeechSynthesizer.State
  ) {
    Task { @MainActor in
      switch synthesizerState {
      case .stopped:
        self.isPlaying = false
        self.playingUtterance = nil

      case let .playing(utterance, range: wordRange):
        self.isPlaying = true
        self.playingUtterance = utterance.locator
        if let wordRange = wordRange {
          self.playingWordRangeSubject.send(wordRange)
        }

      case let .paused(utterance):
        self.isPlaying = false
        self.playingUtterance = utterance.locator
      }
    }
  }
}

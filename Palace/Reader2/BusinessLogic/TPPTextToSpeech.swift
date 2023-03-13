//
//  TPPTextToSpeech.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02/03/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import R2Navigator
import R2Shared

class TPPTextToSpeech: ObservableObject {
  
  struct State: Equatable {
    /// Whether the TTS was enabled by the user.
    var showControls: Bool = false
    /// Whether the TTS is currently speaking.
    var isPlaying: Bool = false
  }
  
  struct Settings: Equatable {
    /// Currently selected user preferences.
    let config: PublicationSpeechSynthesizer.Configuration
    /// Languages supported by the synthesizer.
    let availableLanguages: [Language]
    /// Voices supported by the synthesizer, for the selected language.
    let availableVoiceIds: [String]
    
    init(synthesizer: PublicationSpeechSynthesizer) {
      let voicesByLanguage: [Language: [TTSVoice]] =
      Dictionary(grouping: synthesizer.availableVoices, by: \.language)
      
      self.config = synthesizer.config
      self.availableLanguages = voicesByLanguage.keys.sorted { $0.localizedDescription() < $1.localizedDescription() }
      self.availableVoiceIds = synthesizer.config.defaultLanguage
        .flatMap { voicesByLanguage[$0]?.map { $0.identifier } }
      ?? []
    }
  }
  
  @Published private(set) var state: State = State()
  @Published private(set) var settings: Settings
  
  private let publication: Publication
  private let navigator: Navigator
  private let synthesizer: PublicationSpeechSynthesizer
  private let initialLocator: Locator?
  
  @Published private(set) var playingUtterance: Locator?
  private let playingWordRangeSubject = PassthroughSubject<Locator, Never>()
  
  private var subscriptions: Set<AnyCancellable> = []
  
  init?(navigator: Navigator, publication: Publication, initialLocator: Locator? = nil) {
    guard let synthesizer = PublicationSpeechSynthesizer(publication: publication) else {
      return nil
    }
    self.synthesizer = synthesizer
    self.settings = Settings(synthesizer: synthesizer)
    self.navigator = navigator
    self.publication = publication
    self.initialLocator = initialLocator
    
    synthesizer.delegate = self
    
    // Highlight the currently spoken utterance.
    if let navigator = navigator as? DecorableNavigator {
      $playingUtterance
        .removeDuplicates()
        .sink { locator in
          var decorations: [Decoration] = []
          if let locator = locator {
            decorations.append(Decoration(
              id: "tts-utterance",
              locator: locator,
              style: .highlight(tint: .red)
            ))
          }
          navigator.apply(decorations: decorations, in: "tts")
        }
        .store(in: &subscriptions)
    }
    
    // Navigate to the currently spoken utterance word.
    // This will automatically turn pages when needed.
    var isMoving = false
    playingWordRangeSubject
      .removeDuplicates()
    //  Improve performances by throttling the moves to maximum one per second.
      .throttle(for: 1, scheduler: RunLoop.main, latest: true)
      .drop(while: { _ in isMoving })
      .sink { locator in
        isMoving = navigator.go(to: locator) {
          isMoving = false
        }
      }
      .store(in: &subscriptions)
    
  }
  
  func setConfig(_ config: PublicationSpeechSynthesizer.Configuration) {
    synthesizer.config = config
    settings = Settings(synthesizer: synthesizer)
  }
  
  func voiceWithIdentifier(_ id: String) -> TTSVoice? {
    synthesizer.voiceWithIdentifier(id)
  }
  
  @objc func start() {
    if let navigator = navigator as? VisualNavigator {
      if let locator = initialLocator {
        synthesizer.start(from: locator)
      } else {
        // Gets the locator of the element at the top of the page.
        navigator.firstVisibleElementLocator { [self] locator in
          synthesizer.start(from: locator)
          // Verify it started playing;
          // synthesizer doesn't start when `locator` contains incompatible data
          // In this case we start from the beginning of the page.
          switch synthesizer.state {
          case .stopped: synthesizer.start(from: navigator.currentLocation)
          default: break
          }
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
}

extension TPPTextToSpeech: PublicationSpeechSynthesizerDelegate {
  
  public func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, stateDidChange synthesizerState: PublicationSpeechSynthesizer.State) {
    switch synthesizerState {
    case .stopped:
      state.showControls = false
      state.isPlaying = false
      playingUtterance = nil
      
    case let .playing(utterance, range: wordRange):
      state.showControls = true
      state.isPlaying = true
      playingUtterance = utterance.locator
      if let wordRange = wordRange {
        playingWordRangeSubject.send(wordRange)
      }
      
    case let .paused(utterance):
      state.showControls = true
      state.isPlaying = false
      playingUtterance = utterance.locator
    }
  }
  
  public func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, utterance: PublicationSpeechSynthesizer.Utterance, didFailWithError error: PublicationSpeechSynthesizer.Error) {
    TPPErrorLogger.logError(error, summary: "Text To Speech Error")
  }
}

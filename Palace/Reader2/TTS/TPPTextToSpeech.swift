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
  
  private let publication: Publication
  private let navigator: Navigator
  private let synthesizer: TPPPublicationSpeechSynthesizer

  @Published private(set) var isPlaying: Bool = false
  @Published private(set) var playingUtterance: Locator?

  private let playingWordRangeSubject = PassthroughSubject<Locator, Never>()
  
  private var subscriptions: Set<AnyCancellable> = []
  
  /// Initialize text-to-speech engine
  /// - Parameters:
  ///   - navigator: Readium Navigator object
  ///   - publication: Readium Publication object
  ///   - locator: initial locator
  init?(navigator: Navigator, publication: Publication) {
    guard let synthesizer = TPPPublicationSpeechSynthesizer(publication: publication) else {
      return nil
    }
    self.synthesizer = synthesizer
    self.navigator = navigator
    self.publication = publication
    
    synthesizer.delegate = self
    
    // Highlight currently spoken utterance.
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
  
  func start(from startLocator: Locator? = nil) {
    if let locator = startLocator {
      synthesizer.start(from: locator)
    } else if let navigator = navigator as? VisualNavigator {
      // Gets the locator of the element at the top of the page.
      navigator.firstVisibleElementLocator { [self] locator in
        synthesizer.start(from: locator)
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

extension TPPTextToSpeech: TPPPublicationSpeechSynthesizerDelegate {
  
  public func publicationSpeechSynthesizer(_ synthesizer: TPPPublicationSpeechSynthesizer, stateDidChange synthesizerState: TPPPublicationSpeechSynthesizer.State) {
    switch synthesizerState {
    case .stopped:
      self.isPlaying = false
      playingUtterance = nil
      
    case let .playing(utterance, range: wordRange):
      self.isPlaying = true
      playingUtterance = utterance.locator
      if let wordRange = wordRange {
        playingWordRangeSubject.send(wordRange)
      }
      
    case let .paused(utterance):
      self.isPlaying = false
      playingUtterance = utterance.locator
    }
  }
  
}

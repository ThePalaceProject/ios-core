//
//  TPPPublicationSpeechSynthesizer.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16/03/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import R2Shared
import R2Navigator
import AVFoundation
import Combine

public protocol TPPPublicationSpeechSynthesizerDelegate: AnyObject {
  /// Called when the synthesizer's state is updated.
  func publicationSpeechSynthesizer(_ synthesizer: TPPPublicationSpeechSynthesizer, stateDidChange state: TPPPublicationSpeechSynthesizer.State)
  
  /// Called when an `error` occurs while speaking `utterance`.
  func publicationSpeechSynthesizer(_ synthesizer: TPPPublicationSpeechSynthesizer, utterance: TPPPublicationSpeechSynthesizer.Utterance, didFailWithError error: TPPPublicationSpeechSynthesizer.Error)
}

/// `PublicationSpeechSynthesizer` orchestrates the rendition of a `Publication` by iterating through its content,
/// splitting it into individual utterances using a `ContentTokenizer`, then using a `TTSEngine` to read them aloud.
public class TPPPublicationSpeechSynthesizer: NSObject, Loggable {

  public typealias TokenizerFactory = (_ defaultLanguage: Language?) -> ContentTokenizer
  
  /// Returns whether the `publication` can be played with a `PublicationSpeechSynthesizer`.
  public static func canSpeak(publication: Publication) -> Bool {
    publication.content() != nil
  }
  
  public enum Error: Swift.Error {
    /// Underlying `TTSEngine` error.
    case engine(TTSError)
  }
    
  /// An utterance is an arbitrary text (e.g. sentence) extracted from the publication, that can be synthesized by
  /// the TTS engine.
  public struct Utterance {
    /// Text to be spoken.
    public let text: String
    /// Locator to the utterance in the publication.
    public let locator: Locator
    /// Language of this utterance, if it dffers from the default publication language.
    public let language: Language?
  }
  
  /// Represents a state of the `PublicationSpeechSynthesizer`.
  public enum State {
    /// The synthesizer is completely stopped and must be (re)started from a given locator.
    case stopped
    
    /// The synthesizer is paused at the given utterance.
    case paused(Utterance)
    
    /// The TTS engine is synthesizing the associated utterance.
    /// `range` will be regularly updated while the utterance is being played.
    case playing(Utterance, range: Locator?)
  }
  
  /// Current state of the `PublicationSpeechSynthesizer`.
  public private(set) var state: State = .stopped {
    didSet {
      delegate?.publicationSpeechSynthesizer(self, stateDidChange: state)
    }
  }
  
  public weak var delegate: TPPPublicationSpeechSynthesizerDelegate?
  
  private let publication: Publication
  private let tokenizerFactory: TokenizerFactory
  private let synthesizer: AVSpeechSynthesizer
  private var voiceOverAnnouncementCancellable: AnyCancellable?
  
  /// Creates a `PublicationSpeechSynthesizer` using the given `TTSEngine` factory.
  ///
  /// Returns null if the publication cannot be synthesized.
  ///
  /// - Parameters:
  ///   - publication: Publication which will be iterated through and synthesized.
  ///   - config: Initial TTS configuration.
  ///   - engineFactory: Factory to create an instance of `TtsEngine`. Defaults to `AVTTSEngine`.
  ///   - tokenizerFactory: Factory to create a `ContentTokenizer` which will be used to
  ///     split each `ContentElement` item into smaller chunks. Splits by sentences by default.
  ///   - delegate: Optional delegate.
  public init?(
    publication: Publication,
    tokenizerFactory: @escaping TokenizerFactory = defaultTokenizerFactory,
    delegate: TPPPublicationSpeechSynthesizerDelegate? = nil
  ) {
    guard Self.canSpeak(publication: publication) else {
      return nil
    }
    
    self.publication = publication
    self.tokenizerFactory = tokenizerFactory
    self.delegate = delegate
    self.synthesizer = AVSpeechSynthesizer()
    super.init()

    self.synthesizer.delegate = self
    self.voiceOverAnnouncementCancellable = NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)
      .receive(on: RunLoop.main)
      .sink { _ in
        self.didFinishUtterance()
      }
      
  }
  
  /// The default content tokenizer will split the `Content.Element` items into individual sentences.
  public static let defaultTokenizerFactory: TokenizerFactory = { defaultLanguage in
    makeTextContentTokenizer(
      defaultLanguage: defaultLanguage,
      contextSnippetLength: 50,
      textTokenizerFactory: { language in
        makeDefaultTextTokenizer(unit: .sentence, language: language)
      }
    )
  }
  
  /// (Re)starts the synthesizer from the given locator or the beginning of the publication.
  public func start(from locator: Locator? = nil) {
    publicationIterator = publication.content(from: locator)?.iterator()
    playNextUtterance(.forward)
  }
  
  /// Stops the synthesizer.
  ///
  /// Use `start()` to restart it.
  public func stop() {
    if UIAccessibility.isVoiceOverRunning {
      UIAccessibility.post(notification: .announcement, argument: nil)
    } else {
      synthesizer.stopSpeaking(at: .immediate)
    }
    state = .stopped
    publicationIterator = nil
  }
  
  /// Interrupts a played utterance.
  ///
  /// Use `resume()` to restart the playback from the same utterance.
  public func pause() {
    if UIAccessibility.isVoiceOverRunning {
      UIAccessibility.post(notification: .announcement, argument: nil)
    } else {
      synthesizer.pauseSpeaking(at: .immediate)
    }
    if case let .playing(utterance, range: _) = state {
      state = .paused(utterance)
    }
  }
  
  /// Resumes an utterance interrupted with `pause()`.
  public func resume() {
    if case let .paused(utterance) = state {
      if UIAccessibility.isVoiceOverRunning {
        if let previousUtterance = nextUtterance(.backward) {
          play(previousUtterance)
        } else {
          play(utterance)
        }
      } else if synthesizer.isPaused {
        synthesizer.continueSpeaking()
      } else {
        playNextUtterance(.forward)
      }
      state = .playing(utterance, range: nil)
    }
  }
  
  /// Pauses or resumes the playback of the current utterance.
  public func pauseOrResume() {
    switch state {
    case .stopped: return
    case .playing: pause()
    case .paused: resume()
    }
  }
  
  /// Skips to the previous utterance.
  public func previous() {
    playNextUtterance(.backward)
  }
  
  /// Skips to the next utterance.
  public func next() {
    playNextUtterance(.forward)
  }
  
  /// `Content.Iterator` used to iterate through the `publication`.
  private var publicationIterator: ContentIterator? = nil {
    didSet {
      utterances = CursorList()
    }
  }
  
  /// Utterances for the current publication `ContentElement` item.
  private var utterances: CursorList<Utterance> = CursorList()
  
  /// Plays the next utterance in the given `direction`.
  private func playNextUtterance(_ direction: Direction) {
    guard let utterance = nextUtterance(direction) else {
      state = .stopped
      return
    }
    play(utterance)
  }
  
  /// Plays the given `utterance` with the TTS `engine`.
  private func play(_ utterance: Utterance) {
    
    if let range = utterance.text.range(of: utterance.text) {
      state = .playing(utterance, range: utterance.locator.copy(text: { $0 = utterance.locator.text[range] } ))
    } else {
      state = .playing(utterance, range: nil)
    }

    if UIAccessibility.isVoiceOverRunning {
      UIAccessibility.post(notification: .announcement, argument: utterance.text)
    } else {
      let avUtterance = AVSpeechUtterance(string: utterance.text)
      synthesizer.speak(avUtterance)
    }
  }
    
  /// Gets the next utterance in the given `direction`, or null when reaching the beginning or the end.
  private func nextUtterance(_ direction: Direction) -> Utterance? {
    guard let utterance = utterances.next(direction) else {
      if loadNextUtterances(direction) {
        return nextUtterance(direction)
      }
      return nil
    }
    return utterance
  }
  
  /// Loads the utterances for the next publication `ContentElement` item in the given `direction`.
  private func loadNextUtterances(_ direction: Direction) -> Bool {
    do {
      guard let content = try publicationIterator?.next(direction) else {
        return false
      }
      
      let nextUtterances = try tokenize(content)
        .flatMap { utterances(for: $0) }
      
      if nextUtterances.isEmpty {
        return loadNextUtterances(direction)
      }
      
      utterances = CursorList(
        list: nextUtterances,
        startIndex: {
          switch direction {
          case .forward: return 0
          case .backward: return nextUtterances.count - 1
          }
        }()
      )
      
      return true
      
    } catch {
      log(.error, error)
      return false
    }
  }
  
  /// Splits a publication `ContentElement` item into smaller chunks using the provided tokenizer.
  ///
  /// This is used to split a paragraph into sentences, for example.
  func tokenize(_ element: ContentElement) throws -> [ContentElement] {
    let tokenizer = tokenizerFactory(publication.metadata.language)
    return try tokenizer(element)
  }
  
  /// Splits a publication `ContentElement` item into the utterances to be spoken.
  private func utterances(for element: ContentElement) -> [Utterance] {
    func utterance(text: String, locator: Locator, language: Language? = nil) -> Utterance? {
      guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
        return nil
      }
      
      return Utterance(
        text: text,
        locator: locator,
        language: language
        // If the language is the same as the one declared globally in the publication,
        // we omit it. This way, the app can customize the default language used in the
        // configuration.
          .takeIf { $0 != publication.metadata.language }
      )
    }
    
    switch element {
    case let element as TextContentElement:
      return element.segments
        .compactMap { segment in
          utterance(text: segment.text, locator: segment.locator, language: segment.language)
        }
      
    case let element as TextualContentElement:
      guard let text = element.text.takeIf({ !$0.isEmpty }) else {
        return []
      }
      return Array(ofNotNil: utterance(text: text, locator: element.locator))
      
    default:
      return []
    }
  }
  
  private func didFinishUtterance() {
    switch self.state {
    case .playing(_, range: _): self.playNextUtterance(.forward)
    default: break
    }
    
  }
}

extension TPPPublicationSpeechSynthesizer: AVSpeechSynthesizerDelegate {
  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    self.didFinishUtterance()
  }
}

private enum Direction {
  case forward, backward
}


/// A `List` with a mutable cursor index.
struct CursorList<Element> {
  private let list: [Element]
  private let startIndex: Int
  
  init(list: [Element] = [], startIndex: Int = 0) {
    self.list = list
    self.startIndex = startIndex
  }
  
  private var index: Int? = nil
  
  /// Returns the current element.
  mutating func current() -> Element? {
    moveAndGet(index ?? startIndex)
  }
  
  /// Moves the cursor backward and returns the element, or null when reaching the beginning.
  mutating func previous() -> Element? {
    moveAndGet(index.map { $0 - 1 } ?? startIndex)
  }
  
  /// Moves the cursor forward and returns the element, or null when reaching the end.
  mutating func next() -> Element? {
    moveAndGet(index.map { $0 + 1 } ?? startIndex)
  }
  
  private mutating func moveAndGet(_ index: Int) -> Element? {
    guard list.indices.contains(index) else {
      return nil
    }
    self.index = index
    return list[index]
  }
}

private extension CursorList {
  mutating func next(_ direction: Direction) -> Element? {
    switch direction {
    case .forward:
      return next()
    case .backward:
      return previous()
    }
  }
}

private extension ContentIterator {
  func next(_ direction: Direction) throws -> ContentElement? {
    switch direction {
    case .forward:
      return try next()
    case .backward:
      return try previous()
    }
  }
}

/// An utterance is an arbitrary text (e.g. sentence) that can be synthesized by the TTS engine.
public struct TTSUtterance {
  /// Text to be spoken.
  public let text: String
  
  /// Delay before speaking the utterance, in seconds.
  public let delay: TimeInterval
  
  /// Either an explicit voice or the language of the text. If a language is provided, the default voice for this
  /// language will be used.
  public let voiceOrLanguage: Either<TTSVoice, Language>
  
  public var language: Language {
    switch voiceOrLanguage {
    case .left(let voice):
      return voice.language
    case .right(let language):
      return language
    }
  }
}

//
//  JSONDecoderGuardedTests.swift
//  PalaceTests
//
//  `JSONDecoder` traps instead of throwing when an object KEY is malformed, so
//  no caller can catch it. These pin the screen that turns each of those inputs
//  into an ordinary error, and pin that it is off wherever the decoder already
//  throws (PP-5412).
//

import PalaceNetwork
import XCTest

final class JSONDecoderGuardedTests: XCTestCase {

  private struct Payload: Decodable, Equatable {
    let a: Int
    let b: String
  }

  /// A model that reads one field and ignores the rest.
  ///
  /// Not "how the OPDS2 models behave" — those read many fields. It is the
  /// narrow case where the screen and the decoder disagree at all: the decoder
  /// validates a value when a container asks for it, so a malformed value in an
  /// unread member survives it. In a field the model declares, the decoder
  /// rejects these same inputs, measured.
  private struct Feed: Decodable, Equatable {
    let title: String
  }

  /// The five shapes that reach the trap, all in a top-level key position.
  ///
  /// They trap only where the decoder builds that container's key set, which
  /// any model declaring a field does for the top level.
  ///
  /// Only the last is invalid UTF-8. The other four are well-formed UTF-8, which
  /// is why validating the encoding does not close this: it would admit four of
  /// the five.
  private static let malformedKeys: [(name: String, data: Data)] = [
    ("unknown escape letter", Data(#"{"a\qb":1}"#.utf8)),
    ("non-hex \\u digits", Data(#"{"a\uZZZZb":1}"#.utf8)),
    ("lone high surrogate", Data(#"{"a\uD800b":1}"#.utf8)),
    ("raw control byte", Data([0x7b, 0x22, 0x61, 0x01, 0x62, 0x22, 0x3a, 0x31, 0x7d])),
    ("invalid UTF-8 byte", Data([0x7b, 0x22, 0x61, 0xff, 0x62, 0x22, 0x3a, 0x31, 0x7d]))
  ]

  /// Inputs the decoder accepts but the screen rejects, each in a part of the
  /// document `Feed` never touches. Measured, not assumed.
  ///
  /// These are why the screen is gated rather than unconditional. Four are bad
  /// values in an unread member; the fifth is a bad KEY inside a sub-object the
  /// model never opens, because a key is only validated in a keyed container
  /// the decoder actually builds. Move any of them into a field or a sub-object
  /// the model declares and the decoder rejects it too, so the cost of
  /// screening falls on the part of a document nothing reads.
  private static let screenRejectsButDecoderAccepts: [(name: String, data: Data)] = [
    ("lone surrogate in a value", Data(#"{"title":"T","blurb":"\uD800"}"#.utf8)),
    ("lone surrogate nested", Data(#"{"title":"T","meta":{"x":"a\uD834b"}}"#.utf8)),
    ("exponent out of range", Data(#"{"title":"T","score":1e400}"#.utf8)),
    ("number with a leading zero", Data(#"{"title":"T","copies":01}"#.utf8)),
    ("malformed key in an unopened sub-object", Data(#"{"title":"T","meta":{"a\qb":1}}"#.utf8))
  ]

  // MARK: - The screen rejects every trapping input

  /// Each malformed key is rejected, and rejected as an ordinary error.
  ///
  /// `screenExternalJSON` is tested directly because `decodeGuarded` does not
  /// call it on this runtime. The `underlyingError` is asserted so the error is
  /// traceable to the screen rather than to anything else that throws
  /// `dataCorrupted`.
  func test_screenExternalJSON_rejectsEveryMalformedObjectKey() {
    // Asserted so an emptied vector list fails rather than passing vacuously.
    XCTAssertEqual(Self.malformedKeys.count, 5, "every trapping shape must still be covered")
    for vector in Self.malformedKeys {
      do {
        try JSONDecoder.screenExternalJSON(vector.data)
        XCTFail("\(vector.name): must be rejected; on iOS 18.0-18.3 the decoder traps on this")
      } catch let DecodingError.dataCorrupted(context) {
        // Deliberately not `try XCTUnwrap`: that throws out of the method and
        // would abort the loop, so vectors after the first would lose their own
        // evidence in exactly the regression where the underlying error goes
        // missing.
        guard let underlying = context.underlyingError as NSError? else {
          XCTFail("\(vector.name): must carry the parse error, or something else rejected it")
          continue
        }
        XCTAssertEqual(underlying.domain, NSCocoaErrorDomain, "\(vector.name)")
        XCTAssertEqual(underlying.code, 3840, "\(vector.name): NSCocoaErrorDomain 3840 is a JSON parse error")
      } catch {
        XCTFail("\(vector.name): must throw DecodingError.dataCorrupted, threw \(error)")
      }
    }
  }

  /// Valid JSON passes the screen, including a top-level fragment.
  ///
  /// Fragments have to pass: several feeds answer a bare string or number, and a
  /// stricter screen would refuse bytes the decoder accepts.
  func test_screenExternalJSON_acceptsValidJSON_includingFragments() throws {
    try JSONDecoder.screenExternalJSON(Data(#"{"a":7,"b":"seven"}"#.utf8))
    try JSONDecoder.screenExternalJSON(Data("7".utf8))
    try JSONDecoder.screenExternalJSON(Data(#""x""#.utf8))
  }

  /// The screen refuses five shapes the decoder would have skipped.
  ///
  /// Recorded so the cost is stated rather than discovered. On iOS 18.0 through
  /// 18.3 a document carrying any of these in a member no model reads is
  /// refused instead of decoded.
  func test_screenExternalJSON_alsoRejectsFiveShapesTheDecoderWouldSkip() {
    XCTAssertEqual(Self.screenRejectsButDecoderAccepts.count, 5, "the cost of the screen is stated by these five")
    for vector in Self.screenRejectsButDecoderAccepts {
      XCTAssertThrowsError(try JSONDecoder.screenExternalJSON(vector.data),
                           "\(vector.name): expected the screen to refuse this")
    }
  }

  // MARK: - The decoder's own behaviour, which sets the cost

  /// Each of those five decodes today, so the screen is what would refuse them.
  ///
  /// Without this the previous test proves only that the screen is strict, not
  /// that the strictness costs anything.
  func test_theDecoder_acceptsThoseFiveShapes_whenNothingReadsThatPart() {
    XCTAssertEqual(Self.screenRejectsButDecoderAccepts.count, 5, "the negative control must cover the same five")
    for vector in Self.screenRejectsButDecoderAccepts {
      XCTAssertEqual(try? JSONDecoder().decode(Feed.self, from: vector.data), Feed(title: "T"),
                     "\(vector.name): the fixture must be one the decoder accepts, or it proves nothing")
    }
  }

  /// Moved into a field the model reads, the decoder rejects them itself.
  ///
  /// This is the measurement the gate rests on: the screen's cost is confined to
  /// members nothing reads, because anything a model consumes is already
  /// validated.
  func test_theDecoder_rejectsAMalformedValue_onceAModelReadsThatField() {
    XCTAssertThrowsError(try JSONDecoder().decode(Feed.self, from: Data(#"{"title":"Lost \uD800 here"}"#.utf8))) { error in
      // `dataCorrupted` rather than merely non-nil: that separates "the decoder
      // refused it" from "it decoded to something else".
      guard case DecodingError.dataCorrupted = error else {
        return XCTFail("the decoder must refuse it outright, got \(error)")
      }
    }
  }

  // MARK: - The production entry point

  /// `decodeGuarded` screens exactly when `prescreensExternalJSON` says to.
  ///
  /// Called in its production shape, with no override, so this is what pins the
  /// default. A default changed to screen always would fail here on this
  /// runtime, and that change is the one that would narrow feeds for every
  /// patron on a fixed iOS.
  func test_decodeGuarded_screensExactlyWhenTheRuntimeNeedsIt() throws {
    // A payload the decoder accepts and the screen refuses.
    let divergent = Data(#"{"title":"T","blurb":"\uD800"}"#.utf8)

    if JSONDecoder.prescreensExternalJSON {
      XCTAssertThrowsError(try JSONDecoder().decodeGuarded(Feed.self, from: divergent),
                           "screening runtimes refuse this, which is the documented price there")
    } else {
      XCTAssertEqual(try JSONDecoder().decodeGuarded(Feed.self, from: divergent), Feed(title: "T"),
                     "the decoder throws by itself here, so the screen must be off and feeds must not narrow")
    }
  }

  /// The flag is off exactly from iOS 18.4, stated independently of the flag.
  ///
  /// The two tests above and both call-site tests all read
  /// `prescreensExternalJSON` to decide what to expect, so widening it to `true`
  /// everywhere would pass all of them while narrowing feeds for every patron on
  /// a current iOS. This is the only assertion that witnesses the constant
  /// itself. It restates the boundary rather than computing it, deliberately:
  /// the referent is external — the upstream fix (rdar://133742708) shipped in
  /// Swift 6.1 and so in iOS 18.4 — and the condition it encodes is
  /// trap-versus-throw, which cannot be probed in-process because the trapping
  /// side takes the process with it.
  func test_prescreensExternalJSON_isOffFromTheRuntimeThatCarriesTheUpstreamFix() {
    if #available(iOS 18.4, *) {
      XCTAssertFalse(JSONDecoder.prescreensExternalJSON,
                     "this runtime's decoder throws, so the screen must be off and feeds must not narrow")
    } else {
      XCTAssertTrue(JSONDecoder.prescreensExternalJSON,
                    "this runtime's decoder traps, so the screen must run")
    }
  }

  /// Valid JSON decodes to the same value either way.
  func test_decodeGuarded_withValidJSON_matchesTheUnguardedDecoder() throws {
    let data = Data(#"{"a":7,"b":"seven"}"#.utf8)

    let guarded = try JSONDecoder().decodeGuarded(Payload.self, from: data)

    XCTAssertEqual(guarded, try JSONDecoder().decode(Payload.self, from: data))
    XCTAssertEqual(guarded, Payload(a: 7, b: "seven"))
  }

  // MARK: - Errors callers already handle keep their shape

  /// A type mismatch still arrives as `typeMismatch`, not as the screen's error.
  ///
  /// `UserProfileDocument` and `TokenRequest` branch on the `DecodingError`
  /// case, so wrapping every failure as `dataCorrupted` would change what a
  /// patron is told about a feed the app simply disagrees with.
  func test_decodeGuarded_whenAValueHasTheWrongType_stillReportsTypeMismatch() {
    let data = Data(#"{"a":"not a number","b":"x"}"#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decodeGuarded(Payload.self, from: data)) { error in
      guard case DecodingError.typeMismatch = error else {
        return XCTFail("must stay a typeMismatch so callers can still branch on it, got \(error)")
      }
    }
  }

  /// A missing field still arrives as `keyNotFound`.
  func test_decodeGuarded_whenAFieldIsMissing_stillReportsKeyNotFound() {
    let data = Data(#"{"a":1}"#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decodeGuarded(Payload.self, from: data)) { error in
      guard case DecodingError.keyNotFound = error else {
        return XCTFail("must stay a keyNotFound, got \(error)")
      }
    }
  }
}

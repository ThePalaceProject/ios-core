//
//  AudiobookPlaybackFailureRecord.swift
//  Palace
//
//  The Crashlytics non-fatal recorded for an audiobook `.playbackFailed`, and the
//  decision whether to send it at all (PP-5242).
//
//  What the record has to carry, and why:
//
//  - The underlying error chain. When an `AVAssetResourceLoader` delegate fails a
//    request, `AVPlayerItem.error` replaces the delegate's domain: code -1001
//    becomes `NSURLErrorDomain` -1001, anything else becomes
//    `AVFoundationErrorDomain` -11800. The delegate's original code survives only
//    as `NSUnderlyingError` (`NSOSStatusErrorDomain`, same code). The top-level
//    domain/code alone therefore cannot tell one LCP loader failure from another.
//  - The content source (LCP streamed vs local, OverDrive, Findaway, open access),
//    because one Crashlytics issue groups failures from all of them.
//  - Whether the failure happened at the start of a track.
//  - The interval since the previous failure for the same book, so a follow-up
//    failure (a media-services reset followed within a second by the player's
//    own "not ready" failure) can be identified without being hidden.
//
//  Moved out of `AudiobookSessionManager.swift`, which is under the god-class
//  LOC freeze. The builder and the send decision are pure so they are tested
//  directly; the hub keeps only the call and the state it already owns.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit
import PalaceCatalog
import PalaceBookModel
import PalaceLogging

// MARK: - Content source

/// Where the failing player was reading audio from.
enum AudiobookContentSource: String {
    case lcpStreamed
    case lcpLocal
    case overdrive
    case findaway
    case openAccess
    case unknown

    /// Pure classification over what the session manager knows once an audiobook
    /// is bound.
    ///
    /// - Parameters:
    ///   - hasDecryptor: `loaded.decryptor != nil`. Only `LCPAdapter` supplies a
    ///     decryptor, so this is the same LCP test `PlaybackOpenPolicy` uses.
    ///   - lcpContentIsLocal: whether the `.lcpa` package was on disk when the
    ///     audiobook was bound — the same file-exists test `LCPAdapter` uses to
    ///     choose the local package over streaming from the license.
    ///   - overdriveDistributorKey: `OverdriveDistributorKey` where OverDrive is
    ///     compiled in, `nil` otherwise (Palace-noDRM).
    static func classify(
        book: TPPBook?,
        hasDecryptor: Bool,
        lcpContentIsLocal: Bool,
        overdriveDistributorKey: String?
    ) -> AudiobookContentSource {
        guard let book else { return .unknown }
        if hasDecryptor {
            return lcpContentIsLocal ? .lcpLocal : .lcpStreamed
        }
        if let overdriveDistributorKey,
           book.distributor?.lowercased() == overdriveDistributorKey.lowercased() {
            return .overdrive
        }
        // Findaway is either the acquisition itself or, in the OPDS-catalog and
        // OPDS-publication feed shapes, its direct child — the only positions
        // `TPPOPDSAcquisitionPath.supportedSubtypes` allows it in.
        if let acquisition = book.defaultAcquisition,
           acquisition.type == ContentTypeFindaway
            || acquisition.indirectAcquisitions.contains(where: { $0.type == ContentTypeFindaway }) {
            return .findaway
        }
        return .openAccess
    }
}

// MARK: - Repeat suppression

/// Decides whether a playback failure is a repeat that should not be recorded
/// again. Value type with the time passed in, so it is tested without a clock.
///
/// A failure is a repeat when the same
/// (book, domain, code, underlying domain, underlying code) was seen within
/// `repeatWindow` of the latest occurrence. The window slides:
/// every occurrence, recorded or not, extends it.
///
/// Why 60 seconds, sliding: field data shows devices re-reporting the same
/// failure every 30 seconds, and bursts of 50 records in under 50ms. A window
/// longer than the 30s cadence is needed to catch the re-reports at all, and
/// measuring it from the latest occurrence (not the first record) keeps a
/// sustained re-report to one record instead of one per window. A failure that
/// recurs after a minute of quiet is recorded again.
///
/// Failures with a different code for the same book are always recorded, even
/// when they arrive a moment after another failure: some of those are follow-ups
/// of the first failure, but a different code can also be a different cause, and
/// suppressing it would hide that. The same reasoning applies one level down,
/// which is why the key carries the first `NSUnderlyingError` too — under
/// AVFoundation the top-level code is usually the same `-11800` regardless of
/// cause, so keying on it alone would suppress precisely the distinctions this
/// record was added to capture. `secondsSincePreviousFailureForBook` lets a
/// reader identify the follow-ups instead.
struct PlaybackFailureRecordDeduplicator {

    static let repeatWindow: TimeInterval = 60

    struct Decision: Equatable {
        let shouldRecord: Bool
        /// Time since the previous failure (any code) for the same book, when that
        /// failure was within `repeatWindow`.
        let secondsSincePreviousFailureForBook: TimeInterval?
    }

    private struct Key: Hashable {
        let bookId: String
        let domain: String
        let code: Int
        /// The first level of the `NSUnderlyingError` chain, when the error has
        /// one. Without it the key is the field this whole change exists
        /// because it cannot discriminate: AVFoundation collapses every
        /// resource-loader failure into `AVFoundationErrorDomain -11800`, so two
        /// genuinely different causes on the same book would share a key and the
        /// second would be dropped with its chain unread. That is a worse
        /// outcome than today, where both at least arrive generically.
        let underlyingDomain: String?
        let underlyingCode: Int?
    }

    private var lastSeenByKey: [Key: Date] = [:]
    private var lastFailureByBook: [String: Date] = [:]

    /// Number of (book, domain, code, underlying domain, underlying code)
    /// entries still held. Exposed so a test can assert that expired entries do
    /// not accumulate.
    var trackedKeyCount: Int { lastSeenByKey.count }

    mutating func evaluate(
        bookId: String,
        domain: String,
        code: Int,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil,
        at now: Date
    ) -> Decision {
        let window = Self.repeatWindow
        lastSeenByKey = lastSeenByKey.filter { now.timeIntervalSince($0.value) < window }
        lastFailureByBook = lastFailureByBook.filter { now.timeIntervalSince($0.value) < window }

        let key = Key(
            bookId: bookId,
            domain: domain,
            code: code,
            underlyingDomain: underlyingDomain,
            underlyingCode: underlyingCode
        )
        let isRepeat = lastSeenByKey[key] != nil
        let sincePrevious = lastFailureByBook[bookId].map { now.timeIntervalSince($0) }

        lastSeenByKey[key] = now
        lastFailureByBook[bookId] = now
        return Decision(shouldRecord: !isRepeat, secondsSincePreviousFailureForBook: sincePrevious)
    }
}

// MARK: - Record

extension AudiobookSessionManager {

    /// How many levels of `NSUnderlyingErrorKey` the record follows. Three covers
    /// the observed AVFoundation → OSStatus → CoreMedia shape with room to spare;
    /// the bound keeps a pathological chain from producing an unbounded record.
    nonisolated static let maxUnderlyingErrorDepth = 3

    /// Builds a Crashlytics-ready NSError describing an audiobook playback
    /// failure, with all available context (typed error code, HTTP status,
    /// track URL, book id, position, underlying error chain, content source).
    /// Pure — straight-line unit testable without spinning up the audiobook
    /// stack. `nonisolated` because no app/state is read; lets tests call it off
    /// the MainActor.
    ///
    /// `underlyingDomain`/`underlyingCode` hold the TOP-LEVEL error's domain and
    /// code (their names predate this change and dashboards depend on them). The
    /// `NSUnderlyingError` chain is recorded as `underlyingErrorDomain`/
    /// `underlyingErrorCode`, then `…2`, `…3` for deeper levels.
    nonisolated static func buildPlaybackFailureRecord(
        error: Error?,
        position: TrackPosition?,
        bookId: String?,
        contentSource: AudiobookContentSource = .unknown,
        secondsSincePreviousFailureForBook: TimeInterval? = nil
    ) -> NSError {
        var userInfo: [String: Any] = [
            "bookId": bookId ?? "unknown",
            "trackTitle": position?.track.title ?? "unknown",
            "trackPosition": position.map { "\($0.timestamp)" } ?? "unknown",
            "contentSource": contentSource.rawValue,
            "atTrackStart": (position?.timestamp ?? 0) == 0 ? "true" : "false",
        ]
        if let trackUrl = position?.track.urls?.first?.absoluteString {
            userInfo["trackUrl"] = trackUrl
        }
        if let secondsSincePreviousFailureForBook {
            userInfo["msSincePreviousFailureForBook"] = Int((secondsSincePreviousFailureForBook * 1000).rounded())
        }
        userInfo.merge(errorCauseFields(error)) { _, cause in cause }
        let message = "Audiobook playback failed: \(error?.localizedDescription ?? "no underlying error")"
        userInfo[NSLocalizedDescriptionKey] = message
        return NSError(
            domain: "org.thepalaceproject.palace.audiobookPlayback",
            code: (error as NSError?)?.code ?? -1,
            userInfo: userInfo
        )
    }

    /// The cause fields shared by the playback-failure record and the
    /// open-failure metadata: `underlyingDomain`/`underlyingCode` for `error`
    /// itself, the allow-listed `httpStatusCode`/`trackKey`/`url` from its
    /// userInfo, and `underlyingErrorDomain`/`underlyingErrorCode` (then `…2`,
    /// `…3`) for its `NSUnderlyingError` chain. Empty for a nil error.
    nonisolated static func errorCauseFields(_ error: Error?) -> [String: Any] {
        guard let nsError = error as NSError? else { return [:] }
        var fields: [String: Any] = [
            "underlyingDomain": nsError.domain,
            "underlyingCode": nsError.code,
        ]
        for (key, value) in nsError.userInfo {
            let stringKey = key as String
            guard ["httpStatusCode", "trackKey", "url"].contains(stringKey) else { continue }
            fields[stringKey] = value
        }
        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        var level = 1
        while let current = underlying, level <= maxUnderlyingErrorDepth {
            let suffix = level == 1 ? "" : "\(level)"
            fields["underlyingErrorDomain\(suffix)"] = current.domain
            fields["underlyingErrorCode\(suffix)"] = current.code
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            level += 1
        }
        return fields
    }

    /// Metadata for the open-failure non-fatal logged by
    /// `BookService.showAudiobookTryAgainError`. That report keeps its fixed
    /// domain and code (existing grouping); this adds which loader step failed
    /// (`loadError`), the content source, and the cause fields of the error the
    /// step carried. `underlyingDomain`/`underlyingCode` here describe that
    /// carried error, since the load error itself is a Swift enum with no
    /// useful domain.
    nonisolated static func openFailureMetadata(
        loadError: AudiobookLoadError,
        contentSource: AudiobookContentSource
    ) -> [String: Any] {
        var metadata = errorCauseFields(loadError.underlyingError)
        metadata["loadError"] = loadError.caseName
        metadata["contentSource"] = contentSource.rawValue
        if case .factoryFailed(let manifestType?) = loadError {
            metadata["manifestType"] = manifestType
        }
        return metadata
    }

    /// The content source to record for a failure of `failingBookId`: the bound
    /// source when it belongs to that book, `.unknown` otherwise.
    nonisolated static func contentSource(
        bound: (bookId: String, source: AudiobookContentSource)?,
        failingBookId: String
    ) -> AudiobookContentSource {
        guard let bound, bound.bookId == failingBookId else { return .unknown }
        return bound.source
    }

    /// The record to send for this failure, or `nil` when it repeats one seen
    /// within `PlaybackFailureRecordDeduplicator.repeatWindow`. Pure over the
    /// deduplicator it is handed.
    ///
    /// A nil `bookId` is keyed as its own book so it is never suppressed against
    /// a real one. A nil error is keyed by the same sentinel code (-1) the record
    /// uses.
    nonisolated static func playbackFailureRecordToSend(
        error: Error?,
        position: TrackPosition?,
        bookId: String?,
        contentSource: AudiobookContentSource,
        deduplicator: inout PlaybackFailureRecordDeduplicator,
        now: Date
    ) -> NSError? {
        let nsError = error as NSError?
        let firstUnderlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
        let decision = deduplicator.evaluate(
            bookId: bookId ?? "unknown",
            domain: nsError?.domain ?? "none",
            code: nsError?.code ?? -1,
            underlyingDomain: firstUnderlying?.domain,
            underlyingCode: firstUnderlying?.code,
            at: now
        )
        guard decision.shouldRecord else { return nil }
        return buildPlaybackFailureRecord(
            error: error,
            position: position,
            bookId: bookId,
            contentSource: contentSource,
            secondsSincePreviousFailureForBook: decision.secondsSincePreviousFailureForBook
        )
    }

    /// Content source for the audiobook being bound. Evaluated at bind time, not
    /// at failure time: a streaming LCP book can have its `.lcpa` land in the
    /// background mid-session (PP-5135), and a check at failure time would then
    /// label a streaming failure as local.
    static func contentSourceForBinding(book: TPPBook, decryptor: AnyObject?) -> AudiobookContentSource {
        contentSource(for: book, isLCP: PlaybackOpenPolicy.decideForLoad(decryptor: decryptor).bypassReadinessGate)
    }

    /// Content source for an audiobook that failed to open, so no decryptor
    /// exists. Uses the same LCP test the open path's content gate uses
    /// (`LCPAudiobooks.canOpenBook`) and the same `.lcpa` file-exists test.
    static func contentSourceForOpen(book: TPPBook) -> AudiobookContentSource {
#if LCP
        return contentSource(for: book, isLCP: LCPAudiobooks.canOpenBook(book))
#else
        return contentSource(for: book, isLCP: false)
#endif
    }

    /// `contentIsLocal` is injected so the `hasDecryptor && …` conjunction below
    /// is reachable from a test. It defaults to the production file-exists check,
    /// which reads `AppContainer.production()` and is therefore not drivable from
    /// a unit test — which is exactly why mutating that `&&` to `||` survived the
    /// suite: with `||` short-circuiting on `hasDecryptor`, every LCP book would
    /// report `.lcpLocal` and the streamed/local split — the most valuable
    /// distinction in this field, with streaming at 100% in production — would
    /// silently vanish.
    static func contentSource(
        for book: TPPBook,
        isLCP hasDecryptor: Bool,
        contentIsLocal: (String) -> Bool = { audiobookContentIsLocal($0) }
    ) -> AudiobookContentSource {
#if FEATURE_OVERDRIVE
        let overdriveKey: String? = OverdriveDistributorKey
#else
        let overdriveKey: String? = nil
#endif
        return AudiobookContentSource.classify(
            book: book,
            hasDecryptor: hasDecryptor,
            lcpContentIsLocal: hasDecryptor && contentIsLocal(book.identifier),
            overdriveDistributorKey: overdriveKey
        )
    }

    /// Sends a built record to PalaceLogging + the Crashlytics non-fatal sink.
    static func sendPlaybackFailureRecord(_ nonFatal: NSError) {
        Log.error(#file, "Recording audiobook playback non-fatal: \(nonFatal)")
        FirebaseManager.shared.logError(nonFatal)
    }
}


// MARK: - Load error description

extension AudiobookLoadError {
    /// The case name without its payload, e.g. `lcpDecryptionFailed`.
    var caseName: String {
        Mirror(reflecting: self).children.first?.label ?? String(describing: self)
    }

    /// The error a case carries, if any.
    var underlyingError: Error? {
        switch self {
        case .tokenRefreshFailed(let error),
             .lcpDecryptionFailed(let error),
             .licenseDownloadFailed(let error):
            return error
        case .licenseSaveFailed(let error),
             .manifestDecodingFailed(let error):
            return error
        case .vendorKeyUpdateFailed(let error):
            return error
        case .cancelled, .missingCredentialsForTokenRefresh, .lcpNotAvailable,
             .lcpInstantiationFailed, .missingFulfillURL, .missingContentDirectory,
             .manifestFetchFailed, .manifestParseFailed, .manifestSerializationFailed,
             .factoryFailed:
            return nil
        }
    }
}

//
//  LCPAudiobooks.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 16.11.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#if LCP

import Foundation
import PalaceLogging
import PalaceCatalog
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
@preconcurrency import ReadiumLCP
@preconcurrency import PalaceAudiobookToolkit

/// - Sendable invariant: instances are safe to share across concurrency
///   domains (they are captured by the `@Sendable` closures
///   `publicationCacheQueue.async`/`DispatchQueue.global().async` schedules,
///   and by the decrypt/load `Task`s) because:
///   1. Every stored dependency (`audiobookUrl`, `licenseUrl`,
///      `assetRetriever`, `publicationOpener`, `httpClient`,
///      `publicationCacheQueue`) is a `let` — immutable after `init`.
///   2. Every piece of mutable state (`cachedPublication`,
///      `currentPrefetchTask`, `isReleased`) is read and written ONLY through
///      the serial `publicationCacheQueue` (`.sync`/`.async`). No mutable
///      property is touched off that queue, so there is no unsynchronized
///      shared mutation.
///   `final` keeps the invariant intact — a subclass cannot add
///   unsynchronized stored state. Hence `@unchecked Sendable` rather than a
///   compiler-checked conformance (the Readium dependency types are not
///   Sendable-audited).
@objc final class LCPAudiobooks: NSObject, @unchecked Sendable {

    private static let expectedAcquisitionType = "application/vnd.readium.lcp.license.v1.0+json"

    private let audiobookUrl: AbsoluteURL
    private let licenseUrl: URL?
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener
    private let httpClient: LCPCredentialStrippingHTTPClient

    private var cachedPublication: Publication?
    private let publicationCacheQueue = DispatchQueue(label: "org.thepalaceproject.lcpaudiobooks.publicationcache")
    private var currentPrefetchTask: Task<Void, Never>?

    /// Once set, the instance is a dead one-shot: no new Publication may be opened
    /// through contentDictionary, decrypt, or startPrefetch. A previously opened
    /// Publication held via cachedPublication has already been dropped.
    ///
    /// Why: a stale AudiobookManager's decryptor chain could otherwise race the
    /// next audiobook's publicationOpener.open() on the same .lcpa, which
    /// deadlocks inside Readium and surfaces as the "opening third audiobook
    /// hangs" bug.
    private var isReleased: Bool = false

    /// Initialize for an LCP audiobook
    /// - Parameter audiobookUrl: can be a local `.lcpa` package URL OR an `.lcpl` license URL for streaming
    /// - Parameter licenseUrl: optional license URL for streaming authentication (deprecated, use audiobookUrl)
    @objc init?(for audiobookUrl: URL, licenseUrl: URL? = nil) {

        if let fileUrl = FileURL(url: audiobookUrl) {
            self.audiobookUrl = fileUrl
        } else if let httpUrl = HTTPURL(url: audiobookUrl) {
            self.audiobookUrl = httpUrl
        } else {
            return nil
        }

        self.licenseUrl = licenseUrl ?? (audiobookUrl.pathExtension.lowercased() == "lcpl" ? audiobookUrl : nil)

        let httpClient = LCPCredentialStrippingHTTPClient()
        self.httpClient = httpClient
        self.assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let contentProtection = lcpService.contentProtection else {
            return nil
        }

        let parser = DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )

        self.publicationOpener = PublicationOpener(
            parser: parser,
            contentProtections: [contentProtection]
        )
    }

    @objc func contentDictionary(completion: @escaping (_ json: NSDictionary?, _ error: NSError?) -> Void) {
        if isReleasedSnapshot() {
            DispatchQueue.main.async {
                completion(nil, Self.releasedError())
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.loadContentDictionary { json, error in
                DispatchQueue.main.async {
                    completion(json, error)
                }
            }
        }
    }

    private func isReleasedSnapshot() -> Bool {
        publicationCacheQueue.sync { isReleased }
    }

    private static func releasedError() -> NSError {
        NSError(
            domain: "Palace.LCPAudiobooks",
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "LCPAudiobooks instance has been released"]
        )
    }

    private func loadContentDictionary(completion: @escaping (_ json: NSDictionary?, _ error: NSError?) -> Void) {
        if isReleasedSnapshot() {
            completion(nil, Self.releasedError())
            return
        }

        publicationCacheQueue.async {
            self.currentPrefetchTask?.cancel()
        }

        let task = Task { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            if self.isReleasedSnapshot() {
                completion(nil, Self.releasedError())
                return
            }

            var urlToOpen: AbsoluteURL = audiobookUrl
            if let licenseUrl {
                if let fileUrl = FileURL(url: licenseUrl) {
                    urlToOpen = fileUrl
                } else if let httpUrl = HTTPURL(url: licenseUrl) {
                    urlToOpen = httpUrl
                } else {
                    completion(nil, NSError(domain: "LCPAudiobooks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid license URL"]))
                    return
                }
            }

            let result = await assetRetriever.retrieve(url: urlToOpen)

            switch result {
            case .success(let asset):
                if Task.isCancelled { return }

                var credentials: String?
                if let licenseUrl = licenseUrl, licenseUrl.isFileURL {
                    credentials = try? String(contentsOf: licenseUrl)
                }

                let result = await publicationOpener.open(asset: asset, allowUserInteraction: true, credentials: credentials, sender: nil)

                switch result {
                case .success(let publication):

                    if Task.isCancelled { return }
                    self.publicationCacheQueue.async {
                        self.cachedPublication = publication
                    }

                    if let jsonManifestString = publication.jsonManifest, let jsonData = jsonManifestString.data(using: .utf8),
                       let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
                        completion(jsonObject, nil)
                    } else {
                        let links = publication.readingOrder.map { link in
                            let hrefString = String(describing: link.href)
                            let typeString = link.mediaType.map { String(describing: $0) } ?? "audio/mpeg"
                            return [
                                "href": hrefString,
                                "type": typeString
                            ]
                        }
                        let minimal: [String: Any] = [
                            "metadata": [
                                "identifier": UUID().uuidString,
                                "title": String(describing: publication.metadata.title)
                            ],
                            "readingOrder": links
                        ]
                        completion(minimal as NSDictionary, nil)
                    }
                case .failure(let error):
                    completion(nil, LCPAudiobooks.nsError(for: error))
                }

            case .failure(let error):
                completion(nil, LCPAudiobooks.nsError(for: error))
            }

            self.publicationCacheQueue.async {
                if self.currentPrefetchTask?.isCancelled == true { self.currentPrefetchTask = nil }
            }
        }

        publicationCacheQueue.async {
            self.currentPrefetchTask = task
        }
    }

    /// Check if the book is LCP audiobook. Delegates to `hasLCPAcquisition(_:)`
    /// so all three OPDS feed shapes (`/loans/` XML, `/groups/` JSON, and the
    /// OPDS-catalog wrapping shape) resolve correctly — PP-4407 / PP-4454.
    /// - Parameter book: audiobook
    /// - Returns: `true` if the book is an LCP DRM protected audiobook, `false` otherwise
    @objc static func canOpenBook(_ book: TPPBook) -> Bool {
        return hasLCPAcquisition(book)
    }

    /// Returns `true` iff `book` is an LCP-protected audiobook, regardless of
    /// which OPDS feed shape Marketplace happened to populate it from. Unlike
    /// `canOpenBook(_:)` — which only matches the `/loans/` XML shape that
    /// places the LCP MIME at the top of `defaultAcquisition.type` — this
    /// predicate also walks `indirectAcquisitions[*].type` recursively so the
    /// `/groups/` JSON feed shape (top-level `application/opds-publication+json`
    /// with the LCP license nested one or more levels deep) is caught.
    ///
    /// This is the load-bearing fix for the PP-4407 regression class. Ported
    /// from the 3.0.3 hotfix commit `ca2ff13b6`, which only landed on the
    /// 3.0.x release branch and was never forward-merged to develop. The
    /// `defaultBookContentType == .audiobook` clause is required so LCP-typed
    /// EPUBs and PDFs do NOT match here — only audiobooks.
    @objc static func hasLCPAcquisition(_ book: TPPBook) -> Bool {
        guard book.defaultBookContentType == .audiobook,
              let acquisition = book.defaultAcquisition else {
            return false
        }
        if acquisition.type == expectedAcquisitionType {
            return true
        }
        return indirectChainContainsLCP(acquisition.indirectAcquisitions)
    }

    private static func indirectChainContainsLCP(_ chain: [TPPOPDSIndirectAcquisition]) -> Bool {
        for node in chain {
            if node.type == expectedAcquisitionType {
                return true
            }
            if indirectChainContainsLCP(node.indirectAcquisitions) {
                return true
            }
        }
        return false
    }

    /// Creates an NSError for Objective-C code
    /// - Parameter error: Error object
    /// - Returns: NSError object
    private static func nsError(for error: Error) -> NSError {
        return NSError(domain: "Palace.LCPAudiobooks", code: 0, userInfo: [
            NSLocalizedDescriptionKey: error.localizedDescription,
            "Error": error
        ])
    }
}

extension LCPAudiobooks: LCPStreamingProvider {

    public func getPublication() -> Publication? {
        return publicationCacheQueue.sync {
            return cachedPublication
        }
    }

    public func supportsStreaming() -> Bool {
        return true
    }

    public func setupStreamingFor(_ player: Any) -> Bool {
        guard let streamingPlayer = player as? StreamingCapablePlayer else {
            return false
        }
        if isReleasedSnapshot() {
            return false
        }
        streamingPlayer.setStreamingProvider(self)

        let hasPublication = publicationCacheQueue.sync {
            return cachedPublication != nil
        }

        if hasPublication {
            // Publication is already loaded (the loader's contentDictionary call
            // cached it). Signal the player right away so it doesn't wait on the
            // 30s "Publication loading timeout" fallback. Without this, every
            // back-to-back LCP audiobook open creates a fresh LCPStreamingPlayer
            // whose isLoaded flag can only flip via publicationDidLoad() — which
            // otherwise only fires from the !hasPublication branch below.
            DispatchQueue.main.async {
                streamingPlayer.publicationDidLoad()
            }
        } else {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.loadContentDictionary { _, error in
                    if let error = error {
                        Log.error(#file, "Failed to load LCP publication for streaming: \(error)")
                    } else {
                        Log.info(#file, "Successfully loaded LCP publication for streaming")

                        DispatchQueue.main.async {
                            streamingPlayer.publicationDidLoad()
                        }
                    }
                }
            }
        }

        return true
    }

}

// MARK: - Cached manifest access
extension LCPAudiobooks {
    /// Returns the cached content dictionary if the publication has already been opened.
    /// This avoids re-opening the asset and enables immediate UI presentation.
    public func cachedContentDictionary() -> NSDictionary? {
        let publication = publicationCacheQueue.sync {
            return cachedPublication
        }

        guard let publication, let jsonManifestString = publication.jsonManifest,
              let jsonData = jsonManifestString.data(using: .utf8) else {
            return nil
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? NSDictionary {
            return jsonObject
        }
        return nil
    }

    public func startPrefetch() {
        if isReleasedSnapshot() { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.loadContentDictionary { _, _ in
            }
        }
    }

    func decrypt(url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
        if isReleasedSnapshot() {
            completion(Self.releasedError())
            return
        }
        if let publication = getPublication() {
            decryptWithPublication(publication, url: url, to: resultUrl, completion: completion)
            return
        }
        // No cached publication means this decryptor's session has ended (either never
        // opened, or released). Do NOT reopen through publicationOpener — that raced
        // the next session's open on the same .lcpa and deadlocked Readium.
        completion(Self.releasedError())
    }

    private func decryptWithPublication(_ publication: Publication, url: URL, to resultUrl: URL, completion: @escaping (Error?) -> Void) {
        if let resource = publication.getResource(at: url.path) {
            // The completion originates from the toolkit's `@objc public
            // protocol DRMDecryptor` (off-limits submodule), so its parameter
            // type cannot be annotated `@Sendable`. We must still hand it to a
            // `DispatchQueue.main.async` closure (a strictly-`@Sendable`
            // boundary) to deliver the result on main. Wrap it once, before
            // entering the `Task`, so the `@Sendable` closures capture the
            // Sendable box rather than the bare non-Sendable closure.
            let completionBox = SendableDecryptCompletion(completion)
            Task {
                do {
                    let data = try await resource.read().get()
                    try data.write(to: resultUrl, options: .atomic)
                    DispatchQueue.main.async {
                        completionBox.fire(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        completionBox.fire(error)
                    }
                }
            }
        } else {
            completion(NSError(domain: "AudiobookResourceError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Resource not found at path: \(url.path)"]))
        }
    }

    public func cancelPrefetch() {
        publicationCacheQueue.sync {
            currentPrefetchTask?.cancel()
            currentPrefetchTask = nil
        }
    }

    /// Release all held resources and mark the instance as a dead one-shot.
    /// After this call, decrypt/contentDictionary/startPrefetch/setupStreamingFor
    /// all fail fast. Idempotent.
    public func releaseResources() {
        publicationCacheQueue.sync {
            isReleased = true
            currentPrefetchTask?.cancel()
            currentPrefetchTask = nil
            cachedPublication = nil
        }
    }
}

private extension Publication {
    func getResource(at path: String) -> Resource? {
        let resource = get(Link(href: path))
        guard type(of: resource) != FailureResource.self else {
            return get(Link(href: "/" + path))
        }

        return resource
    }
}

/// `Sendable` wrapper for a `DRMDecryptor.decrypt` completion closure.
///
/// The toolkit's `@objc public protocol DRMDecryptor` (in the off-limits
/// `PalaceAudiobookToolkit` submodule) types the completion as a plain
/// `(Error?) -> Void`, so it cannot be annotated `@Sendable` at the
/// conformance site without diverging from the `@objc` requirement. This box
/// lets the completion cross into the decrypt `Task`'s `DispatchQueue.main.async`
/// hop (a strictly-`@Sendable` boundary) without a concurrency warning.
///
/// - Sendable invariant: `fire(_:)` forwards to the wrapped closure exactly
///   once, always from a single `DispatchQueue.main.async` continuation in
///   `decryptWithPublication` (success XOR failure) — never concurrently from
///   two threads. The wrapped closure is otherwise opaque, hence `@unchecked`.
private struct SendableDecryptCompletion: @unchecked Sendable {
    private let completion: (Error?) -> Void

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func fire(_ error: Error?) {
        completion(error)
    }
}

#endif

import PalaceBookRegistry
//
//  LCPFulfillmentHandler.swift
//  Palace
//
//  Owns the LCP license-fulfillment + streaming-license-copy workflow that
//  lived inside MyBooksDownloadCenter for the `.lcp` rights-management
//  branch. Extracted so the LCP-specific logic (license rename, fulfillment
//  task wiring, audiobook streaming-license copy, PDF extract pass) can be
//  exercised in isolation with mocks of the file system and LCP service.
//
//  The whole class is gated on `#if LCP` because `LCPLibraryService`,
//  `TPPLCPLicense`, and `LCPPDFs` only compile in builds that include the
//  LCP stack. MyBooksDownloadCenter's `fulfillLCPLicense` method is also
//  gated, and only constructs/uses this handler under the same flag — so
//  Palace-noDRM continues to compile with this method as a no-op.
//

#if LCP

import Foundation
import PalaceLogging
import PalaceBookModel

// MARK: - LCPFulfillmentHandlerDelegate

/// Surface MBDC needs to expose for the handler to mark the book as
/// successfully downloaded once the LCP fulfillment + (for audiobooks)
/// streaming-license copy land. `markDownloadSuccessful` already exists on
/// MBDC at `internal` since commit 2; this protocol simply names it.
protocol LCPFulfillmentHandlerDelegate: AnyObject {
    func markDownloadSuccessful(for book: TPPBook)
}

// MARK: - LCPFulfillmentHandler

/// Renames the just-downloaded LCP license to `.lcpl`, kicks off the LCP
/// fulfillment task, and (for audiobooks) copies the license to the
/// streaming location alongside the audiobook content. Routes progress
/// through the shared DownloadProgressReporter and reports failures
/// through the shared DownloadAlertPresenter so the UI sees a single,
/// coherent download error stream regardless of which DRM produced it.
// @unchecked Sendable invariant: every stored dependency is a `let`
// (immutable after init). The only mutable member is `weak var delegate`,
// which is wired exactly once by MyBooksDownloadCenter during its own
// construction on the main thread and never reassigned. It is read from the
// fulfillment/progress callbacks' `MainActor.run` hops and from nonisolated
// callback bodies, but `weak var` loads / ARC-zeroing are runtime-serialized
// via the side-table lock, so reading it off-main is memory-safe. No stored
// value is mutated after init, so the handler is safe to share across the LCP
// fulfillment-task / progress-callback concurrency boundaries.
final class LCPFulfillmentHandler: @unchecked Sendable {

    weak var delegate: LCPFulfillmentHandlerDelegate?

    private let bookRegistry: TPPBookRegistryProvider
    private let stateManager: DownloadStateManager
    private let progressReporter: DownloadProgressReporter
    private let alertPresenter: DownloadAlertPresenter
    private let bookFileManager: BookFileManager
    private let backgroundDownloadHandler: BackgroundDownloadHandler
    private let fileManager: FileManager

    /// Factory closure so tests can inject an LCPLibraryService mock.
    /// Production callers leave the default which constructs a fresh
    /// service per fulfillment — same lifetime as the prior MBDC body.
    private let lcpServiceFactory: () -> LCPLibraryService

    init(
        bookRegistry: TPPBookRegistryProvider,
        stateManager: DownloadStateManager,
        progressReporter: DownloadProgressReporter,
        alertPresenter: DownloadAlertPresenter,
        bookFileManager: BookFileManager,
        backgroundDownloadHandler: BackgroundDownloadHandler,
        fileManager: FileManager = .default,
        lcpServiceFactory: @escaping () -> LCPLibraryService = { LCPLibraryService() }
    ) {
        self.bookRegistry = bookRegistry
        self.stateManager = stateManager
        self.progressReporter = progressReporter
        self.alertPresenter = alertPresenter
        self.bookFileManager = bookFileManager
        self.backgroundDownloadHandler = backgroundDownloadHandler
        self.fileManager = fileManager
        self.lcpServiceFactory = lcpServiceFactory
    }

    // MARK: - Fulfillment

    /// Renames the `.epub`/`.zip`/etc. that just landed at `fileUrl` to a
    /// `.lcpl` license file, asks LCPLibraryService to fulfill it, and
    /// wires progress + completion callbacks onto the shared progress
    /// reporter / alert presenter / background-download-handler.
    func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask) {
        let lcpService = lcpServiceFactory()
        let licenseUrl = fileUrl.deletingPathExtension().appendingPathExtension(lcpService.licenseExtension)

        do {
            _ = try fileManager.replaceItemAt(licenseUrl, withItemAt: fileUrl)
        } catch {
            TPPErrorLogger.logError(error, summary: "Error renaming LCP license file", metadata: [
                "fileUrl": fileUrl.absoluteString,
                "licenseUrl": licenseUrl.absoluteString,
                "book": book.loggableDictionary
            ])
            alertPresenter.failDownloadWithAlert(for: book, withMessage: error.localizedDescription)
            return
        }

        let lcpProgress: (Double) -> Void = { [weak self] progressValue in
            guard let self = self else { return }
            Task {
                if let info = await self.stateManager.bookIdentifierToDownloadInfo.get(book.identifier)?.withDownloadProgress(progressValue) {
                    await self.stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
                }
                // Through `sendProgress`, NOT straight to the publisher. That method
                // also HEARTBEATS the content-transfer registration, and this is the
                // only signal of life a `.lcpa` fetch produces: `downloadInfo` is
                // cleared ~100 ms into the phase, so the registration is all that
                // stands between a long download and a duplicate. Publishing
                // directly left it un-heartbeated, so it expired at the 180 s idle
                // mark and re-armed the second archive fetch — on every title
                // measured for this fix (438 MB / 778 MB / 1.9 GB), all of which
                // run past three minutes on an ordinary connection.
                self.progressReporter.sendProgress(bookIdentifier: book.identifier, progress: progressValue)
                self.progressReporter.broadcastUpdate()
            }
        }

        let lcpCompletion: (URL?, Error?) -> Void = { [weak self] localUrl, error in
            guard let self = self else { return }
            // `defer`, not a straight-line call, for two reasons. It releases the
            // registration on EVERY exit — this closure has four `return`s, and a
            // failed fulfillment that kept the flag would suppress the recovery
            // re-download it specifically depends on. And it runs AFTER
            // `replaceBook` has put the content on disk: clearing up front left a
            // window where the book was (license, no content, nothing in flight),
            // which is precisely the triple that makes reconciliation schedule a
            // duplicate download.
            defer {
                self.progressReporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: false)
            }
            if let error = error {
                let summary = "\(String(describing: book.distributor)) LCP license fulfillment error"
                TPPErrorLogger.logError(error, summary: summary, metadata: [
                    "book": book.loggableDictionary,
                    "licenseURL": licenseUrl.absoluteString,
                    "localURL": localUrl?.absoluteString ?? "N/A"
                ])

                // A `.lcpa` content-download failure — typically airplane mode
                // mid-fetch from googleapis.com — must NOT downgrade an
                // audiobook that ALREADY has playable content on disk. The
                // report that motivated this guard was on iPad: previously
                // downloaded audiobooks losing the Read/Listen affordance the
                // moment the device went offline.
                //
                // The state check is what distinguishes the two cases, and it
                // still does the right thing now that a first fulfillment stays
                // `.downloading` until content lands:
                //  - re-fulfillment of a book that already has content → state
                //    is `.downloadSuccessful`/`.used` → leave it alone.
                //  - first fulfillment whose content never arrived → state is
                //    `.downloading` → fall through and fail honestly, so the
                //    book does not sit in `.downloading` forever.
                // The old comment here claimed audiobooks were marked
                // `.downloadSuccessful` as soon as the license landed; that is
                // no longer the case (see the audiobook branch below).
                //
                // `.used` is included for future-proofing — audiobooks
                // don't transition through `.used` today (only PDFs do, see
                // TPPPDFDocumentMetadata), but mirroring the established
                // `(.downloadSuccessful || .used)` pattern from
                // BookReturnService keeps the guard correct if audiobook
                // playback ever wires through the open-once → `.used`
                // transition.
                // Test the DISK, not the registry state. The state test this
                // replaces only worked while the book had already been marked
                // `.downloadSuccessful` at license-fulfilled time; now that a
                // first fulfillment stays `.downloading`, the state at this
                // point is `.downloading` on every reachable path
                // (`DownloadTaskLifecycleService` sets it at task start, and
                // `DownloadStartCoordinator` refuses to start a download from
                // `.downloadSuccessful`/`.used`), so a state test would never
                // fire and would let a book that DOES have content on disk fall
                // through to `.downloadFailed` — which `BookRegistrySync` then
                // excludes from its file-existence heal, stranding a perfectly
                // good download behind a permanent Retry.
                //
                // What the guard is actually protecting is "this book already
                // has playable audio", so ask that question directly.
                let hasLocalContent = self.bookFileManager.fileUrl(for: book.identifier)
                    .map { self.fileManager.fileExists(atPath: $0.path) } ?? false
                if book.defaultBookContentType == .audiobook && hasLocalContent {
                    Log.warn(#file, "LCP audiobook content re-fetch failed but local content is intact — leaving '\(book.title)' (\(book.identifier)) alone")
                    return
                }

                let errorMessage = "Fulfilment Error: \(error.localizedDescription)"
                self.alertPresenter.failDownloadWithAlert(for: book, withMessage: errorMessage)
                return
            }
            guard let localUrl = localUrl,
                  let license = TPPLCPLicense(url: licenseUrl)
            else {
                let errorMessage = "Error with LCP license fulfillment: \(localUrl?.absoluteString ?? "")"
                self.alertPresenter.failDownloadWithAlert(for: book, withMessage: errorMessage)
                return
            }
            self.bookRegistry.setFulfillmentId(license.identifier, for: book.identifier)

            if !self.backgroundDownloadHandler.replaceBook(book, withFileAtURL: localUrl, forDownloadTask: downloadTask) {
                // Storing the content failed, so there is no playable audio on
                // disk and (with streaming broken) nothing to fall back to.
                // This used to warn and continue, leaving the book in the
                // `.downloadSuccessful` state it had been given early; now that
                // the book is still `.downloading`, continuing would strand it
                // there forever. Surface the failure so the patron can retry.
                let errorMessage = "Error replacing content file with file \(localUrl.absoluteString)"
                self.alertPresenter.failDownloadWithAlert(for: book, withMessage: errorMessage)
                return
            }

            if book.defaultBookContentType == .audiobook {
                Log.info(#file, "Audiobook content stored successfully — marking download successful: \(book.identifier)")
                self.delegate?.markDownloadSuccessful(for: book)
            }

            // PDF fulfillment: Readium's PDFNavigator streams decrypted
            // pages on demand via the shared GCDHTTPServer, so no eager
            // zip→temp extract is needed here. Just mark the book
            // successful once the LCP container + license are on disk.
            if book.defaultBookContentType == .pdf {
                self.delegate?.markDownloadSuccessful(for: book)
            }
        }

        // Register the content transfer BEFORE starting it. Reconciliation runs on
        // foreground and on borrow, and it fired three times inside the first eight
        // seconds of this fulfillment in a device trace; each pass saw a license
        // with no content and no registered transfer, and scheduled a re-download.
        // Registering here is what makes the fulfillment visible to that guard, and
        // it is the same edge the half-sheet uses to swap the borrow spinner for a
        // real progress bar.
        //
        // Registered for EVERY LCP content type, not just audiobooks. The clear on
        // completion is unconditional, and an LCP EPUB mid-fulfillment resolves to
        // `.absent` (its license is not copied to the content directory the way an
        // audiobook's is), so a warm `load()` during the transfer would otherwise
        // reconcile a perfectly healthy EPUB download to `.downloadFailed`.
        progressReporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)

        let fulfillmentDownloadTask = lcpService.fulfill(licenseUrl, progress: lcpProgress, completion: lcpCompletion)

        if book.defaultBookContentType == .audiobook {
            // The `.lcpl` license has landed; the `.lcpa` content package is
            // still transferring (it can be well over a gigabyte). The book
            // therefore stays `.downloading` until `lcpCompletion` confirms the
            // content is on disk.
            //
            // It used to be marked `.downloadSuccessful` right here, on the
            // grounds that a license alone was enough to stream. That is no
            // longer true: streaming-from-license is broken upstream
            // (readium/swift-toolkit#579) and an `.lcpa` is a single encrypted
            // container with no partial-play threshold, so the license alone
            // does not make a playable book. Marking success early had two
            // visible costs — "Listen" was offered for a book whose audio was
            // absent, and the half-sheet's progress bar (gated on
            // `bookState == .downloading`) rendered an invisible spacer for the
            // entire download, which patrons read as a failure.
            //
            // Cancel across the content phase does NOT work through `downloadInfo`:
            // that registration is cleared ~100 ms after the download-completion
            // cleanup runs, and Readium's own transfer was never in it. Cancel
            // takes the no-task branch, and `DownloadCancellationHandler` clears
            // the content-transfer registration so the book does not stay pinned
            // at `.downloading` behind a bar that no longer moves.
            Log.info(#file, "LCP audiobook license fulfilled; awaiting .lcpa content before marking successful: \(book.identifier)")

            if let license = TPPLCPLicense(url: licenseUrl) {
                bookRegistry.setFulfillmentId(license.identifier, for: book.identifier)
            } else {
                Log.error(#file, "🔑 ❌ Failed to read license for fulfillment ID")
            }

            copyLicenseForStreaming(book: book, sourceLicenseUrl: licenseUrl)

            runOnMainAsync { [weak self] in
                self?.progressReporter.broadcastUpdate()
            }
        }

        if let fulfillmentDownloadTask = fulfillmentDownloadTask {
            let downloadInfo = MyBooksDownloadInfo(downloadProgress: 0.0, downloadTask: fulfillmentDownloadTask, rightsManagement: .none)
            Task { [weak self] in
                guard let self else { return }
                await self.stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
            }
        }
    }

    // MARK: - Streaming license copy

    /// Copies the LCP license file to the content directory for streaming
    /// support while preserving the existing fulfillment flow.
    private func copyLicenseForStreaming(book: TPPBook, sourceLicenseUrl: URL) {
        Log.info(#file, "🎵 Starting license copy for streaming: \(book.identifier)")

        guard let finalContentURL = bookFileManager.fileUrl(for: book.identifier) else {
            Log.error(#file, "🎵 ❌ Unable to determine final content URL for streaming license copy")
            return
        }

        let streamingLicenseUrl = finalContentURL.deletingPathExtension().appendingPathExtension("lcpl")
        Log.info(#file, "🎵 Copying license FROM: \(sourceLicenseUrl.path)")
        Log.info(#file, "🎵 Copying license TO: \(streamingLicenseUrl.path)")

        do {
            try? fileManager.removeItem(at: streamingLicenseUrl)
            try fileManager.copyItem(at: sourceLicenseUrl, to: streamingLicenseUrl)
        } catch {
            TPPErrorLogger.logError(error, summary: "Failed to copy LCP license for streaming", metadata: [
                "book": book.loggableDictionary,
                "sourceLicenseUrl": sourceLicenseUrl.absoluteString,
                "targetLicenseUrl": streamingLicenseUrl.absoluteString
            ])
        }
    }
}

#endif

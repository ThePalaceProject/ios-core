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
                // Publish to progress publisher so UI updates (HalfSheet, BookCell, etc.)
                await MainActor.run {
                    self.progressReporter.downloadProgressPublisher.send((book.identifier, progressValue))
                }
                self.progressReporter.broadcastUpdate()
            }
        }

        let lcpCompletion: (URL?, Error?) -> Void = { [weak self] localUrl, error in
            guard let self = self else { return }
            if let error = error {
                let summary = "\(String(describing: book.distributor)) LCP license fulfillment error"
                TPPErrorLogger.logError(error, summary: summary, metadata: [
                    "book": book.loggableDictionary,
                    "licenseURL": licenseUrl.absoluteString,
                    "localURL": localUrl?.absoluteString ?? "N/A"
                ])

                // adjacent: LCP audiobooks are marked
                // `.downloadSuccessful` the moment the .lcpl license lands
                // (streaming-ready). A phase-2 .lcpa content download
                // failure — typically airplane mode mid-fetch from
                // googleapis.com — must NOT downgrade an already-readable
                // audiobook back to `.downloadFailed`. The user reported
                // this on iPad: previously-downloaded audiobooks losing
                // the Read/Listen affordance the second they went offline.
                // Streaming still works off the license; offline playback
                // just isn't ready until they retry.
                //
                // `.used` is included for future-proofing — audiobooks
                // don't transition through `.used` today (only PDFs do, see
                // TPPPDFDocumentMetadata), but mirroring the established
                // `(.downloadSuccessful || .used)` pattern from
                // BookReturnService keeps the guard correct if audiobook
                // playback ever wires through the open-once → `.used`
                // transition.
                let currentState = self.bookRegistry.state(for: book.identifier)
                let isStreamingReady = currentState == .downloadSuccessful || currentState == .used
                if book.defaultBookContentType == .audiobook && isStreamingReady {
                    Log.warn(#file, "LCP audiobook content download failed but streaming license intact — leaving '\(book.title)' (\(book.identifier)) as \(currentState)")
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
                if book.defaultBookContentType == .audiobook {
                    Log.warn(#file, "Content storage failed for audiobook, but streaming still available")
                } else {
                    let errorMessage = "Error replacing content file with file \(localUrl.absoluteString)"
                    self.alertPresenter.failDownloadWithAlert(for: book, withMessage: errorMessage)
                    return
                }
            } else if book.defaultBookContentType == .audiobook {
                Log.info(#file, "Audiobook content stored successfully, offline playback now available")
            }

            // PDF fulfillment: Readium's PDFNavigator streams decrypted
            // pages on demand via the shared GCDHTTPServer, so no eager
            // zip→temp extract is needed here. Just mark the book
            // successful once the LCP container + license are on disk.
            if book.defaultBookContentType == .pdf {
                self.delegate?.markDownloadSuccessful(for: book)
            }
        }

        let fulfillmentDownloadTask = lcpService.fulfill(licenseUrl, progress: lcpProgress, completion: lcpCompletion)

        if book.defaultBookContentType == .audiobook {
            Log.info(#file, "LCP audiobook license fulfilled, ready for streaming: \(book.identifier)")

            if let license = TPPLCPLicense(url: licenseUrl) {
                bookRegistry.setFulfillmentId(license.identifier, for: book.identifier)
            } else {
                Log.error(#file, "🔑 ❌ Failed to read license for fulfillment ID")
            }

            copyLicenseForStreaming(book: book, sourceLicenseUrl: licenseUrl)
            delegate?.markDownloadSuccessful(for: book)

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

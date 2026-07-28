import PalaceBookRegistry
//
//  AdobeDRMHandler.swift
//  Palace
//
//  Bridges NYPLADEPTDelegate (ObjC++) callbacks from the Adobe RMSDK into
//  Palace's download lifecycle. Owns the file move + rights-data persistence
//  after Adobe fulfilment, and routes progress / cancellation back to the host
//  download center via a narrow delegate protocol so the testable logic
//  doesn't have to live behind an @objc protocol method signature.
//

#if FEATURE_DRM_CONNECTOR
import Foundation
import PalaceLogging
import PalaceBookModel

// MARK: - AdobeDRMHandlerDelegate

protocol AdobeDRMHandlerDelegate: AnyObject {
    var bookRegistry: TPPBookRegistryProvider { get }
    func fileUrl(for identifier: String) -> URL?
    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?)
    func markDownloadSuccessful(for book: TPPBook)
    func broadcastUpdate()
    /// Forwards Adobe's progress callback back through MyBooksDownloadCenter so
    /// it can update its async download-info state and publish to subscribers.
    func handleAdobeDownloadProgress(_ progress: Double, for tag: String)
}

// MARK: - AdobeDRMHandler

final class AdobeDRMHandler: NSObject {

    weak var delegate: AdobeDRMHandlerDelegate?

    init(delegate: AdobeDRMHandlerDelegate? = nil) {
        self.delegate = delegate
        super.init()
    }

    // MARK: - Testable Logic
    //
    // These methods carry the actual fulfilment / cancellation behaviour and
    // accept everything they need as plain values. The `NYPLADEPTDelegate`
    // conformance below just unpacks the ObjC callbacks and forwards here, so
    // tests can verify each branch without standing up a real NYPLADEPT.

    /// Process the result of an Adobe DRM fulfilment attempt.
    /// - Parameter fileManager: injectable so tests can provide a temp-dir
    ///   FileManager (or a fault-injecting fake) instead of touching the
    ///   real app sandbox.
    func handleFulfillmentResult(
        didFinishDownload: Bool,
        to adeptToURL: URL?,
        fulfillmentID: String?,
        isReturnable: Bool,
        rightsData: Data,
        tag: String,
        adeptError: Error?,
        fileManager: FileManager = .default
    ) {
        guard let delegate = delegate,
              let book = delegate.bookRegistry.book(forIdentifier: tag),
              let rights = String(data: rightsData, encoding: .utf8) else { return }

        var didSucceedCopying = false

        if didFinishDownload {
            guard let fileURL = delegate.fileUrl(for: book.identifier) else { return }

            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                print("Remove item error: \(error)")
            }

            guard let destURL = delegate.fileUrl(for: book.identifier),
                  let adeptToURL = adeptToURL else {
                TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: destination file URL unavailable", metadata: [
                    "adeptError": adeptError ?? "N/A",
                    "fileURLToRemove": adeptToURL ?? "N/A",
                    "book": book.loggableDictionary,
                    "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
                    "AdobeRights": rights,
                    "AdobeTag": tag
                ])
                delegate.failDownloadWithAlert(for: book, withMessage: nil)
                return
            }

            do {
                try fileManager.copyItem(at: adeptToURL, to: destURL)
                didSucceedCopying = true
            } catch {
                TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: failure copying file", metadata: [
                    "adeptError": adeptError ?? "N/A",
                    "copyError": error,
                    "fromURL": adeptToURL,
                    "destURL": destURL,
                    "book": book.loggableDictionary,
                    "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
                    "AdobeRights": rights,
                    "AdobeTag": tag
                ])
            }
        } else {
            TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: did not finish download", metadata: [
                "adeptError": adeptError ?? "N/A",
                "adeptToURL": adeptToURL ?? "N/A",
                "book": book.loggableDictionary,
                "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
                "AdobeRights": rights,
                "AdobeTag": tag
            ])
        }

        if !didFinishDownload || !didSucceedCopying {
            delegate.failDownloadWithAlert(for: book, withMessage: nil)
            return
        }

        guard let rightsFilePath = delegate.fileUrl(for: book.identifier)?.path.appending("_rights.xml") else { return }
        do {
            try rightsData.write(to: URL(fileURLWithPath: rightsFilePath))
        } catch {
            print("Failed to store rights data.")
        }

        if isReturnable, let fulfillmentID = fulfillmentID {
            delegate.bookRegistry.setFulfillmentId(fulfillmentID, for: book.identifier)
        }

        delegate.markDownloadSuccessful(for: book)

        delegate.broadcastUpdate()
    }

    func handleProgress(_ progress: Double, for tag: String) {
        delegate?.handleAdobeDownloadProgress(progress, for: tag)
    }

    func handleCancellation(tag: String) {
        delegate?.bookRegistry.setState(.downloadNeeded, for: tag)
        delegate?.broadcastUpdate()
    }

    func handleNoAuthorization() {
        // Pre-PP-3649 behavior was to show a sign-in modal, but now that we call
        // ensureDeviceActivated() before fulfillment, this path should only be hit
        // if activation succeeded but the device was deauthorized mid-fulfillment
        // (extremely rare). Log for diagnostics rather than showing a confusing modal.
        Log.warn(#file, "Adobe DRM fulfillment rejected after activation — device may have been deauthorized mid-download")
    }
}

// MARK: - NYPLADEPTDelegate

extension AdobeDRMHandler: NYPLADEPTDelegate {

    func adept(_ adept: NYPLADEPT, didFinishDownload: Bool, to adeptToURL: URL?, fulfillmentID: String?, isReturnable: Bool, rightsData: Data, tag: String, error adeptError: Error?) {
        handleFulfillmentResult(
            didFinishDownload: didFinishDownload,
            to: adeptToURL,
            fulfillmentID: fulfillmentID,
            isReturnable: isReturnable,
            rightsData: rightsData,
            tag: tag,
            adeptError: adeptError
        )
    }

    func adept(_ adept: NYPLADEPT, didUpdateProgress progress: Double, tag: String) {
        handleProgress(progress, for: tag)
    }

    func adept(_ adept: NYPLADEPT, didCancelDownloadWithTag tag: String) {
        handleCancellation(tag: tag)
    }

    func didIgnoreFulfillmentWithNoAuthorizationPresent() {
        handleNoAuthorization()
    }
}
#endif

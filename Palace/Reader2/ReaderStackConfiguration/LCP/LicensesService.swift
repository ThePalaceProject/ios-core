//
//  LicensesService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 25.03.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared
import ReadiumLCP
import ReadiumZIPFoundation
import CryptoSwift
import PalaceLogging
import PalaceCatalog

enum TPPLicensesServiceError: Error {
    case licenseError(message: String)

    public var description: String {
        switch self {
        case .licenseError(let message): return message
        }
    }
}

// Swift 6 `complete`: `@unchecked Sendable`. The instance is passed as
// `delegate:` to `URLSession(configuration:delegate:delegateQueue:)`, which
// requires a `Sendable` delegate under strict concurrency.
// INVARIANT — no concurrent access to the mutable state:
//   • `progressHandler`, `completionHandler`, `lcpl`, `link` are written exactly
//     once, synchronously inside `acquirePublication(...)`, BEFORE `task.resume()`.
//   • They are read only from the `URLSessionDownloadDelegate` callbacks, which
//     this class always registers with `delegateQueue: .main`.
//   • `task.resume()` establishes the happens-before edge, so the single writer
//     precedes every reader and no read races a write.
// This is the honest ceiling for a callback-style delegate; a `@MainActor`
// isolation would instead ripple onto every (test) caller of the synchronous
// `acquirePublication` entry point.
/// The whole-archive transfer in flight, so a chapter load can borrow the link.
///
/// A patron waiting on a chapter and the background fetch of the same 1-2 GB
/// archive compete for one connection. Measured on a patron's device at
/// ~4.3 MB/s: a cold chapter needs 12,705,792 bytes before the first audio
/// sample, about 3 s with the link to itself and roughly 17 s on a quarter
/// share, against a 30 s deadline in the player.
///
/// Suspension, not cancellation: a suspended task keeps its progress, so
/// nothing already fetched is discarded.
enum LCPPublicationTransfer {

    /// Longest a hold may last before the transfer resumes anyway.
    ///
    /// A load that never reports its end must not suspend the patron's
    /// download for the life of the process. Below
    /// `LocalBookContentService.inflightContentDownloadIdleTimeout`, so a held
    /// transfer cannot outlive the claim that tracks it.
    static let maxHold: TimeInterval = 60

    /// Whether a hold taken at `heldSince` is still in force.
    ///
    /// Pure so the expiry is testable and a flipped comparison is caught; the
    /// expensive mistake is a hold that never lifts.
    static func holdIsInForce(heldSince: Date?, now: Date, maxHold: TimeInterval = maxHold) -> Bool {
        guard let heldSince else { return false }
        return now.timeIntervalSince(heldSince) < maxHold
    }

    // Swift 6 `complete`: `nonisolated(unsafe)` with an explicit lock, matching
    // the lock-backed `@unchecked Sendable` precedent in this file.
    // INVARIANT — every read and write of `task` and `heldSince` happens inside
    // `lock`, and no reference escapes the critical section except the local
    // `inFlight` copy in `releaseIfExpired`, which is resumed outside the lock
    // precisely so a `URLSession` callback cannot re-enter it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var task: URLSessionDownloadTask?
    nonisolated(unsafe) private static var heldSince: Date?

    /// Called by the transfer as it starts, and with nil once it is finished.
    static func register(_ transfer: URLSessionDownloadTask?) {
        lock.lock(); defer { lock.unlock() }
        task = transfer
        heldSince = nil
    }

    /// A chapter the patron is waiting on has started loading.
    static func holdForStreamingLoad(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard heldSince == nil else { return }
        heldSince = now
        task?.suspend()
    }

    /// The load is over, however it ended.
    static func releaseStreamingLoad() {
        lock.lock(); defer { lock.unlock() }
        guard heldSince != nil else { return }
        heldSince = nil
        task?.resume()
    }

    /// Lifts a hold whose load never reported an end.
    static func releaseIfExpired(now: Date = Date()) {
        lock.lock()
        let expired = heldSince != nil && !holdIsInForce(heldSince: heldSince, now: now)
        if expired { heldSince = nil }
        let inFlight = task
        lock.unlock()
        if expired { inFlight?.resume() }
    }

    /// Whether a chapter load currently holds the link.
    static var isHolding: Bool {
        lock.lock(); defer { lock.unlock() }
        return heldSince != nil
    }

    /// Test seam: forget any registered transfer and hold.
    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        task = nil
        heldSince = nil
    }
}

class TPPLicensesService: NSObject, @unchecked Sendable {

    // MARK: - Transfer policy

    /// How long the whole publication transfer may take.
    ///
    /// A streamed LCP audiobook archive is one to two gigabytes. Measured on a
    /// patron's device at ~4.3 MB/s, a 1,896,374,144-byte archive needs about
    /// 441 s at full rate, and that link was observed collapsing mid-transfer.
    /// The previous 600 s cap therefore killed the transfer rather than the
    /// transfer finishing, and with no resume data each attempt restarted from
    /// byte zero and re-saturated the same link: 22 failures over six weeks on
    /// one device, the archive never completing.
    static let publicationResourceTimeout: TimeInterval = 4 * 60 * 60

    /// How long a socket may deliver nothing before the transfer fails.
    ///
    /// Unchanged in spirit from the 60 s this replaced: the budget above is for a
    /// slow transfer, not for a dead one.
    static let publicationRequestTimeout: TimeInterval = 60

    /// How many times a failed transfer may be resumed from its partial data.
    ///
    /// Bounded because a link that never recovers would otherwise be retried for
    /// the life of the process, spending the patron's battery and data.
    static let maxResumeAttempts = 3

    /// What to do with a transfer that failed.
    enum ResumeAction: Equatable {
        /// Continue from the bytes already on disk.
        case resume(Data)
        /// Report the failure; there is nothing cheaper to try.
        case giveUp
    }

    /// Whether a failed transfer can be continued rather than restarted.
    ///
    /// Pure so the policy is testable and a flipped comparison is caught: the
    /// expensive mistake here is silently restarting a 1.9 GB download.
    static func resumeAction(for error: Error, attemptsSoFar: Int) -> ResumeAction {
        let nsError = error as NSError
        // A cancelled transfer was cancelled deliberately; resuming it fights the
        // caller that asked for it to stop.
        guard nsError.code != NSURLErrorCancelled else { return .giveUp }
        guard attemptsSoFar < maxResumeAttempts else { return .giveUp }
        guard let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
              !data.isEmpty
        else { return .giveUp }
        return .resume(data)
    }

    /// Resume attempts spent on the transfer in flight. Written only from the
    /// delegate callbacks, which this class always registers on the main queue.
    private var resumeAttempts = 0
    /// The session in flight, kept so a resumed task is created on the same one.
    private var activeSession: URLSession?


    var progressHandler: ((_ progress: Double) -> Void)?
    var completionHandler: ((_ localUrl: URL?, _ error: Error?) -> Void)?
    var lcpl: URL?
    var link: TPPLCPLicenseLink?

    func acquirePublication(from lcpl: URL, progress: @escaping (_ progress: Double) -> Void, completion: @escaping (_ localUrl: URL?, _ error: Error?) -> Void) -> URLSessionDownloadTask? {
        // Parse LCP license file
        guard let license = TPPLCPLicense(url: lcpl) else {
            completion(nil, TPPLicensesServiceError.licenseError(message: "Reading license file failed"))
            return nil
        }
        // Get publication download link
        guard let link = license.firstLink(withRel: .publication), let href = link.href, let url = URL(string: href) else {
            completion(nil, TPPLicensesServiceError.licenseError(message: "Error parsing license file, publication href was not found"))
            return nil
        }

        self.progressHandler = progress
        self.completionHandler = completion
        self.lcpl = lcpl
        self.link = link

        Log.info(#file, "📥 [LCP DOWNLOAD] Starting publication download")
        Log.info(#file, "  Host: \(url.host ?? "unknown")")
        Log.info(#file, "  Full URL: \(url.absoluteString)")

        let request = URLRequest(url: url, applyingCustomUserAgent: true)
        let session: URLSession

        if url.host?.lowercased().contains("googleapis.com") == true {
            // No credentials may be sent to googleapis.com use ephemeral session
            Log.info(#file, "  Session type: ephemeral (no credentials for googleapis.com)")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.publicationRequestTimeout
            config.timeoutIntervalForResource = Self.publicationResourceTimeout
            session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        } else {
            // Use sha256 for a stable session identifier across app launches (PP-3704).
            // Swift's URL.hashValue is randomized per process (SE-0206), so using it caused
            // background download sessions to be orphaned on every app restart.
            let stableHash = lcpl.absoluteString.sha256()
            let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "").appending(".lcpBackgroundIdentifier.\(stableHash)")
            let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            Log.info(#file, "  Background session ID: \(backgroundIdentifier)")
            session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: .main)
        }
        self.activeSession = session
        self.resumeAttempts = 0
        let task = session.downloadTask(with: request)
        LCPPublicationTransfer.register(task)
        task.resume()
        return task
    }

    /// Injects licens file into LCP-protected file
    /// - Parameters:
    ///   - lcpl: license URL
    ///   - file: LCP-protected file URL
    func injectLicense(lcpl: URL, to file: URL, at path: String) async throws {
        let archive = try await Archive(url: file, accessMode: .update)

        do {
            // Removes the old License if it already exists in the archive, otherwise we get duplicated entries
            if let oldLicense = try await archive.get(path) {
                try await archive.remove(oldLicense)
            }

            // Stores the License into the ZIP file
            let data = try Data(contentsOf: lcpl)
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: {
                    (position, size) -> Data in
                    let start = Int(position)
                    let end = min(start + Int(size), data.count)
                    return data[start..<end]
                }
            )
        } catch {
            throw TPPLicensesServiceError.licenseError(message: "Error injecting license file: \(error.localizedDescription)")
        }
    }

    /// Defines path inside .zip file to write license file to.
    /// - Parameter link: LCP license `link` object.
    /// - Returns: Path inside .zip file, `nil` if license should not be injected.
    func pathInZip(for link: TPPLCPLicenseLink) -> String? {
        guard let linkType = link.type else {
            return nil
        }
        switch linkType {
        case ContentTypeEpubZip: return "META-INF/license.lcpl"
        case ContentTypeReadiumLCP, ContentTypeReadiumLCPPDF, ContentTypePDFLCP, ContentTypeAudiobookLCP: return "license.lcpl"
        default: return nil
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension TPPLicensesService: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        LCPPublicationTransfer.register(nil)
        guard let lcpl = self.lcpl, let link = self.link else {
            completionHandler?(nil, TPPLicensesServiceError.licenseError(message: "Missing license or link"))
            return
        }

        let safeCopy = FileManager.default.temporaryDirectory.appendingPathComponent("download_\(UUID().uuidString).zip")

        do {
            try FileManager.default.copyItem(at: location, to: safeCopy)

            if let licensePathInZip = self.pathInZip(for: link) {

                Task {
                    do {
                        if (try? await Archive(url: safeCopy, accessMode: .read)) != nil {
                            try await self.injectLicense(lcpl: lcpl, to: safeCopy, at: licensePathInZip)

                            completionHandler?(safeCopy, nil)
                        } else {
                            completionHandler?(nil, TPPLicensesServiceError.licenseError(message: "Failed to open archive"))
                        }
                    } catch {
                        completionHandler?(nil, error)
                    }
                }
            } else {
                completionHandler?(safeCopy, nil)
            }
        } catch {
            completionHandler?(nil, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        switch Self.resumeAction(for: error, attemptsSoFar: resumeAttempts) {
        case let .resume(data):
            // Continue from the bytes already on disk. Restarting a 1.9 GB
            // archive from zero re-saturates the very link that just failed,
            // which is how a transfer can fail repeatedly and never advance.
            resumeAttempts += 1
            Log.info(#file, String(
                format: "📥 [LCP DOWNLOAD] resuming after %@ (attempt %d of %d, %d bytes already fetched)",
                (error as NSError).localizedDescription,
                resumeAttempts, Self.maxResumeAttempts, data.count
            ))
            let session = activeSession ?? session
            session.downloadTask(withResumeData: data).resume()
        case .giveUp:
            LCPPublicationTransfer.register(nil)
            // A deliberate cancellation is not a failure to report.
            if (error as NSError).code != NSURLErrorCancelled {
                completionHandler?(nil, error)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

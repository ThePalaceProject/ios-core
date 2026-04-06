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

enum TPPLicensesServiceError: Error {
    case licenseError(message: String)

    public var description: String {
        switch self {
        case .licenseError(let message): return message
        }
    }
}

class TPPLicensesService: NSObject {

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

        // PP-3704: No credentials may be sent to storage.googleapis.com (or any googleapis.com).
        // Sending cookies/Authorization causes 401. Use ephemeral session (no cookies) for that domain.
        let request = URLRequest(url: url, applyingCustomUserAgent: true)
        let session: URLSession
        if url.host?.lowercased().contains("googleapis.com") == true {
            Log.info("LCP", "Using ephemeral session (no credentials) for googleapis.com publication download: \(url.absoluteString)")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 600
            session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        } else {
            // Create download task and return it to MyBooksDownloadCenter
            // to hande task cancellation correctly
            let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "").appending(".lcpBackgroundIdentifier.\(lcpl.hashValue)")
            let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: .main)
        }
        let task = session.downloadTask(with: request)
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
        // Check the task wasn't cancelled
        if let nsError = error as? NSError, nsError.code != NSURLErrorCancelled {
            completionHandler?(nil, error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

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

        let isGoogleAPIs = url.host?.lowercased().contains("googleapis.com") == true
        Log.info(#file, "📥 [LCP DOWNLOAD] Starting publication download")
        Log.info(#file, "  Host: \(url.host ?? "unknown")")
        Log.info(#file, "  Is googleapis.com: \(isGoogleAPIs)")
        Log.warn(#file, "  ⚠️ Session type: background (credentials NOT stripped — fix pending)")
        Log.info(#file, "  Full URL: \(url.absoluteString)")

        let request = URLRequest(url: url, applyingCustomUserAgent: true)
        let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "").appending(".lcpBackgroundIdentifier.\(lcpl.hashValue)")
        let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        Log.info(#file, "  Background session ID: \(backgroundIdentifier)")
        let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: .main)
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

        // Log HTTP status — a 401 here means credentials leaked to GCS
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            let requestURL = downloadTask.currentRequest?.url?.absoluteString ?? "unknown"
            Log.info(#file, "📥 [LCP DOWNLOAD] HTTP \(statusCode) — URL: \(requestURL)")

            if statusCode != 200 {
                Log.error(#file, "📥 [LCP DOWNLOAD] ❌ Server returned HTTP \(statusCode) — this may be a GCS credential leak (PP-3704)")
                TPPErrorLogger.logError(
                    withCode: .ignore,
                    summary: "LCP download non-200 HTTP status",
                    metadata: [
                        "http_status": String(statusCode),
                        "request_url": requestURL,
                        "session_id": session.configuration.identifier ?? "ephemeral"
                    ]
                )
                completionHandler?(nil, TPPLicensesServiceError.licenseError(message: "Server returned HTTP \(statusCode) — download failed"))
                return
            }
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        Log.info(#file, "📥 [LCP DOWNLOAD] ✅ Download finished — size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")

        let safeCopy = FileManager.default.temporaryDirectory.appendingPathComponent("download_\(UUID().uuidString).zip")

        do {
            try FileManager.default.copyItem(at: location, to: safeCopy)

            if let licensePathInZip = self.pathInZip(for: link) {

                Task {
                    do {
                        if (try? await Archive(url: safeCopy, accessMode: .read)) != nil {
                            try await self.injectLicense(lcpl: lcpl, to: safeCopy, at: licensePathInZip)
                            Log.info(#file, "📥 [LCP DOWNLOAD] ✅ License injected — ready for local playback")
                            completionHandler?(safeCopy, nil)
                        } else {
                            Log.error(#file, "📥 [LCP DOWNLOAD] ❌ Failed to open archive after download")
                            completionHandler?(nil, TPPLicensesServiceError.licenseError(message: "Failed to open archive"))
                        }
                    } catch {
                        Log.error(#file, "📥 [LCP DOWNLOAD] ❌ License injection failed: \(error.localizedDescription)")
                        completionHandler?(nil, error)
                    }
                }
            } else {
                completionHandler?(safeCopy, nil)
            }
        } catch {
            Log.error(#file, "📥 [LCP DOWNLOAD] ❌ File copy failed: \(error.localizedDescription)")
            completionHandler?(nil, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let httpResponse = task.response as? HTTPURLResponse {
            Log.info(#file, "📥 [LCP DOWNLOAD] Task completed — HTTP status: \(httpResponse.statusCode)")
        }
        if let nsError = error as? NSError, nsError.code != NSURLErrorCancelled {
            Log.error(#file, "📥 [LCP DOWNLOAD] ❌ Session task failed: \(nsError.localizedDescription) (code: \(nsError.code))")
            if let failingURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                Log.error(#file, "  Failing URL: \(failingURL)")
            }
            TPPErrorLogger.logError(
                nsError,
                summary: "LCP background download task failed",
                metadata: [
                    "error_code": String(nsError.code),
                    "session_id": session.configuration.identifier ?? "ephemeral"
                ]
            )
            completionHandler?(nil, error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

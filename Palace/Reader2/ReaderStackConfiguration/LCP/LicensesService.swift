//
//  LicensesService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 25.03.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumLCP
import ReadiumShared
import ReadiumZIPFoundation

// MARK: - TPPLicensesServiceError

enum TPPLicensesServiceError: Error {
  case licenseError(message: String)

  public var description: String {
    switch self {
    case let .licenseError(message): message
    }
  }
}

// MARK: - TPPLicensesService

class TPPLicensesService: NSObject {
  var progressHandler: ((_ progress: Double) -> Void)?
  var completionHandler: ((_ localUrl: URL?, _ error: Error?) -> Void)?
  var lcpl: URL?
  var link: TPPLCPLicenseLink?

  func acquirePublication(
    from lcpl: URL,
    progress: @escaping (_ progress: Double) -> Void,
    completion: @escaping (_ localUrl: URL?, _ error: Error?) -> Void
  ) -> URLSessionDownloadTask? {
    // Parse LCP license file
    guard let license = TPPLCPLicense(url: lcpl) else {
      completion(nil, TPPLicensesServiceError.licenseError(message: "Reading license file failed"))
      return nil
    }
    // Get publication download link
    guard let link = license.firstLink(withRel: .publication), let href = link.href, let url = URL(string: href) else {
      completion(
        nil,
        TPPLicensesServiceError.licenseError(message: "Error parsing license file, publication href was not found")
      )
      return nil
    }

    progressHandler = progress
    completionHandler = completion
    self.lcpl = lcpl
    self.link = link

    // Create download task and return it to MyBooksDownloadCenter
    // to hande task cancellation correctly
    // Background task identifier is unique to create unique download sessions for each class instance.
    // Otherwise, single download session calls one delegate class methods,
    // and only one book's status is updated.
    let request = URLRequest(url: url, applyingCustomUserAgent: true)
    let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "")
      .appending(".lcpBackgroundIdentifier.\(lcpl.hashValue)")
    let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
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
          position, size -> Data in
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

// MARK: URLSessionDownloadDelegate

extension TPPLicensesService: URLSessionDownloadDelegate {
  func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let lcpl = lcpl, let link = link else {
      completionHandler?(nil, TPPLicensesServiceError.licenseError(message: "Missing license or link"))
      return
    }

    let safeCopy = FileManager.default.temporaryDirectory.appendingPathComponent("download_\(UUID().uuidString).zip")

    do {
      try FileManager.default.copyItem(at: location, to: safeCopy)

      if let licensePathInZip = pathInZip(for: link) {
        Task {
          do {
            if let _ = try? await Archive(url: safeCopy, accessMode: .read) {
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

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
    // Check the task wasn't cancelled
    if let nsError = error as? NSError, nsError.code != NSURLErrorCancelled {
      completionHandler?(nil, error)
    }
  }

  func urlSession(
    _: URLSession,
    downloadTask _: URLSessionDownloadTask,
    didWriteData _: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
  }
}

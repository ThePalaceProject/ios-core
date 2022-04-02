//
//  LicensesService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 25.03.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import R2Shared
import ReadiumLCP
import ZIPFoundation

enum TPPLicensesServiceError: Error {
  case licenseError(message: String)
  
  public var description: String {
    switch self {
    case .licenseError(let message): return message
    }
  }  
}

class TPPLicensesService: NSObject {
  
  let lcpService: LCPService
  let contentProtection: ContentProtection
  
  init(lcpService: LCPService, contentProtection: ContentProtection) {
    self.lcpService = lcpService
    self.contentProtection = contentProtection
  }
  
  func acquirePublication(from lcpl: URL, completion: @escaping (_ localUrl: URL?, _ error: Error?) -> Void) {
    
    // 1. read license file (extend TPPLCPLicense for that)
    guard let license = TPPLCPLicense(url: lcpl) else {
      completion(nil, TPPLicensesServiceError.licenseError(message: "Reading license file failed"))
      return
    }
    
    guard let link = license.firstLink(withRel: .publication), let href = link.href, let url = URL(string: href) else {
      completion(nil, TPPLicensesServiceError.licenseError(message: "Error parsing license file, publication href was not found"))
      return
    }
    
    let title = link.title ?? "No title"
    
    // 2. download license.url (see LicenseDocument.swift in readium-lcp-swift)
    print("Download url: \(url), title: \(title)")

    // DownloadSession.swift contains an example how to update download progress
    
    // LicensesService.swift contains acquirePublication and injectLicense
    
    let request = URLRequest(url: url)
    let task = URLSession.shared.downloadTask(with: request) { tmpLocalUrl, response, error in
      guard let file = tmpLocalUrl, error == nil else {
        completion(nil, TPPLicensesServiceError.licenseError(message: "URLSession downloadTask error: \(error!.localizedDescription)"))
        return
      }

      if let licensePathInZip = self.pathInZip(for: link) {
        do {
          try self.injectLicense(lcpl: lcpl, to: file, at: licensePathInZip)
        } catch {
          completion(nil, error)
        }
      }

      completion(file, nil)
    }
    task.resume()
  }
  
  /// Injects licens file into LCP-protected file
  /// - Parameters:
  ///   - lcpl: license URL
  ///   - file: LCP-protected file URL
  func injectLicense(lcpl: URL, to file: URL, at path: String) throws {
    guard let archive = Archive(url: file, accessMode: .update) else {
      throw TPPLicensesServiceError.licenseError(message: "Error opening archive file \(file.path)")
    }
    
    do {
      // Removes the old License if it already exists in the archive, otherwise we get duplicated entries
      if let oldLicense = archive[path] {
        try archive.remove(oldLicense)
      }

      // Stores the License into the ZIP file
      let data = try Data(contentsOf: lcpl)
      try archive.addEntry(with: path, type: .file, uncompressedSize: UInt32(data.count), provider: { (position, size) -> Data in
        return data[position..<size]
      })
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
    case ContentTypeReadiumLCP, ContentTypeAudiobookLCP: return "license.lcpl"
    default: return nil
    }
  }

}

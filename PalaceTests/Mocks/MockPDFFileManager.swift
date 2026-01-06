import XCTest
@testable import Admission_Form_Automation

class MockPDFFileManager: PDFFileManagerProtocol {
  var files: [Directory: [String: Data]] = [:]

  init() {
    for directory in Directory.allCases {
      files[directory] = [:]
    }
  }

  func initializeDirectory(_ directory: Directory, clearContents: Bool) throws {
    if clearContents {
      files[directory] = [:]
    }
  }

  func initializeAllDirectories() throws {
    for directory in Directory.allCases {
      files[directory] = [:]
    }
  }

  @discardableResult
  func saveFile(_ data: Data, to directory: Directory, fileName: String, options: Data.WritingOptions = .completeFileProtection) throws -> URL {
    files[directory]?[fileName] = data
    return URL(string: "file:///mock/\(directory.rawValue)/\(fileName)")!
  }

  func readFile(from directory: Directory, fileName: String) throws -> Data? {
    return files[directory]?[fileName]
  }

  func fetchPendingFilesInLongTerm() throws -> [Data] {
    return files[.longTerm]?.filter { $0.key.hasSuffix(".meta") }.map { $0.value } ?? []
  }

  func deleteFile(from directory: Directory, fileName: String) throws {
    files[directory]?.removeValue(forKey: fileName)
  }

  func clearDirectory(_ directory: Directory) throws {
    files[directory] = [:]
  }

  func removeInvalidFiles(from directory: Directory, validFilenames: Set<String>) throws {
    guard let directoryFiles = files[directory] else { return }

    for fileName in directoryFiles.keys where !validFilenames.contains(fileName) {
      files[directory]?.removeValue(forKey: fileName)
    }
  }

  func purgeOldFiles(in directory: Directory, olderThanHours: Int = 72) throws {
    // No implementation needed for tests
  }

  func saveBase64FormsToBlankDirectory(formList: [Form]) throws {
    for form in formList {
      guard let base64 = form.fileContents,
            let data = Data(base64Encoded: base64) else {
        continue
      }
      try saveFile(data, to: .blank, fileName: form.fileName)
    }
  }

  func removeInvalidBlankForms(formList: [Form]) throws {
    let validFilenames = Set(formList.map { $0.fileName })
    try removeInvalidFiles(from: .blank, validFilenames: validFilenames)
  }

  func saveHospitalLogos(_ logoList: [HospitalLogo]) throws {
    for logo in logoList {
      guard let base64 = logo.fileContents,
            let data = Data(base64Encoded: base64) else {
        continue
      }
      try saveFile(data, to: .logo, fileName: logo.fileName)
    }
  }

  func getLogoImage(for fileName: String) -> UIImage? {
    return nil // Mock implementation
  }

  func saveExportPDF(fileData: Data, fileName: String) throws {
    try saveFile(fileData, to: .export, fileName: fileName)
  }

  func deleteAllPatientDocuments() throws {
    try clearDirectory(.working)
    try clearDirectory(.export)
  }

  func copyFileToTempWorkingDirectory(fileName: String) throws -> URL {
    guard let data = try readFile(from: .blank, fileName: fileName) else {
      throw NSError(domain: "MockPDFFileManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source file not found in blank directory."])
    }
    return try saveFile(data, to: .working, fileName: fileName)
  }

  func getEditableFileURL(fileName: String) throws -> (fileURL: URL, fileIsDirty: Bool) {
    if let _ = files[.working]?[fileName] {
      return (URL(string: "file:///mock/working/\(fileName)")!, true)
    } else {
      let url = try copyFileToTempWorkingDirectory(fileName: fileName)
      return (url, false)
    }
  }

  func getImmutableFileURL(fileName: String) -> URL? {
    if let _ = files[.export]?[fileName] {
      return URL(string: "file:///mock/export/\(fileName)")!
    }
    return nil
  }
}

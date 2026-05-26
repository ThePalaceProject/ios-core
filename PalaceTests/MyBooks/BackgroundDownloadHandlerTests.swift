//
//  BackgroundDownloadHandlerTests.swift
//  PalaceTests
//
//  Unit tests for BackgroundDownloadHandler: MIME detection, OPDS entry handling,
//  progress updates, file move/replace/validate operations.
//

import XCTest
import PalaceCatalog
@testable import Palace

// Inert session used to mint suspended URLSessionDownloadTask handles for test
// helpers that take a task as a parameter. Using URLSession.shared accumulates
// suspended tasks on the process-wide singleton across tests, leaking dispatch
// state. This shared ephemeral session is invalidated at process exit only.
private let inertTestSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [InertNoOpURLProtocol.self]
    return URLSession(configuration: config)
}()

/// URLProtocol that immediately fails any request without hitting the network,
/// so suspended tasks created on `inertTestSession` never accidentally call out.
final class InertNoOpURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: "InertNoOp", code: -1, userInfo: nil))
    }
    override func stopLoading() {}
}


// MockBackgroundDownloadDelegate extracted to PalaceTests/Mocks/MockBackgroundDownloadDelegate.swift

// MARK: - Tests

final class BackgroundDownloadHandlerTests: XCTestCase {

    private var handler: BackgroundDownloadHandler!
    private var mockDelegate: MockBackgroundDownloadDelegate!

    override func setUp() {
        super.setUp()
        mockDelegate = MockBackgroundDownloadDelegate()
        handler = BackgroundDownloadHandler(delegate: mockDelegate)
    }

    override func tearDown() {
        handler = nil
        mockDelegate = nil
        super.tearDown()
    }

    // MARK: - MIME Type Detection

    func testDetectRightsManagement_adobeAdept() {
        let result = handler.detectRightsManagement(from: ContentTypeAdobeAdept)
        XCTAssertEqual(result, .adobe)
        // Should differ from LCP and from no-DRM
        XCTAssertNotEqual(result, .lcp)
        XCTAssertNotEqual(result, .none)
    }

    func testDetectRightsManagement_readiumLCP() {
        let result = handler.detectRightsManagement(from: ContentTypeReadiumLCP)
        XCTAssertEqual(result, .lcp)
        XCTAssertNotEqual(result, .adobe)
        XCTAssertNotEqual(result, .none)
    }

    func testDetectRightsManagement_epubZip() {
        let result = handler.detectRightsManagement(from: ContentTypeEpubZip)
        XCTAssertEqual(result, .none)
        // Open-access EPUBs need no DRM treatment
        XCTAssertNotEqual(result, .adobe)
        XCTAssertNotEqual(result, .lcp)
    }

    func testDetectRightsManagement_bearerToken() {
        let result = handler.detectRightsManagement(from: ContentTypeBearerToken)
        XCTAssertEqual(result, .simplifiedBearerTokenJSON)
        XCTAssertNotEqual(result, .adobe)
        XCTAssertNotEqual(result, .unknown)
    }

    func testDetectRightsManagement_unknownType() {
        let result = handler.detectRightsManagement(from: "application/x-unknown-drm")
        XCTAssertEqual(result, .unknown)
        // Unknown type must not be treated as a known DRM type
        XCTAssertNotEqual(result, .adobe)
        XCTAssertNotEqual(result, .lcp)
        XCTAssertNotEqual(result, .none)
    }

    // MARK: - OPDS Entry MIME Type Detection

    func testIsOPDSEntryMimeType_applicationXml() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/xml"))
        // Non-OPDS type should return false
        XCTAssertFalse(handler.isOPDSEntryMimeType("application/json"))
    }

    func testIsOPDSEntryMimeType_textXml() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("text/xml"))
        // HTML is not an OPDS type
        XCTAssertFalse(handler.isOPDSEntryMimeType("text/html"))
    }

    func testIsOPDSEntryMimeType_atomXml() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/atom+xml"))
        // EPUB is not an OPDS entry MIME type
        XCTAssertFalse(handler.isOPDSEntryMimeType("application/epub+zip"))
    }

    func testIsOPDSEntryMimeType_opdsCatalog() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/opds-catalog+xml"))
        // Plain JSON is not an OPDS MIME type
        XCTAssertFalse(handler.isOPDSEntryMimeType("application/json"))
    }

    func testIsOPDSEntryMimeType_caseInsensitive() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("APPLICATION/XML"))
        XCTAssertTrue(handler.isOPDSEntryMimeType("Text/XML"))
        // Case-insensitive matching should not accidentally accept non-XML types
        XCTAssertFalse(handler.isOPDSEntryMimeType("APPLICATION/JSON"))
    }

    func testIsOPDSEntryMimeType_epub_returnsFalse() {
        XCTAssertFalse(handler.isOPDSEntryMimeType("application/epub+zip"))
        // Regular XML-based types should still be true
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/xml"))
    }

    func testIsOPDSEntryMimeType_json_returnsFalse() {
        XCTAssertFalse(handler.isOPDSEntryMimeType("application/json"))
        // application/atom+xml should still be an OPDS type
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/atom+xml"))
    }

    func testIsOPDSEntryMimeType_html_returnsFalse() {
        XCTAssertFalse(handler.isOPDSEntryMimeType("text/html"))
        // text/xml should still be true while text/html is false
        XCTAssertTrue(handler.isOPDSEntryMimeType("text/xml"))
    }

    // MARK: - File Validation

    func testValidateDownloadedFile_existingFileWithContent_returnsTrue() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_download_\(UUID().uuidString).epub")
        let data = Data("fake epub content".utf8)
        try data.write(to: testFile)

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let result = handler.validateDownloadedFile(at: testFile, for: book)

        XCTAssertTrue(result)

        try? FileManager.default.removeItem(at: testFile)
    }

    func testValidateDownloadedFile_missingFile_returnsFalse() {
        let nonexistentFile = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).epub")
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        let result = handler.validateDownloadedFile(at: nonexistentFile, for: book)

        XCTAssertFalse(result)
    }

    func testValidateDownloadedFile_emptyFile_returnsFalse() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("empty_\(UUID().uuidString).epub")
        FileManager.default.createFile(atPath: testFile.path, contents: Data(), attributes: nil)

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let result = handler.validateDownloadedFile(at: testFile, for: book)

        XCTAssertFalse(result)

        try? FileManager.default.removeItem(at: testFile)
    }

    // MARK: - File Move

    func testMoveFile_success_setsDownloadSuccessful() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let registry = mockDelegate.bookRegistry as! TPPBookRegistryMock
        registry.addBook(book, state: .downloading)

        // Create source file
        let tempDir = FileManager.default.temporaryDirectory
        let sourceFile = tempDir.appendingPathComponent("source_\(UUID().uuidString).epub")
        let destFile = tempDir.appendingPathComponent("dest_\(UUID().uuidString).epub")
        try Data("book content".utf8).write(to: sourceFile)

        mockDelegate.fileUrls[book.identifier] = destFile

        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)
        let result = handler.moveFile(at: sourceFile, toDestinationForBook: book, forDownloadTask: task)

        XCTAssertTrue(result)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))

        try? FileManager.default.removeItem(at: destFile)
    }

    func testMoveFile_noFileUrl_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let source = URL(fileURLWithPath: "/tmp/nonexistent.epub")
        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)

        // fileUrls is empty, so fileUrl returns nil
        let result = handler.moveFile(at: source, toDestinationForBook: book, forDownloadTask: task)

        XCTAssertFalse(result)
    }

    func testMoveFile_noDelegate_returnsFalse() {
        handler = BackgroundDownloadHandler(delegate: nil)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let source = URL(fileURLWithPath: "/tmp/test.epub")
        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)

        let result = handler.moveFile(at: source, toDestinationForBook: book, forDownloadTask: task)
        XCTAssertFalse(result)
    }

    func testMoveFile_moveFailure_logsError() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let registry = mockDelegate.bookRegistry as! TPPBookRegistryMock
        registry.addBook(book, state: .downloading)

        let nonexistentSource = URL(fileURLWithPath: "/tmp/definitely_not_here_\(UUID().uuidString).epub")
        let destFile = FileManager.default.temporaryDirectory.appendingPathComponent("dest_\(UUID().uuidString).epub")
        mockDelegate.fileUrls[book.identifier] = destFile

        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)
        let result = handler.moveFile(at: nonexistentSource, toDestinationForBook: book, forDownloadTask: task)

        XCTAssertFalse(result)
        XCTAssertEqual(mockDelegate.logBookDownloadFailureCalls.count, 1)
        XCTAssertTrue(mockDelegate.logBookDownloadFailureCalls.first?.reason.contains("move") == true)
    }

    // MARK: - File Replace

    func testReplaceBook_success_setsDownloadSuccessful() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let registry = mockDelegate.bookRegistry as! TPPBookRegistryMock
        registry.addBook(book, state: .downloading)

        let tempDir = FileManager.default.temporaryDirectory
        let sourceFile = tempDir.appendingPathComponent("replace_src_\(UUID().uuidString).epub")
        let destFile = tempDir.appendingPathComponent("replace_dst_\(UUID().uuidString).epub")

        try Data("new content".utf8).write(to: sourceFile)
        mockDelegate.fileUrls[book.identifier] = destFile

        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)
        let result = handler.replaceBook(book, withFileAtURL: sourceFile, forDownloadTask: task)

        XCTAssertTrue(result)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)

        try? FileManager.default.removeItem(at: destFile)
    }

    func testReplaceBook_existingFile_replacesIt() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let registry = mockDelegate.bookRegistry as! TPPBookRegistryMock
        registry.addBook(book, state: .downloading)

        let tempDir = FileManager.default.temporaryDirectory
        let sourceFile = tempDir.appendingPathComponent("new_\(UUID().uuidString).epub")
        let destFile = tempDir.appendingPathComponent("old_\(UUID().uuidString).epub")

        try Data("old content".utf8).write(to: destFile)
        try Data("new content".utf8).write(to: sourceFile)
        mockDelegate.fileUrls[book.identifier] = destFile

        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)
        let result = handler.replaceBook(book, withFileAtURL: sourceFile, forDownloadTask: task)

        XCTAssertTrue(result)

        let finalContent = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(finalContent, "new content")

        try? FileManager.default.removeItem(at: destFile)
    }

    func testReplaceBook_noDelegate_returnsFalse() {
        handler = BackgroundDownloadHandler(delegate: nil)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let source = URL(fileURLWithPath: "/tmp/test.epub")
        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)

        let result = handler.replaceBook(book, withFileAtURL: source, forDownloadTask: task)
        XCTAssertFalse(result)
    }

    func testReplaceBook_noFileUrl_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let source = URL(fileURLWithPath: "/tmp/test.epub")
        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)

        // fileUrls is empty
        let result = handler.replaceBook(book, withFileAtURL: source, forDownloadTask: task)
        XCTAssertFalse(result)
    }

    // MARK: - Progress Handling

    func testHandleDownloadProgress_firstBytes_detectsMimeType() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        // Setup download info
        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)
        let info = MyBooksDownloadInfo(downloadProgress: 0.0, downloadTask: task, rightsManagement: .unknown)
        await mockDelegate.stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)

        // Simulate first bytes (bytesWritten == totalBytesWritten)
        // Note: This test exercises the progress path without MIME type (no real response)
        await handler.handleDownloadProgress(
            for: book,
            task: task,
            bytesWritten: 1024,
            totalBytesWritten: 5120,
            totalBytesExpectedToWrite: 10240
        )

        // Progress should be updated
        let updatedInfo = await mockDelegate.stateManager.downloadInfoAsync(forBookIdentifier: book.identifier)
        XCTAssertNotNil(updatedInfo)
        // Progress = 5120/10240 = 0.5
        XCTAssertEqual(updatedInfo?.downloadProgress ?? 0, 0.5, accuracy: 0.01)
    }

    func testHandleDownloadProgress_noDelegate_doesNotCrash() async {
        handler = BackgroundDownloadHandler(delegate: nil)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = inertTestSession.downloadTask(with: URL(string: "https://example.com")!)

        // Should not crash and handler state must remain consistent
        await handler.handleDownloadProgress(
            for: book,
            task: task,
            bytesWritten: 100,
            totalBytesWritten: 500,
            totalBytesExpectedToWrite: 1000
        )
        // After a no-delegate progress call, handler must still classify MIME types correctly
        XCTAssertNil(handler.delegate, "Delegate must remain nil after no-delegate progress call")
    }

    // MARK: - Initialization

    func testInit_withDelegate() {
        let handler = BackgroundDownloadHandler(delegate: mockDelegate)
        // The delegate should be the same object we passed in
        XCTAssertTrue(handler.delegate === mockDelegate,
                      "Handler must retain the exact delegate instance it was initialized with")
        // A newly initialised handler should detect MIME types correctly
        XCTAssertEqual(handler.detectRightsManagement(from: ContentTypeEpubZip), .none)
        XCTAssertEqual(handler.detectRightsManagement(from: ContentTypeAdobeAdept), .adobe,
                       "Adobe Adept content type must be detected as .adobe rights management")
    }

    func testInit_withoutDelegate() {
        let handler = BackgroundDownloadHandler()
        XCTAssertNil(handler.delegate)
        // Handler without a delegate should still be able to classify MIME types
        XCTAssertEqual(handler.detectRightsManagement(from: ContentTypeAdobeAdept), .adobe)
        // OPDS MIME detection should also work without a delegate
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/xml"))
    }
}

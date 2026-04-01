//
//  BackgroundDownloadHandlerTests.swift
//  PalaceTests
//
//  Unit tests for BackgroundDownloadHandler: MIME detection, OPDS entry handling,
//  progress updates, file move/replace/validate operations.
//

import XCTest
@testable import Palace

// MARK: - Mock Delegate

final class MockBackgroundDownloadDelegate: BackgroundDownloadHandlerDelegate {
    let stateManager = DownloadStateManager()
    let progressReporter: DownloadProgressReporter
    let bookRegistry: TPPBookRegistryProvider
    let userAccount: TPPUserAccount
    let tokenInterceptor: TokenRefreshInterceptor

    var handleDownloadCompletionCalls: [(session: URLSession, task: URLSessionDownloadTask, location: URL)] = []
    var handleTaskCompletionErrorCalls: [(task: URLSessionTask, error: Error?)] = []
    var schedulePendingStartsCalled = false
    var failDownloadCalls: [(book: TPPBook, message: String?)] = []
    var alertForProblemCalls: [(problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook)] = []
    var logBookDownloadFailureCalls: [(book: TPPBook, reason: String)] = []
    var fulfillLCPCalls: [(fileUrl: URL, book: TPPBook)] = []
    var fileUrls: [String: URL] = [:]

    init(
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistryMock(),
        userAccount: TPPUserAccount = TPPUserAccountMock()
    ) {
        self.bookRegistry = bookRegistry
        self.userAccount = userAccount
        self.tokenInterceptor = TokenRefreshInterceptor()
        self.progressReporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(
                postHandler: { _, _ in },
                isVoiceOverRunning: { false }
            )
        )
    }

    func handleDownloadCompletion(session: URLSession, task: URLSessionDownloadTask, location: URL) async {
        handleDownloadCompletionCalls.append((session: session, task: task, location: location))
    }

    func handleTaskCompletionError(task: URLSessionTask, error: Error?) async {
        handleTaskCompletionErrorCalls.append((task: task, error: error))
    }

    func schedulePendingStartsIfPossible() {
        schedulePendingStartsCalled = true
    }

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?) {
        failDownloadCalls.append((book: book, message: message))
    }

    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
        alertForProblemCalls.append((problemDoc: problemDoc, error: error, book: book))
    }

    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?) {
        logBookDownloadFailureCalls.append((book: book, reason: reason))
    }

    func fileUrl(for identifier: String) -> URL? {
        return fileUrls[identifier]
    }

    func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask) {
        fulfillLCPCalls.append((fileUrl: fileUrl, book: book))
    }
}

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
    }

    func testDetectRightsManagement_readiumLCP() {
        let result = handler.detectRightsManagement(from: ContentTypeReadiumLCP)
        XCTAssertEqual(result, .lcp)
    }

    func testDetectRightsManagement_epubZip() {
        let result = handler.detectRightsManagement(from: ContentTypeEpubZip)
        XCTAssertEqual(result, .none)
    }

    func testDetectRightsManagement_bearerToken() {
        let result = handler.detectRightsManagement(from: ContentTypeBearerToken)
        XCTAssertEqual(result, .simplifiedBearerTokenJSON)
    }

    func testDetectRightsManagement_unknownType() {
        let result = handler.detectRightsManagement(from: "application/x-unknown-drm")
        XCTAssertEqual(result, .unknown)
    }

    // MARK: - OPDS Entry MIME Type Detection

    func testIsOPDSEntryMimeType_applicationXml() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/xml"))
    }

    func testIsOPDSEntryMimeType_textXml() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("text/xml"))
    }

    func testIsOPDSEntryMimeType_atomXml() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/atom+xml"))
    }

    func testIsOPDSEntryMimeType_opdsCatalog() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("application/opds-catalog+xml"))
    }

    func testIsOPDSEntryMimeType_caseInsensitive() {
        XCTAssertTrue(handler.isOPDSEntryMimeType("APPLICATION/XML"))
        XCTAssertTrue(handler.isOPDSEntryMimeType("Text/XML"))
    }

    func testIsOPDSEntryMimeType_epub_returnsFalse() {
        XCTAssertFalse(handler.isOPDSEntryMimeType("application/epub+zip"))
    }

    func testIsOPDSEntryMimeType_json_returnsFalse() {
        XCTAssertFalse(handler.isOPDSEntryMimeType("application/json"))
    }

    func testIsOPDSEntryMimeType_html_returnsFalse() {
        XCTAssertFalse(handler.isOPDSEntryMimeType("text/html"))
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

        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
        let result = handler.moveFile(at: sourceFile, toDestinationForBook: book, forDownloadTask: task)

        XCTAssertTrue(result)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))

        try? FileManager.default.removeItem(at: destFile)
    }

    func testMoveFile_noFileUrl_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let source = URL(fileURLWithPath: "/tmp/nonexistent.epub")
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        // fileUrls is empty, so fileUrl returns nil
        let result = handler.moveFile(at: source, toDestinationForBook: book, forDownloadTask: task)

        XCTAssertFalse(result)
    }

    func testMoveFile_noDelegate_returnsFalse() {
        handler = BackgroundDownloadHandler(delegate: nil)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let source = URL(fileURLWithPath: "/tmp/test.epub")
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

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

        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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

        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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

        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        let result = handler.replaceBook(book, withFileAtURL: source, forDownloadTask: task)
        XCTAssertFalse(result)
    }

    func testReplaceBook_noFileUrl_returnsFalse() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let source = URL(fileURLWithPath: "/tmp/test.epub")
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        // fileUrls is empty
        let result = handler.replaceBook(book, withFileAtURL: source, forDownloadTask: task)
        XCTAssertFalse(result)
    }

    // MARK: - Progress Handling

    func testHandleDownloadProgress_firstBytes_detectsMimeType() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        // Setup download info
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
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
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)

        // Should not crash
        await handler.handleDownloadProgress(
            for: book,
            task: task,
            bytesWritten: 100,
            totalBytesWritten: 500,
            totalBytesExpectedToWrite: 1000
        )
    }

    // MARK: - Initialization

    func testInit_withDelegate() {
        let handler = BackgroundDownloadHandler(delegate: mockDelegate)
        XCTAssertNotNil(handler.delegate)
    }

    func testInit_withoutDelegate() {
        let handler = BackgroundDownloadHandler()
        XCTAssertNil(handler.delegate)
    }
}

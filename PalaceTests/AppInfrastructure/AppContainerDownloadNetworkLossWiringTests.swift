//
//  AppContainerDownloadNetworkLossWiringTests.swift
//  PalaceTests
//
//  The network-loss monitor a container builds must act on that container's
//  own download center, or a connectivity drop fails nothing in the app.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class AppContainerDownloadNetworkLossWiringTests: XCTestCase {

    /// A container from the test factory fails a downloading book that its own
    /// center tracks, through its own registry.
    func testFactoryContainer_monitorFailsItsOwnCentersDownload() async throws {
        let registry = TPPBookRegistryMock()
        let container = makeTestAppContainer(bookRegistry: registry)
        let monitor = try XCTUnwrap(container.downloadNetworkLossMonitor)
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloading)
        let task = await track(book, taskID: 4114, in: container.downloadCenter)

        monitor.failActiveDownloads()
        await monitor.lastFailureTask?.value

        XCTAssertEqual(task.state, .canceling)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadFailed)
    }

    /// The production builder installs a monitor bound to the production
    /// download center. The tracked book is not in the registry, so the pass
    /// cancels its task and fails nothing.
    func testProductionContainer_monitorCancelsTasksOfTheProductionCenter() async throws {
        let container = AppContainer.production() // MIGRATED-DEFERRED: the production builder's own wiring is the contract under test
        let monitor = try XCTUnwrap(container.downloadNetworkLossMonitor)
        let center = container.downloadCenter
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let taskID = 941_140
        let task = await track(book, taskID: taskID, in: center)

        monitor.failActiveDownloads()
        await monitor.lastFailureTask?.value
        await center.stateManager.taskIdentifierToBook.remove(taskID)
        await center.stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)

        XCTAssertEqual(task.state, .canceling)
    }

    private func track(_ book: TPPBook, taskID: Int, in center: MyBooksDownloadCenter) async -> MockURLSessionDownloadTask {
        let task = MockURLSessionDownloadTask(taskIdentifier: taskID)
        await center.stateManager.taskIdentifierToBook.set(taskID, value: book)
        await center.stateManager.bookIdentifierToDownloadInfo.set(
            book.identifier,
            value: MyBooksDownloadInfo(downloadProgress: 0.2, downloadTask: task, rightsManagement: .none))
        return task
    }
}

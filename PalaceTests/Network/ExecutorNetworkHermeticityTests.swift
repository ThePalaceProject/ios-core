//
//  ExecutorNetworkHermeticityTests.swift
//  PalaceTests
//
//  #3 guard (intent: palacenetwork-swift6-modernization / accountdetail-leak-
//  cycle-and-hermetic-network): proves the SHARED TPPNetworkExecutor — the one
//  `AccountsManager.fallbackDirectRefresh` uses — routes through
//  NoNetworkURLProtocol in unit tests, so it cannot escape to the real
//  `registry.palaceproject.io`. `URLProtocol.registerClass` only covers
//  `URLSession.shared`; the executor builds its own `URLSession(configuration:)`,
//  which consults only `config.protocolClasses` — closed by AppContainer's
//  non-DEBUG `testExecutorProtocolClasses` seam (set in PalaceTestSetup).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ExecutorNetworkHermeticityTests: XCTestCase {

    /// A GET to a non-stub host through the shared executor must be BLOCKED
    /// (fast failure), never a real network request. If the #3 seam regresses,
    /// this either succeeds (real response) or times out at the executor's real
    /// request timeout instead of failing immediately with the stub's error.
    func testSharedExecutor_GETToNonStubHost_isBlocked_notRealNetwork() {
        let executor = AppContainer.production().networkExecutor
        let exp = expectation(description: "executor GET completes")
        var capturedError: Error?
        var didSucceed = false

        executor.GET(
            URL(string: "https://registry.palaceproject.io/libraries")!,
            useTokenIfAvailable: false
        ) { result in
            switch result {
            case .success:        didSucceed = true
            case .failure(let error, _): capturedError = error
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5.0)

        // The decisive proof the executor honors the stub: WITHOUT
        // NoNetworkURLProtocol installed on its session, this GET reaches the real
        // `registry.palaceproject.io` and SUCCEEDS (that is the exact regression
        // this guards — verified: it did succeed before the seam landed). WITH the
        // stub, the request is intercepted and fails immediately. We assert the
        // OUTCOME (not-success + a failure), not the error identity: the executor's
        // responder wraps the underlying URLError into its own "Api call with
        // failure HTTP status" error, so NoNetworkURLProtocol's raw message is not
        // surfaced — but the request never left the process.
        XCTAssertFalse(didSucceed,
            "shared executor GET to a non-stub host must NOT reach the real network "
            + "(a success here means the #3 protocol-class seam regressed)")
        XCTAssertNotNil(capturedError,
            "the GET must FAIL (blocked by the stub), not return a real response")
    }
}

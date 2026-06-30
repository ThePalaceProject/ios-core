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

// Subclasses PalaceTestCase (not bare XCTestCase): it reads
// `AppContainer.production()` (the SHARED executor is exactly what this test must
// verify), which trips the TearDownRequiredLint — inheriting the `*TestCase` base
// satisfies it + adds the quiescence floor. The `.production()` read carries a
// per-line `// MIGRATED-DEFERRED` marker (AppContainerIsolationLint) because the
// production shared executor IS the contract here — a makeTestAppContainer()
// executor would not prove the PRODUCTION path is hermetic.
final class ExecutorNetworkHermeticityTests: PalaceTestCase {

    /// A GET to a non-stub host through the shared executor must be BLOCKED
    /// (fast failure), never a real network request. If the #3 seam regresses,
    /// this either succeeds (real response) or times out at the executor's real
    /// request timeout instead of failing immediately with the stub's error.
    func testSharedExecutor_GETToNonStubHost_isBlocked_notRealNetwork() {
        let executor = AppContainer.production().networkExecutor // MIGRATED-DEFERRED: swarm_47883816 — #3 guard MUST read the production shared executor (a test-container executor wouldn't prove the production path is hermetic)
        let target = "registry.palaceproject.io/libraries"
        // Positive-proof baseline: interceptions of THIS request before our GET
        // (the host app may have hit it during launch). We assert a strict
        // increment after, which proves OUR request was blocked by the stub —
        // not merely that it failed.
        let interceptionsBefore = NoNetworkURLProtocol.interceptionCount(matching: target)
        let exp = expectation(description: "executor GET completes")
        var capturedError: Error?
        var didSucceed = false

        executor.GET(
            URL(string: "https://\(target)")!,
            useTokenIfAvailable: false
        ) { result in
            switch result {
            case .success:        didSucceed = true
            case .failure(let error, _): capturedError = error
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5.0)

        // DECISIVE positive proof: the GET was intercepted by NoNetworkURLProtocol
        // on the EXECUTOR'S OWN session. Outcome-only checks (not-success + error)
        // are confounded — a missing network, or a non-2xx from a request that
        // ESCAPED to the real host, satisfy them too. The interception increment
        // rules both out: if the #3 protocol-class seam regressed, the stub is
        // absent from the executor's session, our request escapes, and this count
        // does NOT move → the test fails exactly when hermeticity is broken.
        XCTAssertGreaterThan(
            NoNetworkURLProtocol.interceptionCount(matching: target), interceptionsBefore,
            "the shared executor's session must route THIS GET through "
            + "NoNetworkURLProtocol (no increment ⇒ the #3 seam regressed and the "
            + "request escaped to the real registry)")
        // Outcome corroboration: WITH the stub the request fails immediately; the
        // responder wraps the underlying URLError into its own failure, so we
        // assert the OUTCOME (not-success + a failure), not the error identity.
        XCTAssertFalse(didSucceed,
            "shared executor GET to a non-stub host must NOT reach the real network "
            + "(a success here means the #3 protocol-class seam regressed)")
        XCTAssertNotNil(capturedError,
            "the GET must FAIL (blocked by the stub), not return a real response")
    }
}

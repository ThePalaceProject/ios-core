//
//  XCTestCase+fakeDownloadTask.swift
//  PalaceTests
//
//  Returns a `URLSessionDownloadTask` suitable for identity / equality
//  comparisons in tests. The task is constructed against an ephemeral
//  URLSession whose only registered protocol is `NoNetworkURLProtocol`,
//  so even if a buggy test calls `.resume()` it will fail loudly with
//  `NSURLErrorNotConnectedToInternet` instead of escaping to real network.
//
//  Replaces 16 `URLSession.shared.downloadTask(with: ...)` sites in
//  PalaceTests/MyBooks/. Those sites construct a task *only* to hand a
//  concrete `URLSessionDownloadTask` to a SUT that takes one for identity
//  comparison — none of them ever resume the task. Hitting URLSession.shared
//  was a smell: any future change that DOES resume (refactor, mistake) would
//  leak to real network from a unit test.
//

import Foundation
import XCTest

extension XCTestCase {

    /// Returns a `URLSessionDownloadTask` for use as an identity / equality
    /// stand-in in tests. The task is created from an ephemeral session
    /// whose protocol stack is `NoNetworkURLProtocol` — never resume it,
    /// but if you accidentally do, the request will be blocked with
    /// `NSURLErrorNotConnectedToInternet` instead of leaking to real HTTP.
    ///
    /// - Parameter url: A throwaway URL. Defaults to a hostname under the
    ///   `palace-test.invalid` namespace (`.invalid` is an IANA-reserved
    ///   non-resolvable TLD), so the safety net actually engages on accidental
    ///   `.resume()` — `NoNetworkURLProtocol.canInit` filters on host, and a
    ///   `file://` default would slip past with nil-host.
    func fakeDownloadTask(
        url: URL = URL(string: "https://palace-test.invalid/fake-download") ?? URL(filePath: "/dev/null")
    ) -> URLSessionDownloadTask {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkURLProtocol.self]
        return URLSession(configuration: config).downloadTask(with: url)
    }
}

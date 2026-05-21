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
    /// - Parameter url: A throwaway URL. Defaults to a non-routable file
    ///   URL so identity comparisons are stable across runs without
    ///   incurring a force-unwrap on the default value.
    func fakeDownloadTask(
        url: URL = URL(filePath: "/dev/null/palace-fake-download-task")
    ) -> URLSessionDownloadTask {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkURLProtocol.self]
        return URLSession(configuration: config).downloadTask(with: url)
    }
}

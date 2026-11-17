//  XCTestCase+fakeDownloadTask.swift
//
//  Returns a `URLSessionDownloadTask` for identity comparisons in tests, built on
//  an ephemeral session whose only protocol is `NoNetworkURLProtocol`, so a
//  `.resume()` fails with `NSURLErrorNotConnectedToInternet` instead of reaching
//  the network. Used by PalaceTests/MyBooks/ in place of
//  `URLSession.shared.downloadTask(with:)`.

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

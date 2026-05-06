//
//  TPPProcessInfo.swift
//  Palace
//
//  Lightweight helpers for inspecting the current process environment.
//

import Foundation

@objcMembers
final class TPPProcessInfo: NSObject {

    /// True when the process is running under XCTest. The XCTest harness sets
    /// `XCTestConfigurationFilePath` and `XCTestSessionIdentifier` env vars
    /// before launching the app, so checking either is reliable.
    ///
    /// Use this to gate side-effecting startup code (Firebase, Crashlytics,
    /// Transifex, analytics, remote config) that would otherwise hit real
    /// network endpoints during tests, leak dispatch state, and corrupt the
    /// libdispatch state of subsequent test executions.
    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
    }
}

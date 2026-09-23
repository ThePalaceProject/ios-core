//
//  TPPURLSettingsProviderMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceAuth
@testable import Palace

/// `@unchecked Sendable`: this mock is passed into the `@MainActor`
/// `TPPSignInBusinessLogic` SUT across an isolation boundary in sign-in tests,
/// so it must be `Sendable`. Its single mutable stored property
/// (`accountMainFeedURL`) is guarded by an `NSLock` via a locked computed
/// accessor — mirroring `TPPSignInOutBusinessLogicUIDelegateMock` /
/// `TPPBookRegistryMock`. The `universalLinksURL` requirement is a constant.
/// Property names, types, and protocol conformances are preserved so no call
/// site changes.
class TPPURLSettingsProviderMock: NSObject, NYPLUniversalLinksSettings, NYPLFeedURLProvider, UniversalLinksProviding, @unchecked Sendable {

    private let lock = NSLock()

    private var _accountMainFeedURL: URL?
    var accountMainFeedURL: URL? {
        get { lock.withLock { _accountMainFeedURL } }
        set { lock.withLock { _accountMainFeedURL = newValue } }
    }

    var universalLinksURL: URL {
        return URL(string: "https://example.com/univeral-link-redirect")!
    }
}

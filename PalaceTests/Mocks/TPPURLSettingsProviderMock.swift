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

// @unchecked Sendable: handed across isolation boundaries by Swift 6 tests
// (sending-value errors otherwise); stub state is effectively immutable.
class TPPURLSettingsProviderMock: NSObject, NYPLUniversalLinksSettings, NYPLFeedURLProvider, UniversalLinksProviding, @unchecked Sendable {
    // Mutable stub state guarded by a single NSLock (matches TPPBookRegistryMock) so the
    // @unchecked Sendable conformance is sound under concurrent test access.
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

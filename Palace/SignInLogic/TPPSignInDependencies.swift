//
//  TPPSignInDependencies.swift
//  The Palace Project
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

@objc protocol TPPBookDownloadsDeleting {
    func reset(_ libraryID: String!)
}

// Plain Swift protocol (every consumer is Swift), so the conformer need not be
// an NSObject.
protocol TPPBookRegistrySyncing {
    var isSyncing: Bool {get}
    func reset(_ libraryAccountUUID: String)
    func sync()
    func reportSyncEnded()
}

@objc protocol TPPDRMAuthorizing: NSObjectProtocol {
    var workflowsInProgress: Bool {get}
    func isUserAuthorized(_ userID: String!, withDevice device: String!) -> Bool
    func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: (@Sendable (Bool, Error?, String?, String?) -> Void)!)
    func deauthorize(withUsername username: String!, password: String!, userID: String!, deviceID: String!, completion: (@Sendable (Bool, Error?) -> Void)!)
}

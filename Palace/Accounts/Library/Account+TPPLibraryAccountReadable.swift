//
//  Account+TPPLibraryAccountReadable.swift
//  The Palace Project
//
//  Bridges the main-target `Account` class to the PalaceAuth seam protocols
//  `TPPLibraryAccountReadable` and `TPPAuthenticationDocumentReadable`.
//  Both conformances are single-line — `uuid`, `hasUpdatedToken`, etc. are
//  already stored properties on `Account` / `AccountDetails` with the right
//  shape.
//
//  This file is NOT yet wired into `Palace.xcodeproj/project.pbxproj`.
//  Impl 4 must add it to both `Palace` and `Palace-noDRM` Sources phases.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAuth

extension Account: TPPLibraryAccountReadable {
    // `uuid: String` and `hasUpdatedToken: Bool` are already public stored
    // properties on `Account`; the conformance is purely a marker that the
    // class fits the seam shape.
}

extension AccountDetails: TPPAuthenticationDocumentReadable {
    // `userProfileUrl: String?`, `signUpUrl: URL?`, `supportsSimplyESync: Bool`
    // are already stored properties on `AccountDetails` with the right shape.
}

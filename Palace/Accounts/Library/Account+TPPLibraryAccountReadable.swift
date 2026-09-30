//
//  Account+TPPLibraryAccountReadable.swift
//  The Palace Project
//
//  Bridges the main-target `Account` class to the PalaceAuth seam protocols
//  `TPPLibraryAccountReadable` and `TPPAuthenticationDocumentReadable`.
//  The requirements are already satisfied by existing stored properties.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAuth

extension Account: TPPLibraryAccountReadable {
}

extension AccountDetails: TPPAuthenticationDocumentReadable {
}

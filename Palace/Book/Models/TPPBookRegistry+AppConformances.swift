//
//  TPPBookRegistry+AppConformances.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookRegistry

/// App-target conformance of the package `TPPBookRegistry` to the app-side
/// `TPPBookRegistrySyncing` protocol (declared in `TPPSignInBusinessLogic.swift`).
/// The protocol's consumers are all app-target, so the conformance lives here
/// rather than in the package.
extension TPPBookRegistry: TPPBookRegistrySyncing {}

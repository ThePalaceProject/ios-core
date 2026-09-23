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
/// The protocol stays app-side (its consumers — BookDetailViewModel,
/// AccountDetailViewModel, DeveloperSettingsViewModel, SignInBusinessLogic — are
/// all app-target), so the conformance is declared here rather than in the package
/// (god-class decomposition Wave 2b, §2.2). `isSyncing`, `reset(_:)`, and `sync()`
/// are already public on `TPPBookRegistry`, so this is a pure declaration.
extension TPPBookRegistry: TPPBookRegistrySyncing {}

//
//  NYPLADEPT+TPPDRMAuthorizing.swift
//  The Palace Project
//
//  Conformance shim for the Adobe DRM authorizer. Lives in the main target
//  (NOT the package) because `NYPLADEPT` is a main-target ObjC++ class with
//  ADEPT framework dependencies that cannot ship inside an SPM module.
//
//  The `TPPDRMAuthorizing` protocol declaration is currently still in main
//  target (`Palace/SignInLogic/TPPSignInBusinessLogic.swift`) — when
//  TPPSignInBusinessLogic eventually moves into PalaceAuth, this file will
//  switch to `import PalaceAuth` and the protocol will live there.
//
//  This file is NOT yet wired into `Palace.xcodeproj/project.pbxproj`.
//  Impl 4 must add it to both `Palace` and `Palace-noDRM` targets via
//  `scripts/pbxproj_add_swift.rb` or hand-edit, gated by the existing
//  `#if FEATURE_DRM_CONNECTOR` so the noDRM target's Swift compile sees
//  an empty file.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR
extension NYPLADEPT: TPPDRMAuthorizing {}
#endif

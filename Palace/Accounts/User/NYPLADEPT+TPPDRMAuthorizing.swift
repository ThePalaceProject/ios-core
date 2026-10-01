//
//  NYPLADEPT+TPPDRMAuthorizing.swift
//  The Palace Project
//
//  Conformance shim for the Adobe DRM authorizer. Lives in the main target
//  (NOT the package) because `NYPLADEPT` is a main-target ObjC++ class with
//  ADEPT framework dependencies that cannot ship inside an SPM module.
//  Gated by `FEATURE_DRM_CONNECTOR` so the noDRM target compiles an empty file.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR
extension NYPLADEPT: TPPDRMAuthorizing {}
#endif

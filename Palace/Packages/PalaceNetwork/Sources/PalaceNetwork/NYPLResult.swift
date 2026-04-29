//
//  NYPLResult.swift
//  The Palace Project
//
//  Result type carrying a TPPUserFriendlyError on failure so callers can
//  surface useful messaging without a downcast. Lives in PalaceNetwork so
//  it can be referenced from TPPRequestExecuting and from package-level
//  consumers.
//

import Foundation

public enum NYPLResult<SuccessInfo> {
    case success(SuccessInfo, URLResponse?)
    case failure(TPPUserFriendlyError, URLResponse?)
}

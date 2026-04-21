//
//  MockCredentialsProvider.swift
//  PalaceTests
//
//  Shared mock for NYPLBasicAuthCredentialsProvider.
//  Extracted from TPPBasicAuthTests for reuse across test files.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

final class MockCredentialsProvider: NSObject, NYPLBasicAuthCredentialsProvider {
    var username: String?
    var pin: String?
}

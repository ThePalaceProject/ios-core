//
//  OPDS2AuthenticationDocument.swift
//  The Palace Project
//
//  Created by Benjamin Anderman on 5/10/19.
//  Copyright © 2019 NYPL Labs. All rights reserved.
//

import Foundation

public enum OPDS2LinkRel: String, Sendable {
    case passwordReset = "http://librarysimplified.org/terms/rel/patron-password-reset"
}

public struct Announcement: Codable, Sendable {
    public let id: String
    public let content: String
}

public struct OPDS2AuthenticationDocument: Codable, Sendable {
    public struct Features: Codable, Sendable {
        public let disabled: [String]?
        public let enabled: [String]?
    }

    public struct Authentication: Codable, Sendable {
        public struct Inputs: Codable, Sendable {
            public struct Input: Codable, Sendable {
                public let barcodeFormat: String?
                public let maximumLength: UInt?
                public let keyboard: String // TODO: Use enum instead (or not; it could break if new values are added)
            }

            public let login: Input
            public let password: Input
        }

        public struct Labels: Codable, Sendable {
            public let login: String
            public let password: String
        }

        public let inputs: Inputs?
        public let labels: Labels?
        public let type: String
        public let description: String?
        public let links: [OPDS2Link]?
    }

    public let features: Features?
    public let links: [OPDS2Link]?
    public let title: String
    public let authentication: [Authentication]?
    public let serviceDescription: String?
    public let colorScheme: String?
    public let announcements: [Announcement]?
    public let id: String

    static public func fromData(_ data: Data) throws -> OPDS2AuthenticationDocument {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase

        return try jsonDecoder.decode(OPDS2AuthenticationDocument.self, from: data)
    }
}

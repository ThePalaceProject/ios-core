//
//  OPDS2AuthenticationDocument.swift
//  The Palace Project
//
//  Created by Benjamin Anderman on 5/10/19.
//  Copyright © 2019 NYPL Labs. All rights reserved.
//

import Foundation

enum OPDS2LinkRel: String {
  case passwordReset = "http://librarysimplified.org/terms/rel/patron-password-reset"
}

struct Announcement: Codable {
  let id: String
  let content: String
}

struct OPDS2AuthenticationDocument: Codable {
  struct Features: Codable {
    let disabled: [String]?
    let enabled: [String]?
  }
  
  struct Authentication: Codable {
    struct Inputs: Codable {
      struct Input: Codable {
        let barcodeFormat: String?
        let maximumLength: UInt?
        let keyboard: String // TODO: Use enum instead (or not; it could break if new values are added)
      }
      
      let login: Input
      let password: Input
    }
    
    struct Labels: Codable {
      let login: String
      let password: String
    }
    
    let inputs: Inputs?
    let labels: Labels?
    let type: String
    let description: String?
    let links: [OPDS2Link]?
  }
  
  let features: Features?
  let links: [OPDS2Link]?
  let title: String
  let authentication: [Authentication]?
  let serviceDescription: String?
  let colorScheme: String?
  let announcements: [Announcement]?
  let id: String
//
//  static func fromData(_ data: Data) throws -> OPDS2AuthenticationDocument {
//    let jsonDecoder = JSONDecoder()
//    jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
//
//    return try jsonDecoder.decode(OPDS2AuthenticationDocument.self, from: data)
//  }
  
  static func fromData(_ data: Data) throws -> OPDS2AuthenticationDocument {
    let jsonDecoder = JSONDecoder()
    jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    
    let decodedData = try jsonDecoder.decode(OPDS2AuthenticationDocument.self, from: data)
    
    // Convert back to JSON for pretty printing
    let jsonEncoder = JSONEncoder()
    jsonEncoder.outputFormatting = .prettyPrinted // This will pretty print the JSON
    
    let jsonData = try jsonEncoder.encode(decodedData)
    if let jsonString = String(data: jsonData, encoding: .utf8) {
      print(jsonString)
    }
    
    return decodedData
  }
}

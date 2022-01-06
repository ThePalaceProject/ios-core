//
//  TPPSecretsTests.swift
//  PalaceTests
//
//  Created by Maurice Work on 1/3/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import XCTest

class TPPSecretsTests: XCTestCase {

  let testJSON = Bundle.init(for: TPPSecretsTests.self)
    .url(forResource: "MockAPIKeys", withExtension: "json")!
  
    func testExample() throws {
      let data = try! Data(contentsOf: testJSON)
      let dict = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: [String: Any]]
      let string =  Scripts().scripts(fromDictionary: dict)
      
    }
}

class Scripts {
  // These are the keys for extracting data from APIKeys.json
  private let secretKey = "secret"
  private let infoKey = "info"
  private let feedbooksKey = "feedbooks"
  private let drmCertificateKey = "drmCertificate"
  
  // For obfuscating keys
  private let obfuscator = Obfuscator(salt: ObfuscatedConstants.obfuscatedString)
  
  /// Required framework imports
  private let importedFrameworks = """
    import Foundation


    """
  
  /// During code generation, this will contain the code for AudioBookVendors type.
  private var audioBookVendors = ""
  
  /// The introductory section of code for t the main TPPSecrets type.
  private let mainTypeName = """
    class TPPSecrets: NSObject {

    """
  
  // MARK: - Public function
  
  /// Generates Swift code for the entire "Secrets" file that will be saved
  /// to disk.
  func scripts(fromDictionary dict: [String: [String: Any]]) -> String {
    var mainTypeBody = "  private static let salt: [UInt8] = \(ObfuscatedConstants.obfuscatedString)\n\n"
    
    // Add secret and info to script if they exist, sorting by key names
    for (name, d) in Array(dict).sorted(by: {$0.0 < $1.0}) {
      // Handle feedbooks (keys and info for multiple vendors)
      if name == feedbooksKey, let detail = d as? [String: [String:Any]] {
        mainTypeBody.append(feedbooksScript(from: detail))
      } else {
        mainTypeBody.append(feedbooksScript(from: [:]))
      }
      
      if name == drmCertificateKey, let detail = d as? [String: String] {
        mainTypeBody.append(drmCertificateScript(from: detail))
      }
      
      // Single Key
      if let secret = d[secretKey] as? String {
        mainTypeBody.append(secretScript(name: name, secret: obfuscator.bytes(byObfuscatingString: secret)))
      }
      // Single Info
      if let info = d[infoKey] as? [String:Any] {
        mainTypeBody.append(variableScript(name: name + "Info", info: info))
      }
    }
    
    return importedFrameworks + audioBookVendors + mainTypeName + mainTypeBody + decodeFunction() + "}"
  }
  
  // Scripts for DRM certificates only
  
  private func drmCertificateScript(from dict: [String: String]) -> String {
    var keys = [String: [UInt8]]()
    
    for (vendor, certificate) in dict {
      keys[vendor] = obfuscator.bytes(byObfuscatingString: certificate)
    }
    
    return multipleKeysScript(declaration: "drmCertificate(forVendor name: AudioBookVendors)", keys: keys)
  }
  
  // Scripts for feedbooks only
  private func feedbooksScript(from dict: [String: [String:Any]]) -> String {
    // Scripts
    var vendorEnum = """
    enum AudioBookVendors: String, CaseIterable {

    """
    var result = ""
    
    // Keys and info
    var keys = [String: [UInt8]]()
    var info = [String: [String : Any]]()
    
    // Extract keys and info, add enum case to extra declaration
    for (name, d) in dict {
      vendorEnum.append("""
        case \(name) = \"\(name)\"

      """)
      
      if let secret = d[secretKey] as? String {
        keys[name] = obfuscator.bytes(byObfuscatingString: secret)
      }
      
      if let i = d[infoKey] as? [String:Any] {
        info[name] = i
      }
    }
    
    // Update Extra Declaration
    vendorEnum.append("}\n\n")
    audioBookVendors.append(vendorEnum)
    
    // Script for multiple keys
    result.append(multipleKeysScript(declaration: "feedbookKeys(forVendor name: AudioBookVendors)", keys: keys))
    
    // Script for multiple info
    result.append(multipleInfoScript(declaration: "feedbookInfo(forVendor name: AudioBookVendors)", info: swiftDictionary(byTranslatingJson: info)))
    
    return result
  }
  
  // Scripts for multiple keys
  // Example for declaration: "feedbookKeys(forVendor name : AudioBookVendors)"
  // Always use "name" as the parameter name
  // Parameter should always be an Enum type, it uses the raw value of the enum as a key to extract the data
  private func multipleKeysScript(declaration: String, keys: [String: [UInt8]]) -> String {
    return """
      static func \(declaration) -> String? {
        let allKeys : [String: [UInt8]] = \(keys)
        guard let encoded = allKeys[name.rawValue] else { return nil }
        return decode(encoded, cipher: salt)
      }


    """
  }
  
  // Scripts for multiple info
  // Usage: same as above
  private func multipleInfoScript(declaration: String, info: String) -> String {
    return """
      static func \(declaration) -> [String: Any] {
        let info : [String: [String: Any]] = \(info)
        return info[name.rawValue] ?? [:]
      }


    """
  }
  
  // Single Key/Info
  private func variableScript(name: String, info: [String:Any]) -> String {
    let jsonString = swiftDictionary(byTranslatingJson: info)
    
    return """
      static var \(name): [String: Any] {
        return \(jsonString)
      }


    """
  }
  
  private func secretScript(name: String, secret: [UInt8]) -> String {
    return """
      @objc static var \(name): String? {
        let encoded: [UInt8] = \(secret)
        return decode(encoded, cipher: salt)
      }
        

    """
  }
  
  /// Generates swift code for the function that decodes the key.
  private func decodeFunction() -> String {
    return """
      private static func decode(_ encoded: [UInt8], cipher: [UInt8]) -> String? {
        var decrypted = [UInt8]()
        for k in encoded.enumerated() {
          decrypted.append(k.element ^ cipher[((k.offset + 3) * 7) % cipher.count])
        }
        return String(bytes: decrypted, encoding: .utf8)
      }
    
    """
  }
  
  // Helper - transform a JSON dictionary to a string of dictionary in Swift syntax
  private func swiftDictionary(byTranslatingJson json: [String:Any]) -> String {
    do {
      // Encode dictionary into json string in order to output it in correct format in a swift file
      let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes, .prettyPrinted])
      guard let jsonString = String(data: jsonData, encoding: .utf8) else {
        return ""
      }
      
      var modifiedString = jsonString
      modifiedString = modifiedString.replacingOccurrences(of: "\n{", with: "\n[")
      modifiedString = modifiedString.replacingOccurrences(of: "{\n", with: "[\n")
      modifiedString = modifiedString.replacingOccurrences(of: "\n}", with: "\n  ]")
      modifiedString = modifiedString.replacingOccurrences(of: "}\n", with: "  ]\n")
      modifiedString = modifiedString.replacingOccurrences(of: "},\n", with: "  ],\n")
      
      return modifiedString
    } catch {
      ConsoleIO().writeMessage("Failed to translate JSON data to Swift code")
    }
    return ""
  }
}

// MARK: - File I/O

class FileHandler {
  private var inputPath = "../Certificates/Palace/iOS/APIKeys.json"
  private let outputPath = "/Palace"
  private let outputFilename = "/TPPSecrets.swift"
  
  let consoleIO = ConsoleIO()
  
  // MARK: - Read/Write File
  
  func handleJSONFile() {
    let pathURL = URL(fileURLWithPath: inputPath)
    
    do {
      let data = try Data(contentsOf: pathURL, options: .mappedIfSafe)
      let result = try JSONSerialization.jsonObject(with: data, options: .mutableLeaves)
      if let jsonDict = result as? [String: [String: Any]] {
        let scripts = Scripts().scripts(fromDictionary: jsonDict)
        writeToSwiftFile(with: scripts)
      } else {
        handleInvalidFile()
      }
    } catch {
      handleInvalidFile()
    }
  }
  
  func writeToSwiftFile(with message: String) {
    let path = FileManager.default.currentDirectoryPath.appending(outputPath + outputFilename)
    
    do {
      try message.write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
    } catch {
      consoleIO.writeMessage(writeToFileFailureMessage, to: .error)
    }
  }
  
  // MARK: - Input Setting
  
  func setInputPath(to path: String) {
    inputPath = path
  }
  
  // MARK: - Warnings
  
  func printUsage() {
    consoleIO.printUsage()
  }
  
  func handleInvalidFile() {
    consoleIO.writeMessage(accessFileFailureMessage, to: .error)
  }
}

// MARK: Main

//let fileHandler = FileHandler()
//
//let argCount = CommandLine.argc
//let arguments = CommandLine.arguments
//
//if argCount == 1 {
//  fileHandler.handleJSONFile()
//} else if argCount == 2 {
//  if (arguments[1] == "-h") {
//    fileHandler.printUsage()
//  } else {
//    fileHandler.setInputPath(to: arguments[1])
//    fileHandler.handleJSONFile()
//  }
//} else {
//  fileHandler.printUsage()
//}

class Obfuscator {
  
  // MARK: - Variables
  
  // Console Output
  let consoleIO = ConsoleIO()
  
  private var salt: [UInt8]
  
  // MARK: - Initialization
  
  init(salt: [UInt8]) {
    self.salt = salt
  }
  
  // MARK: - Obfuscation/Reveal
  func bytes(byObfuscatingString string: String) -> [UInt8] {
    let text = [UInt8](string.utf8)
    let cipher = self.salt
    let length = cipher.count
    
    var encrypted = [UInt8]()
    
    for t in text.enumerated() {
      encrypted.append(t.element ^ cipher[((t.offset + 3) * 7) % length])
    }
    
    //      #if DEBUG
    //      consoleIO.writeMessage("Salt used: \(self.salt)\n")
    //      consoleIO.writeMessage("Swift Code:\n************")
    //      consoleIO.writeMessage("// Original \"\(string)\"")
    //      consoleIO.writeMessage("let key: [UInt8] = \(encrypted)\n")
    //      #endif
    
    return encrypted
  }
}

enum ObfuscatedConstants {
  static let obfuscatedString: [UInt8] = [41, 197, 130, 122, 252, 240, 168, 236, 84, 188, 78, 230, 199, 121, 131, 237, 90, 163, 192, 251]
}

class ConsoleIO {
  func printUsage() {
    let executableName = (CommandLine.arguments[0] as NSString).lastPathComponent
    
    writeMessage("""

    PURPOSE

    This script can be used to obfuscate keys from a JSON file into a generated
    .swift file. The input JSON file is currently `Palace/iOS/APIKeys.json`.

    USAGE

    The main use case is for Palace: please make sure the Certificates repo
    is a sibling of the Palace `ios-core` repo, and run this script from the
    repo root directory. This will generate or overwrite the existing
    <ios-core root>/Palace/TPPSecrets.swift by default:

      swift ../Certificates/Palace/iOS/\(executableName)

    You can also manully choose the path of the input JSON:

      swift ../Certificates/Palace/iOS/\(executableName) <input path>

    """)
  }
  
  func writeMessage(_ message: String, to: OutputType = .standard) {
    switch to {
    case .standard:
      print("\(message)")
    case .error:
      fputs("Error: \(message)\n", stderr)
    }
  }
}


let createFileSucceedMessage = "Successfully created TPPSecrets.swift."
let writeToFileFailureMessage = "Failed to write to TPPSecrets.swift. Please try again."
let accessFileFailureMessage = "Invalid file path or file type."

enum OutputType {
  case error
  case standard
}

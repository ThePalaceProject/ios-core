//
//  TPPPDFTextExtractor.swift
//  Palace
//
//  Created by Vladimir Fedorov on 30.11.2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

class TPPPDFTextExtractor {
  private var textBlocks = [String]()
  // Extracts blocks of text
  // One block is not neccessarily a sentences, a line of text, or even one word -
  // depending on the software used, it can contain one-two letters only.
  func extractText(page: CGPDFPage) -> [String] {
    let stream = CGPDFContentStreamCreateWithPage(page)
    let operatorTable = CGPDFOperatorTableCreate()
    // Documentation:
    // https://developer.apple.com/documentation/coregraphics/1454118-cgpdfoperatortablesetcallback
    // PDF operators:
    // https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.3.pdf
    // "TJ" operator: an array of blocks (strings, numbers, etc)
    CGPDFOperatorTableSetCallback(operatorTable!, "TJ") { scanner, context in
      guard let context = context else { return }
      let extractor = Unmanaged<TPPPDFTextExtractor>.fromOpaque(context).takeUnretainedValue()
      extractor.handleArray(scanner: scanner)
    }
    // String operators
    for op in ["Tj", "\"", "'"] {
      CGPDFOperatorTableSetCallback(operatorTable!, op) { scanner, context in
        guard let context = context else { return }
        let extractor = Unmanaged<TPPPDFTextExtractor>.fromOpaque(context).takeUnretainedValue()
        extractor.handleString(scanner: scanner)
      }
    }
    let scanner = CGPDFScannerCreate(stream, operatorTable, Unmanaged.passUnretained(self).toOpaque())
    CGPDFScannerScan(scanner)
    
    // Release resources
    CGPDFScannerRelease(scanner)
    CGPDFOperatorTableRelease(operatorTable!)
    CGPDFContentStreamRelease(stream)
    
    return textBlocks
  }
  
  /// String operator handler
  /// - Parameter scanner: `CGPDFScannerRef`
  private func handleString(scanner: CGPDFScannerRef) {
    var pdfString: CGPDFStringRef?
    if CGPDFScannerPopString(scanner, &pdfString), let pdfString, let cfString = CGPDFStringCopyTextString(pdfString) {
      let string = cfString as String
      // Skip control sequences
      if !string[string.startIndex].isWhitespace {
        textBlocks.append(string)
      }
    }
  }
  
  /// Array operator handler
  /// - Parameter scanner: `CGPDFScannerRef`
  private func handleArray(scanner: CGPDFScannerRef) {
    var array: CGPDFArrayRef?
    guard CGPDFScannerPopArray(scanner, &array), let array else { return }
    
    var blockValue = ""
    // Iterate through the array elements
    let count = CGPDFArrayGetCount(array)
    for index in 0..<count {
      var obj: CGPDFObjectRef?
      guard CGPDFArrayGetObject(array, index, &obj), let obj else { continue }
      
      let type = CGPDFObjectGetType(obj)
      switch type {
      case .string:
        // Extract and append the string to the text
        var pdfString: CGPDFStringRef?
        if CGPDFObjectGetValue(obj, .string, &pdfString), let pdfString, let cfString = CGPDFStringCopyTextString(pdfString) {
          let string = cfString as String
          // Skip control sequences
          if !string[string.startIndex].isWhitespace {
            blockValue += string
          }
        }
      case .real:
        var realValue: CGPDFReal = 0.0
        if CGPDFObjectGetValue(obj, .real, &realValue) {
          // Real values adjust the spacing between elements (e.g., letters).
          // "100" is an empirical value large enough to represent a space between words.
          // Text in PDFs can appear as a single line of characters without whitespace characters;
          // these values adjust the visual spacing between characters.
          if abs(realValue) > 100 {
            blockValue += " "
          }
        }
      case .integer:
        var intValue: CGPDFInteger = 0
        if CGPDFObjectGetValue(obj, .integer, &intValue) {
          // The same as realValue above
          if abs(intValue) > 100 {
            blockValue += " "
          }
        }
      default:
        break
      }
    }
    textBlocks.append(blockValue)
  }
}

//
//  TPPBookCellDelegate+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//
import Foundation
import NYPLAudiobookToolkit

@objc extension TPPBookCellDelegate {
  public func saveListeningPosition(at location: String, completion: ((_ serverID: String?) -> Void)? = nil) {
    TPPAnnotations.postListeningPosition(forBook: self.book.identifier, selectorValue: location, completion: completion)
  }
}

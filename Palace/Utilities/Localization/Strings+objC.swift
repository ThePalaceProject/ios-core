//
//  Strings+objC.swift
//  Palace
//
//  Created by Vladimir Fedorov on 09/02/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

/// Makes `Strings` string properties available in Objective-C
@objcMembers
class LocalizedStrings: NSObject {
  
  // MARK: - TPPLastListenedPositionSynchronizer
  static let syncListeningPositionAlertTitle = Strings.TPPLastListenedPositionSynchronizer.syncListeningPositionAlertTitle
  static let syncListeningPositionAlertBody = Strings.TPPLastListenedPositionSynchronizer.syncListeningPositionAlertBody
  
  // MARK: - TPPLastReadPositionSynchronizer
  static let stay = Strings.TPPLastReadPositionSynchronizer.stay
  static let move = Strings.TPPLastReadPositionSynchronizer.move
  
}

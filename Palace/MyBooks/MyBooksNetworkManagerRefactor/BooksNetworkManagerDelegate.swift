//
//  BooksNetworkManagerDelegate.swift
//  Palace
//
//  Created by Maurice Carrier on 6/19/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine

protocol BooksNetworkManagerDelegate: AnyObject {
  func process(error: [String: Any]?, for book: TPPBook)
}


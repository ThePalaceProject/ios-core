//
//  ViewCoordinator.swift
//  Palace
//
//  Created by Maurice Carrier on 10/25/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

protocol ViewCoordinator: WithEvents {
  associatedtype ChildView
  var childView: ChildView? { get }
}

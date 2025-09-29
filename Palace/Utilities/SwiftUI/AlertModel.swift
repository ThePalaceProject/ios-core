//
//  AlertModel.swift
//  Palace
//
//  Created by Maurice Carrier on 2/17/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

struct AlertModel: Identifiable {
  let id = UUID()
  var title: String
  var message: String
  var buttonTitle: String?
  var primaryAction: () -> Void = {}
  var secondaryButtonTitle: String?
  var secondaryAction: () -> Void = {}
}

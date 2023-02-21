//
//  Font+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 12/5/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

extension Font {
  init(uiFont: UIFont) {
    self = Font(uiFont as CTFont)
  }
}

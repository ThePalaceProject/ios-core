//
//  BookCell.swift
//  Palace
//
//  Created by Maurice Carrier on 1/5/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct BookCell: View {
  @ObservedObject var model: BookCellModel
  var previewEnabled: Bool = true
  
  var body: some View {
    NormalBookCell(model: model, previewEnabled: previewEnabled)
  }
}

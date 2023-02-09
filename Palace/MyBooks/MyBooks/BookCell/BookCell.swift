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

  var body: some View {
    bookCell
  }
  
  @ViewBuilder private var bookCell: some View {
    switch model.state {
    case .downloading:
      DownloadingBookCell(model: model)
    default:
      NormalBookCell(model: model)
    }
  }
}

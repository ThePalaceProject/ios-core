//
//  CustomGridLayout.swift
//  Palace
//
//  Created by Maurice Carrier on 2/24/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

struct AdaptableGridLayout <Content: View>: View {
  private let gridItemLayout = [GridItem(.adaptive(minimum: 300), spacing: .zero)]
  private var isPad : Bool { UIDevice.current.userInterfaceIdiom == .pad }
  var content: () -> Content
  
  var body: some View {
    if isPad {
      LazyVGrid(columns: gridItemLayout, alignment: .leading, spacing: .zero) {
        content()
      }
    } else {
      VStack(alignment: .leading, spacing: 10) {
        content()
      }
    }
  }
}


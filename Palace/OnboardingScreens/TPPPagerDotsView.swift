//
//  TPPPagerDotsView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 09.12.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPPagerDotsView: View {
  /// Number of dots to show
  var count: Int
  /// Selected dot index
  @Binding var currentIndex: Int
  var body: some View {
    HStack(spacing: 8) {
      ForEach(0..<count) { index in
        Circle()
          .foregroundColor(index == currentIndex ? .black : .gray)
          .frame(width: 8, height: 8)
      }
    }
  }
}

struct TPPPagerDotsView_Previews: PreviewProvider {
    static var previews: some View {
      TPPPagerDotsView(count: 5, currentIndex: .constant(2))
    }
}

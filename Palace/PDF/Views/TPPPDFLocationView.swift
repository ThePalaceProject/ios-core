//
//  TPPPDFLocationView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 29.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// PDF page location view
struct TPPPDFLocationView: View {
  let location: TPPPDFLocation
  var emphasizeLevel: Int = -1
  
  init(location: TPPPDFLocation) {
    self.location = location
  }
  
  init(location: TPPPDFLocation, emphasizeLevel: Int) {
    self.location = location
    self.emphasizeLevel = emphasizeLevel
  }
  
  var body: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 4) {
        Text(location.title ?? "")
          .fontWeight(location.level <= emphasizeLevel ? .bold : .regular)
        if let subtitle = location.subtitle {
          Text(subtitle)
            .font(.subheadline)
        }
      }
      .padding(.leading, 10 * CGFloat(location.level))
      Spacer()
      Text(location.pageLabel ?? "\(location.pageNumber + 1)")
        .fontWeight(location.level <= emphasizeLevel ? .bold : .regular)
    }
    .contentShape(Rectangle())
  }
}

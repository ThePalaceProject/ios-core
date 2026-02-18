//
//  TPPPDFLocationView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 29.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

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
          .palaceFont(.headline, weight: location.level <= emphasizeLevel ? .bold : .regular)
        if let subtitle = location.subtitle {
          Text(subtitle)
            .palaceFont(.subheadline, weight: location.level <= emphasizeLevel ? .bold : .regular)
        }
      }
      .padding(.leading, 10 * CGFloat(location.level))
      Spacer()
      Text(location.pageLabel ?? "\(location.pageNumber + 1)")
        .palaceFont(.body, weight: location.level <= emphasizeLevel ? .bold : .regular)
    }
    .contentShape(Rectangle())
  }
}

struct TPPPDFLocationView_Previews: PreviewProvider {
    static var previews: some View {
      List {
        TPPPDFLocationView(location: .init(title: "Chapter 1", subtitle: "Subtitle", pageLabel: "xi", pageNumber: 11), emphasizeLevel: 1)
        TPPPDFLocationView(location: .init(title: "Chapter 1", subtitle: "Subtitle", pageLabel: "xi", pageNumber: 11))
      }
    }
}

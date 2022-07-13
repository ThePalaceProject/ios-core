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
  var body: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 4) {
        Text(location.title ?? "")
          .font(.headline)
          .fontWeight(location.level < 2 ? .bold : .regular)
        if let subtitle = location.subtitle {
          Text(subtitle)
            .font(.subheadline)
        }
      }
      .padding(.leading, 10 * CGFloat(location.level - 1))
      Spacer()
      Text(location.pageLabel ?? "\(location.pageNumber + 1)")
        .fontWeight(location.level < 2 ? .bold : .regular)
    }
    .contentShape(Rectangle())
  }
}

struct TPPPDFLocationView_Previews: PreviewProvider {
  static var previews: some View {
    TPPPDFLocationView(location: TPPPDFLocation(title: "Title", subtitle: "Subtitle", pageLabel: "A1", pageNumber: 4))
  }
}

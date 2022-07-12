//
//  TPPPDFLocationView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 29.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPPDFLocationView: View {
  let location: TPPPDFLocation
  var body: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 4) {
        Text(location.title ?? "")
          .font(.headline)
        if let subtitle = location.subtitle {
          Text(subtitle)
            .font(.subheadline)
        }
      }
      Spacer()
      Text(location.pageValue ?? "\(location.pageNumber)")
    }
  }
}

struct TPPPDFLocationView_Previews: PreviewProvider {
  static var previews: some View {
    TPPPDFLocationView(location: TPPPDFLocation(title: "Title", subtitle: "Subtitle", pageValue: "A1", pageNumber: 4))
  }
}

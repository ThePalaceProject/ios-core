//
//  FacetView.swift
//  Palace
//
//  Created by Maurice Carrer on 12/23/22.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct FacetView: View {
  @ObservedObject var model: FacetViewModel

  var body: some View {
    HStack {
      titleLabel
      facet
    }
    .padding(.vertical)
  }

  var titleLabel: some View {
    Text(model.groupName)
  }

  var facet: some View {
    Button(action: {
      print("update current facet")
    }) {
      Text(model.activeFacet.title)
        .border(.white, width: 1)
        .cornerRadius(3)
    }
  }
}

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
  @State private var showAlert = false

  var body: some View {
    HStack {
      titleLabel
      facet
    }
    .actionSheet(isPresented: $showAlert) { facetAlert }
    .font(.footnote)
    .padding(.vertical)
  }

  var titleLabel: some View {
    Text(model.groupName)
  }

  var facet: some View {
    Button(action: {
      showAlert = true
    }) {
      Text(model.activeFacet.localizedString)
    }
    .frame(width: 60, height: 30)
    .border(.white, width: 1)
    .cornerRadius(2)
  }

  private var facetAlert: ActionSheet {
    var buttons = [ActionSheet.Button]()

    if let secondaryFacet = model.facets.first(where: { $0 != model.activeFacet }) {
      buttons.append(ActionSheet.Button.default(Text(secondaryFacet.localizedString)) {
        self.model.activeFacet = secondaryFacet
      })

      buttons.append(Alert.Button.default(Text(model.activeFacet.localizedString)) {
        self.model.activeFacet = model.activeFacet
      })
    } else {
      buttons.append(ActionSheet.Button.cancel(Text(Strings.Generic.cancel)))
    }

    return ActionSheet(title: Text(""), message: Text(""), buttons:buttons)
  }
}

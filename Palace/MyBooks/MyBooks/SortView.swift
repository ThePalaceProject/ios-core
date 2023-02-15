//
//  SortView.swift
//  Palace
//
//  Created by Maurice Carrer on 12/23/22.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct SortView: View {
  @ObservedObject var model: FacetViewModel
  @State private var showAlert = false

  var body: some View {
    VStack(alignment: .leading) {
      dividerView
      HStack {
        titleLabel
        sortView
      }
      .padding(.leading)
      .actionSheet(isPresented: $showAlert) { alert }
      .font(.footnote)
      dividerView
    }
  }

  private var titleLabel: some View {
    Text(model.groupName)
  }

  private var sortView: some View {
    Button(action: {
      showAlert = true
    }) {
      Text(model.activeSort.localizedString)
    }
    .frame(width: 60, height: 30)
    .border(.white, width: 1)
    .cornerRadius(2)
  }
  
  private var dividerView: some View {
    Rectangle()
      .fill(Color(TPPConfiguration.mainColor()))
      .frame(height: 0.30)
      .edgesIgnoringSafeArea(.horizontal)
  }

  private var alert: ActionSheet {
    var buttons = [ActionSheet.Button]()

    if let secondaryFacet = model.facets.first(where: { $0 != model.activeSort }) {
      buttons.append(ActionSheet.Button.default(Text(secondaryFacet.localizedString)) {
        self.model.activeSort = secondaryFacet
      })

      buttons.append(Alert.Button.default(Text(model.activeSort.localizedString)) {
        self.model.activeSort = model.activeSort
      })
    } else {
      buttons.append(ActionSheet.Button.cancel(Text(Strings.Generic.cancel)))
    }

    return ActionSheet(title: Text(""), message: Text(""), buttons:buttons)
  }
}

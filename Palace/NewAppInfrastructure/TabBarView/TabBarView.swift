//
//  TabBarView.swift
//  Palace
//
//  Created by Maurice Carrier on 10/25/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct TabBarView: View {
  @ObservedObject var model: TabBarViewModel
  
  var body: some View {
      contentView
        .edgesIgnoringSafeArea(.bottom)
  }
  
  var contentView: some View {
    TabView {
      tabView(for: .catalog)
      tabView(for: .books)
      if model.currentAccount?.details?.supportsReservations ?? false {
        tabView(for: .reservations)
      }
      tabView(for: .settings)
    }
  }
  
  private func tabView(for item: TabBarItem) -> some View {
    BaseView(title: item.title, content: CatalogView(model: model.catalogViewModel).anyView())
      .tabItem {
          item.image
            .renderingMode(.template)
            .foregroundColor(TPPConfiguration.iconColor())
          Text(item.title)
      }
  }
}

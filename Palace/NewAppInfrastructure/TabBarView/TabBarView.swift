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
    VStack {
      contentView
    }
    .edgesIgnoringSafeArea(.bottom)
  }
  
  var contentView: some View {
    TabView {
      CatalogView(viewModel: model.catalogViewModel)
        .tabItem {
          TabBarItem.catalog.image
            .renderingMode(.template)
            .foregroundColor(TPPConfiguration.iconColor())
          Text(TabBarItem.catalog.title)
        }
      CatalogView(viewModel: model.catalogViewModel)
        .tabItem {
          TabBarItem.books.image
            .renderingMode(.template)
            .foregroundColor(TPPConfiguration.iconColor())
          Text(TabBarItem.books.title)
        }
      if model.currentAccount?.details?.supportsReservations ?? false {
        CatalogView(viewModel: model.catalogViewModel)
          .tabItem {
            TabBarItem.reservations.image
              .renderingMode(.template)
              .foregroundColor(TPPConfiguration.iconColor())
            Text(TabBarItem.reservations.title)
          }
      }
      CatalogView(viewModel: model.catalogViewModel)
        .tabItem {
          TabBarItem.settings.image
            .renderingMode(.template)
            .foregroundColor(TPPConfiguration.iconColor())
          Text(TabBarItem.settings.title)
        }
    }
  }
}

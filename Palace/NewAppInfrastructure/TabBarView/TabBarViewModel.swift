//
//  RootViewCoordinator.swift
//  Palace
//
//  Created by Maurice Carrier on 10/25/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import SwiftUI

enum TabBarItem {
  case catalog, books, reservations, settings
  
  var image: Image {
    switch self {
    case .catalog:
      return Images.TabBarView.catalog
    case .books:
      return Images.TabBarView.books
    case .reservations:
      return Images.TabBarView.reservations
    case .settings:
      return Images.TabBarView.settings
    }
  }
  
  var title: String {
    switch self {
    case .catalog:
      return NSLocalizedString("Catalog", comment: "")
    case .books:
      return NSLocalizedString("MyBooksViewControllerTitle", comment: "")
    case .reservations:
      return NSLocalizedString("Reservations", comment: "")
    case .settings:
      return NSLocalizedString("Settings", comment: "")
    }
  }
}

class TabBarViewModel: WithEvents, WithContext, ObservableObject {
  typealias Event = AppEvent
  
  @Published var selectedView: TabBarItem = .catalog
  @Published var currentAccount: Account?

  let context: AppContext
  let eventInput = EventSubject()
  var eventObserver: AnyCancellable?
  
  lazy var catalogViewModel = CatalogViewModel(context: context)

  private var contextObservers = Set<AnyCancellable>()
  
  init(context: AppContext) {
    self.context = context

    self.context.selectedTabBarViewPublisher
      .assign(to: \.selectedView, onWeak: self)
      .store(in: &contextObservers)
    
    self.context.accountPublisher
      .assign(to: \.currentAccount, onWeak: self)
      .store(in: &contextObservers)
  }
}

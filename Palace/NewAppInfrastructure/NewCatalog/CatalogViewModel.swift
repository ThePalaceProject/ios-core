//
//  CatalogViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 10/25/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI
import Combine

typealias Action = () -> Void

protocol CatalogViewModelShape {
  var title: String { get set }
  var logoImage: Image { get set }
  var homeURL: String { get set }
  var facetGroups: [TPPCatalogFacetGroup] { get set }
  var nextURL: String { get set }
  var openSearchURL: String { get set }
  var sections: [CatalogSection] { get set }

  func refresh()
}

protocol CatalogSection {
  var title: String? { get set }
  var auxillaryButtonTitle: String? { get set }
  var auxillaryButtonAction: Action? { get set }
  var books: [TPPBook] { get set }
}

class CatalogViewModel: NSObject, CatalogViewModelShape, WithContext {
  var context: AppContext

  private var account: Account? {
    didSet {
      guard let account = account else { return }
      title = account.name
      homeURL = account.homePageUrl ?? ""
    }
  }
  
  var title: String = ""
  var logoImage: Image = Images.Shared.accountLogoPlaceholder
  var homeURL: String = ""
  var facetGroups: [TPPCatalogFacetGroup] = []
  var nextURL: String = ""
  var openSearchURL: String = ""
  var sections: [CatalogSection] = []
  
  typealias Event = AppEvent
  let eventInput = AppEventSubject()
  var eventObserver: AnyCancellable?
  var accountObserver: AnyCancellable?

  init(context: AppContext) {
    self.context = context
    
    super.init()
    accountObserver = context.accountPublisher
      .compactMap { $0 }
      .assign(to: \.account, onWeak: self)
  }

  func refresh() {
    
  }
}


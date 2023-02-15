//
//  FacetViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine

enum Facet: String {
  case author
  case title
  
  var localizedString: String {
    switch self {
    case .author:
      return Strings.FacetView.author
    case .title:
      return Strings.FacetView.title
    }
  }
}

class FacetViewModel: ObservableObject {
  @Published var groupName: String
  @Published var facets: [Facet]
  
  @Published var activeSort: Facet
  
  init(groupName: String, facets: [Facet]) {
    self.facets = facets
    self.groupName = groupName
    activeSort = facets.first!
  }
}

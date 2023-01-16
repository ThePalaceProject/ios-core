//
//  FacetViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine

struct Facet {
  var title: String
}

class FacetViewModel: ObservableObject {
  @Published var groupName: String
  @Published var facets: [Facet]
  
  @Published var activeFacet: Facet = facets.first
}

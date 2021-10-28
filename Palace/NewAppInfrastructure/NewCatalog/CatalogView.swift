//
//  CatalogView.swift
//  Palace
//
//  Created by Maurice Work on 10/26/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI

struct CatalogView: View {
  
  var viewModel: CatalogViewModel
  
  var body: some View {
    Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
  }
}

#if DEBUG
struct CatalogView_Previews: PreviewProvider {
  static var previews: some View {
    CatalogView(viewModel: CatalogViewModel(context: AppContextProvider()))
  }
}
#endif

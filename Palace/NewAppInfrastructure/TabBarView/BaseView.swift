//
//  BaseView.swift
//  Palace
//
//  Created by Maurice Carrier on 10/29/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI

struct BaseView: View {
  
  var title: String
  var content: AnyView

  var body: some View {
    NavigationView {
      content
        .navigationBarTitle(Text(title), displayMode: .inline)
        .navigationBarItems(leading: accountButton, trailing: searchButton)
    }
    
  }
  
  var accountButton: some View {
    Button {
      print("Launch Account Picker")
    } label: {
      Images.Shared.palaceLogo
    }
  }
  
  var searchButton: some View {
    Button {
      print("Launch Search View")
    } label: {
      Images.Shared.searchIcon
    }
  }
}

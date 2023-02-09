//
//  ButtonView.swift
//  Palace
//
//  Created by Maurice Carrier on 2/8/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

struct ButtonView: View {
  
  var title: String
  var backgroundFill: Color? = nil
  var action: () -> Void
    
  var body: some View {
    Button (action: action) {
      Text(title)
        .padding()
    }
    .frame(height: 35)
    .buttonStyle(.plain)
    .background(backgroundFill)
    .overlay(
      RoundedRectangle(cornerRadius: 3)
        .stroke(backgroundFill ?? Color(TPPConfiguration.mainColor()), lineWidth: 1)
    )
  }
}

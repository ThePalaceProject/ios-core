//
//  TPPPDFLabel.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import PalaceUIKit
import SwiftUI

/// Floating label
///
/// PDF name, page number
struct TPPPDFLabel: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .palaceFont(.subheadline, weight: .semibold)
      .multilineTextAlignment(.center)
      .padding(.horizontal)
      .padding(.vertical, 6)
      .foregroundColor(.white)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .foregroundColor(.black)
          .opacity(0.6)
      )
  }
}

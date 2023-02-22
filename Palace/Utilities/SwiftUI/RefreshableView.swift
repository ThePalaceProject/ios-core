//
//  RefreshableView.swift
//  Palace
//
//  Created by Maurice Carrier on 2/22/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

typealias Action = () -> Void

struct RefreshableScrollView: ViewModifier {
  var onRefresh: Action

  private var topPadding = 50.0
  @State private var needRefresh: Bool = false
  private let coordinatorSpaceName = "RefreshingView"
  
  init(_ refreshAction: @escaping Action) {
    onRefresh = refreshAction
  }

  func body(content: Content) -> some View {
    ScrollView {
      refreshView
      content
    }
    .coordinateSpace(name: coordinatorSpaceName)
  }
  
  private var refreshView: some View {
    GeometryReader { geometry in
      if (geometry.frame(in: .named(coordinatorSpaceName)).midY > topPadding) {
        Spacer()
          .onAppear {
            needRefresh = true
          }
      } else if (geometry.frame(in: .named(coordinatorSpaceName)).midY < 10) {
        Spacer()
          .onAppear {
            if needRefresh {
              needRefresh = false
              onRefresh()
            }
          }
      }
      HStack {
        Spacer()
        if needRefresh {
          ProgressView()
            .square(length: 25)
        }
        Spacer()
      }
    }.padding(.top, -topPadding)
  }
}

//
//  UIViewControllerWrapper.swift
//  Palace
//
//  Created by Maurice Carrier on 12/4/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

struct UIViewControllerWrapper<Wrapper: UIViewController>: UIViewControllerRepresentable {
  typealias Updater = (Wrapper, Context) -> Void

  var makeView: () -> Wrapper
  var update: (Wrapper, Context) -> Void

  init(
    _ makeView: @escaping @autoclosure () -> Wrapper,
    updater update: @escaping (Wrapper) -> Void
  ) {
    self.makeView = makeView
    self.update = { view, _ in update(view) }
  }

  func makeUIViewController(context _: Context) -> Wrapper {
    makeView()
  }

  func updateUIViewController(_ uiViewController: Wrapper, context: Context) {
    update(uiViewController, context)
  }
}

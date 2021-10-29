//
//  NavigationConfigurator.swift
//  Palace
//
//  Created by Maurice Carrier on 10/28/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI

struct NavigationConfigurator: UIViewControllerRepresentable {
  var configure: (UINavigationController) -> Void = { _ in }
  
  func makeUIViewController(context: UIViewControllerRepresentableContext<NavigationConfigurator>) -> UIViewController {
    UIViewController()
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<NavigationConfigurator>) {
    if let nc = uiViewController.navigationController {
      self.configure(nc)
    }
  }
}

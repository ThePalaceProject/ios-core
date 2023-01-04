//
//  TPPMyBooksViewController.swift
//  Palace
//
//  Created by Maurice Carrier on 1/4/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

class TPPMyBooksViewController: NSObject {
  @objc static func makeSwiftUIView(dismissHandler: @escaping (() -> Void)) -> UIViewController {
    let controller = UIHostingController(rootView: MyBooksView())
    controller.title = Strings.MyBooksView.title
    controller.tabBarItem.image = UIImage(named: "MyBooks")
    let navigationController = UINavigationController(rootViewController: controller)

    return navigationController
  }
}

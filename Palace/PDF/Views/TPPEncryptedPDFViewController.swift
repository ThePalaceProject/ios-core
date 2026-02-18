//
//  TPPEncryptedPDFViewController.swift
//  Palace
//
//  Created by Vladimir Fedorov on 01.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import UIKit

/// Encrypted PDF view controller
class TPPEncryptedPDFViewController: UIPageViewController {
  
  var document: TPPEncryptedPDFDocument
  var pageCount: Int = 0
  var currentPage: Int = 0
  
  func navigate(to page: Int) {
    let direction: NavigationDirection  = page < currentPage ? .reverse : .forward
    currentPage = min(pageCount - 1, max(0, page))
    setViewControllers([pageViewController(page: currentPage)], direction: direction, animated: false, completion: nil)
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  init(encryptedPDF: TPPEncryptedPDFDocument) {
    self.document = encryptedPDF
    self.pageCount = encryptedPDF.pageCount
    super.init(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 20])
  }
  
  override func viewDidLoad() {
    view.backgroundColor = .secondarySystemBackground
    dataSource = self
    currentPage = min(pageCount, max(0, currentPage))
    setViewControllers([pageViewController(page: currentPage)], direction: .forward, animated: false)
    super.viewDidLoad()
  }
  
  func pageViewController(page: Int = 0) -> UIViewController {
    return TPPEncryptedPDFPageViewController(encryptedPdf: document, pageNumber: page)
  }

}

extension TPPEncryptedPDFViewController: UIPageViewControllerDataSource {
  func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
    guard let pageVC = viewController as? TPPEncryptedPDFPageViewController, pageVC.pageNumber > 0 else {
      return nil
    }
    return self.pageViewController(page: pageVC.pageNumber - 1)
  }
  func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
    guard let pageVC = viewController as? TPPEncryptedPDFPageViewController, pageVC.pageNumber < (pageCount - 1) else {
      return nil
    }
    return self.pageViewController(page: pageVC.pageNumber + 1)
  }
}

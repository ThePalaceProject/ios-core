//
//  TPPPDFPreviewGridController.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import UIKit

/// PDF preview grid.
///
/// Shows page previews and bookmarks in `.pdf` files.
class TPPPDFPreviewGridController: UICollectionViewController {
  
  private let preferredPreviewWidth: CGFloat = 200
  private let minimumItemsPerRow: Int = 3
  
  /// Indices of pages to show in previews.
  var indices: [Int]? {
    didSet {
      collectionView.reloadData()
    }
  }
  
  /// Current page, collection view scrolls to that page in previews
  var currentPage: Int = 0
  
  /// Defines if this view is currently visible in SwiftUI view
  ///
  /// Added to optimize data updates and generate page previews only when the view is visible to the user.
  var isVisible = false {
    didSet {
      scrollToCurrentItem()
    }
  }
  
  var delegate: TPPPDFPreviewGridDelegate?
  
  private var document: TPPPDFDocument?
  private let cellId = "cell"
  private let previewCache = NSCache<NSNumber, UIImage>()
  private let itemSpacing = 10.0

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  /// Initializes PDF preview grid.
  /// - Parameters:
  ///   - document: PDF document
  ///   - indices: When provided, the view shows previews for pages with these indices.
  init(document: TPPPDFDocument, indices: [Int]?) {
    super.init(collectionViewLayout: UICollectionViewFlowLayout())
    self.document = document
    self.indices = indices
  }

  private func pageNumber(for item: Int) -> Int {
    if let indices = indices {
      let index = max(0, min(indices.count - 1, item))
      return indices[index]
    }
    return item
  }
  
  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    previewCache.removeAllObjects()
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView.bounces = true
    collectionView.decelerationRate = .normal
    collectionView.isUserInteractionEnabled = true
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(TPPPDFPreviewGridCell.self, forCellWithReuseIdentifier: cellId)
    collectionView.backgroundColor = .secondarySystemBackground
    collectionView.contentInset = UIEdgeInsets(top: itemSpacing, left: itemSpacing, bottom: itemSpacing, right: itemSpacing)
    view.addSubview(collectionView)
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if indices == nil && currentPage < (document?.pageCount ?? 0) {
      collectionView.scrollToItem(at: IndexPath(item: currentPage, section: 0), at: .centeredVertically, animated: false)
    }
  }
  
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    DispatchQueue.main.async {
      self.collectionView.collectionViewLayout.invalidateLayout()
      self.scrollToCurrentItem()
    }
  }

  override func numberOfSections(in collectionView: UICollectionView) -> Int {
    return 1
  }
  
  override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    return indices?.count ?? document?.pageCount ?? 0
  }
  
  override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let page = self.pageNumber(for: indexPath.item)
    let key = NSNumber(value: page)
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cellId, for: indexPath) as! TPPPDFPreviewGridCell
    cell.pageNumber = page
    cell.pageLabel.text = document?.label(page: page) ?? "\(page + 1)"
    if let image = previewCache.object(forKey: key) {
      cell.imageView.image = image
    } else {
      if let pageSize = document?.size(page: page) {
        cell.imageView.image = UIImage(color: .white, size: pageSize)
      } else {
        cell.imageView.image = nil
      }
      DispatchQueue.pdfThumbnailRenderingQueue.async {
        let image: UIImage? = self.document?.preview(for: page)
        if let image = image {
          self.previewCache.setObject(image, forKey: key)
        }
        if page == cell.pageNumber {
          DispatchQueue.main.async {
            cell.imageView.image = image
          }
        }
      }
    }
    return cell
  }
  
  override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let page = pageNumber(for: indexPath.item)
    delegate?.didSelectPage(page)
  }
  
  private func scrollToCurrentItem() {
    guard isVisible else { return }

    let totalItems = indices?.count ?? document?.pageCount ?? 0
    guard currentPage >= 0, currentPage < totalItems else {
      return
    }

    let indexPath = IndexPath(item: currentPage, section: 0)
    collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
  }
}

extension TPPPDFPreviewGridController: UICollectionViewDelegateFlowLayout {
  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
    var itemsPerRow = minimumItemsPerRow
    let device = UIDevice.current
    if device.userInterfaceIdiom == .pad &&
        (device.orientation == .landscapeLeft || device.orientation == .landscapeRight) {
      itemsPerRow = max(minimumItemsPerRow, Int(collectionView.bounds.width / preferredPreviewWidth))
    }
    let contentWidth = collectionView.bounds.width
    var interitemSpace = 0.0
    if let flowLayout = collectionViewLayout as? UICollectionViewFlowLayout {
      interitemSpace += flowLayout.minimumInteritemSpacing * CGFloat(itemsPerRow - 1)
      interitemSpace += flowLayout.sectionInset.left
      interitemSpace += flowLayout.sectionInset.right
      interitemSpace += itemSpacing * CGFloat(itemsPerRow - 1)
    }
    let width = (contentWidth - interitemSpace - itemSpacing) / CGFloat(itemsPerRow)
    var height = width * 1.5
    let pageNumber = self.pageNumber(for: indexPath.item)
    if let pageSize = document?.size(page: pageNumber) {
      height = pageSize.height * (width / pageSize.width)
    }
    return CGSize(width: width, height: height)
  }
  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
    UIFont.smallSystemFontSize * 2
  }
}

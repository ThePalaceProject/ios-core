//
//  TPPPDFPreviewGridCell.swift
//  Palace
//
//  Created by Vladimir Fedorov on 23.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

class TPPPDFPreviewGridCell: UICollectionViewCell {
  
  /// Page number for the page preview image
  var pageNumber: Int?
  
  var imageView: UIImageView = {
    let imageView = UIImageView()
    imageView.backgroundColor = .secondarySystemBackground
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubviews()
  }
  
  func addSubviews() {
    addSubview(imageView)
    imageView.autoPinEdgesToSuperviewMargins()
  }
}

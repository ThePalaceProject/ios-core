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
    imageView.backgroundColor = .clear
    imageView.contentMode = .scaleAspectFit
    imageView.layer.shadowOffset = .zero
    imageView.layer.shadowRadius = 4
    imageView.layer.shadowOpacity = 0.2
    return imageView
  }()
  
  var pageLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: UIFont.smallSystemFontSize)
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    return label
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
    addSubview(pageLabel)
    imageView.autoPinEdgesToSuperviewMargins()
    pageLabel.autoPinEdge(.leading, to: .leading, of: self)
    pageLabel.autoPinEdge(.trailing, to: .trailing, of: self)
    pageLabel.autoPinEdge(.top, to: .bottom, of: self, withOffset: -UIFont.smallSystemFontSize / 4)
  }
}

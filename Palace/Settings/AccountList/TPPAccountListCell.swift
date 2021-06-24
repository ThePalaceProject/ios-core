//
//  TPPAccountListCell.swift
//  Palace
//
//  Created by Maurice Work on 6/24/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import UIKit

class TPPAccountListCell: UITableViewCell {
  
  var account: Account?
  
  init(_ account: Account) {
    super.init(style: .subtitle, reuseIdentifier: "AccountListCell")
    
    self.account = account
    setup()
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  override func awakeFromNib() {
    super.awakeFromNib()
  }
  
  private func setup() {
    accessoryType = .disclosureIndicator
    let container = UIView()
    let textContainer = UIView()
    
    let imageView = UIImageView(image: account?.logo)
    imageView.contentMode = .scaleAspectFit
    
    let textLabel = UILabel()
    textLabel.font = UIFont.systemFont(ofSize: 16)
    textLabel.text = account?.name
    textLabel.numberOfLines = 0
    
    let detailLabel = UILabel()
    detailLabel.font = UIFont(name: "AvenirNext-Regular", size: 12)
    detailLabel.numberOfLines = 0
    detailLabel.text = account?.subtitle
    
    textContainer.addSubview(textLabel)
    textContainer.addSubview(detailLabel)
    
    container.addSubview(imageView)
    container.addSubview(textContainer)
    contentView.addSubview(container)
    
    imageView.autoAlignAxis(toSuperviewAxis: .horizontal)
    imageView.autoPinEdge(toSuperviewEdge: .left)
    imageView.autoSetDimensions(to: CGSize(width: 45, height: 45))
    
    textContainer.autoPinEdge(.left, to: .right, of: imageView, withOffset: contentView.layoutMargins.left * 2)
    textContainer.autoPinEdge(toSuperviewMargin: .right)
    textContainer.autoAlignAxis(toSuperviewAxis: .horizontal)
    
    NSLayoutConstraint.autoSetPriority(UILayoutPriority.defaultLow) {
      textContainer.autoPinEdge(toSuperviewEdge: .top, withInset: 0, relation: .greaterThanOrEqual)
      textContainer.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0, relation: .greaterThanOrEqual)
    }
    
    textLabel.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .bottom)
    
    detailLabel.autoPinEdge(.top, to: .bottom, of: textLabel)
    detailLabel.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .top)
    
    container.autoPinEdgesToSuperviewMargins()
    container.autoSetDimension(.height, toSize: 55, relation: .greaterThanOrEqual)
  }
}

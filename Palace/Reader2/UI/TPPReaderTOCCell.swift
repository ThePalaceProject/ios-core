//
//  TPPReaderTOCCell.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 4/23/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import UIKit

@objc class TPPReaderTOCCell: UITableViewCell {
  @IBOutlet var titleLabel: UILabel!
  @IBOutlet var leadingEdgeConstraint: NSLayoutConstraint!
  @IBOutlet var background: UIView!

  /// Configure the cell's visual appearance.
  /// - Parameters:
  ///   - title: Chapter title.
  ///   - nestingLevel: How nested this chapter should look.
  ///   - isForCurrentChapter: `true` if the cell represents the current
  /// chapter the user is on.
  @objc func config(
    withTitle title: String,
    nestingLevel: Int,
    isForCurrentChapter: Bool
  ) {
    leadingEdgeConstraint?.constant = 0
    leadingEdgeConstraint?.constant = CGFloat(nestingLevel * 20 + 10)

    titleLabel?.text = title
    titleLabel?.textColor = TPPAssociatedColors.shared.appearanceColors.textColor

    background?.layer.borderColor = TPPConfiguration.mainColor().cgColor
    background?.layer.borderWidth = 1
    background?.layer.cornerRadius = 3
    backgroundColor = .clear

    background.isHidden = !isForCurrentChapter
  }
}

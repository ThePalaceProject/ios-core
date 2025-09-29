//
//  TPPRoundedButton.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2021-03-31.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import UIKit

private let TPPRoundedButtonPadding: CGFloat = 6.0

// MARK: - TPPRoundedButtonType

@objc enum TPPRoundedButtonType: Int {
  case normal
  case clock
}

// MARK: - TPPRoundedButton

@objc class TPPRoundedButton: UIButton {
  // Properties
  private var type: TPPRoundedButtonType {
    didSet {
      updateViews()
    }
  }

  private var endDate: Date? {
    didSet {
      updateViews()
    }
  }

  private var isFromDetailView: Bool

  // UI Components
  private let label: UILabel = .init()
  private let iconView: UIImageView = .init()

  // Initializer
  init(type: TPPRoundedButtonType, endDate: Date?, isFromDetailView: Bool) {
    self.type = type
    self.endDate = endDate
    self.isFromDetailView = isFromDetailView

    super.init(frame: CGRect.zero)

    setupUI()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setter

  @objc func setType(_ type: TPPRoundedButtonType) {
    self.type = type
  }

  @objc func setEndDate(_ date: NSDate?) {
    guard let convertedDate = date as Date? else {
      return
    }
    endDate = convertedDate
  }

  @objc func setFromDetailView(_ isFromDetailView: Bool) {
    self.isFromDetailView = isFromDetailView
  }

  // MARK: - UI

  private func setupUI() {
    titleLabel?.font = UIFont.palaceFont(ofSize: 14)
    layer.borderColor = tintColor.cgColor
    layer.borderWidth = 1
    layer.cornerRadius = 3

    label.textColor = tintColor
    label.font = UIFont.palaceFont(ofSize: 9)

    addSubview(label)
    addSubview(iconView)
  }

  private func updateViews() {
    let padX = TPPRoundedButtonPadding + 2
    let padY = TPPRoundedButtonPadding

    if type == .normal || isFromDetailView {
      if isFromDetailView {
        contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
      } else {
        contentEdgeInsets = UIEdgeInsets(top: padY, left: padX, bottom: padY, right: padX)
      }
      iconView.isHidden = true
      label.isHidden = true
    } else {
      iconView.image = UIImage(named: "Clock")?.withRenderingMode(.alwaysTemplate)
      iconView.isHidden = false
      label.isHidden = false
      label.text = endDate?.timeUntilString(suffixType: .short) ?? ""
      label.sizeToFit()

      iconView.frame = CGRect(x: padX, y: padY / 2, width: 14, height: 14)
      var frame = label.frame
      frame.origin = CGPoint(x: iconView.center.x - frame.size.width / 2, y: iconView.frame.maxY)
      label.frame = frame
      contentEdgeInsets = UIEdgeInsets(top: padY, left: iconView.frame.maxX + padX, bottom: padY, right: padX)
    }
  }

  private func updateColors() {
    let color: UIColor = isEnabled ? tintColor : UIColor.gray
    layer.borderColor = color.cgColor
    label.textColor = color
    iconView.tintColor = color
    setTitleColor(color, for: .normal)
  }

  // Override UIView functions
  override var isEnabled: Bool {
    didSet {
      updateColors()
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if !isEnabled
      && self.point(inside: convert(point, to: self), with: event)
    {
      return self
    }
    return super.hitTest(point, with: event)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    var s = super.sizeThatFits(size)
    s.width += TPPRoundedButtonPadding * 2
    return s
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    updateColors()
  }

  override var accessibilityLabel: String? {
    get {
      guard !iconView.isHidden,
            let title = titleLabel?.text,
            let timeUntilString = endDate?.timeUntilString(suffixType: .long)
      else {
        return titleLabel?.text
      }
      return "\(title).\(timeUntilString) remaining."
    }
    set {}
  }
}

extension TPPRoundedButton {
  @objc(initWithType:isFromDetailView:)
  convenience init(type: TPPRoundedButtonType, isFromDetailView: Bool) {
    self.init(type: type, endDate: nil, isFromDetailView: isFromDetailView)
  }
}

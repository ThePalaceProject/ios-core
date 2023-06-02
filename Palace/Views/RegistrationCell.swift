//
//  RegistrationCell.swift
//  Palace
//
//  Created by Maurice Carrier on 6/2/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

class RegistrationCell: UITableViewCell {
  typealias DisplayStrings = Strings.TPPAccountRegistration

  private let padding: CGFloat = 20.0
  
  private let regTitle: UILabel = {
    let label = UILabel()
    label.font = UIFont.preferredFont(forTextStyle: .body)
    label.numberOfLines = 2
    label.text = DisplayStrings.doesUserHaveLibraryCard
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
  
  private let regBody: UILabel = {
    let label = UILabel()
    label.font = UIFont.preferredFont(forTextStyle: .callout)
    label.numberOfLines = 0
    label.text = DisplayStrings.geolocationInstructions
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
  
  private let regButton: UIButton = {
    let button = UIButton(type: .system)
    button.setTitle(DisplayStrings.createCard, for: .normal)
    button.setTitleColor(TPPConfiguration.mainColor(), for: .normal)
    button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
    button.layer.borderColor = TPPConfiguration.mainColor().cgColor
    button.layer.borderWidth = 1.0
    button.layer.cornerRadius = 5.0
    button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }()
  
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    
    let containerView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    
    containerView.addSubview(regTitle)
    containerView.addSubview(regBody)
    containerView.addSubview(regButton)
    
    contentView.addSubview(containerView)
    
    NSLayoutConstraint.activate([
      regTitle.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: padding),
      regTitle.topAnchor.constraint(equalTo: containerView.topAnchor, constant: padding),
      regTitle.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -padding),
      
      regBody.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: padding),
      regBody.topAnchor.constraint(equalTo: regTitle.bottomAnchor, constant: padding),
      regBody.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -padding),
      
      regButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: padding),
      regButton.topAnchor.constraint(equalTo: regBody.bottomAnchor, constant: padding),
      regButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -padding),
      
      containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
      containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
    
    selectionStyle = .none
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  func configure(title: String, body: String, buttonTitle: String, buttonAction: @escaping () -> Void) {
    regTitle.text = title
    regBody.text = body
    regButton.setTitle(buttonTitle, for: .normal)
    regButton.addAction(UIAction(handler: { _ in buttonAction() }), for: .touchUpInside)
  }
}

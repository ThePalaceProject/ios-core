import UIKit

@objcMembers
final class TPPReloadView: UIView {
  var handler: (() -> Void)?

  // MARK: - UI

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.boldPalaceFont(ofSize: 17)
    label.text = NSLocalizedString("Connection Failed", comment: "")
    label.textColor = .gray
    return label
  }()

  private let messageLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 3
    label.textAlignment = .center
    label.font = UIFont.palaceFont(ofSize: 12)
    label.textColor = .gray
    return label
  }()

  private let reloadButton: TPPRoundedButton = {
    let button = TPPRoundedButton(type: .normal, isFromDetailView: false)
    button.setTitle(NSLocalizedString("Try Again", comment: ""), for: .normal)
    return button
  }()

  // MARK: - Init

  override init(frame _: CGRect) {
    super.init(frame: CGRect(x: 0, y: 0, width: 280, height: 0))
    commonInit()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
  }

  private func commonInit() {
    addSubview(titleLabel)
    addSubview(messageLabel)
    addSubview(reloadButton)

    reloadButton.addTarget(self, action: #selector(didTapReload), for: .touchUpInside)
    setDefaultMessage()
    layoutIfNeeded()
    frame = CGRect(x: 0, y: 0, width: 280, height: reloadButton.frame.maxY)
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()

    let padding: CGFloat = 5
    let width = bounds.width

    // Title
    titleLabel.sizeToFit()
    titleLabel.centerInSuperview()
    var f = titleLabel.frame
    f.origin.y = 0
    titleLabel.frame = f

    // Message
    let messageHeight = messageLabel.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    messageLabel.frame = CGRect(x: 0, y: titleLabel.frame.maxY + padding, width: width, height: messageHeight)

    // Button
    reloadButton.sizeToFit()
    reloadButton.centerInSuperview()
    var bf = reloadButton.frame
    bf.origin.y = messageLabel.frame.maxY + padding
    reloadButton.frame = bf
  }

  // MARK: - Actions

  @objc private func didTapReload() {
    handler?()
    setDefaultMessage()
  }

  // MARK: - Public (ObjC)

  func setDefaultMessage() {
    messageLabel.text = NSLocalizedString("Check Connection", comment: "")
    setNeedsLayout()
  }

  func setMessage(_ msg: String?) {
    messageLabel.text = msg
    setNeedsLayout()
  }
}

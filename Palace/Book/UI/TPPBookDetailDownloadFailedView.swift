import UIKit
import PureLayout

@objc class TPPBookDetailDownloadFailedView: UIView {

  private let messageLabel = UILabel()

  @objc init() {
    super.init(frame: .zero)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = TPPConfiguration.mainColor()

    messageLabel.font = UIFont.customFont(forTextStyle: .body)
    messageLabel.textAlignment = .center
    messageLabel.textColor = TPPConfiguration.backgroundColor()
    messageLabel.text = NSLocalizedString("The download could not be completed.\nScroll down to 'View Issues' to see details.", comment: "")
    messageLabel.numberOfLines = 0
    addSubview(messageLabel)
    messageLabel.autoPinEdgesToSuperviewEdges()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didChangePreferredContentSize),
      name: UIContentSizeCategory.didChangeNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func didChangePreferredContentSize() {
    messageLabel.font = UIFont.customFont(forTextStyle: .body)
  }

  @objc func configureFailMessage(with problemDoc: TPPProblemDocument?) {
    if problemDoc != nil {
      messageLabel.text = NSLocalizedString("The download could not be completed.\nScroll down to 'View Issues' to see details.", comment: "")
    } else {
      messageLabel.text = NSLocalizedString("The download could not be completed.", comment: "")
    }
  }
}

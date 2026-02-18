import UIKit

final class TPPContentBadgeImageView: UIImageView {

  @objc enum TPPBadgeImage: Int {
    case audiobook
    case ebook

    func assetName() -> String {
      switch self {
      case .audiobook:
        return "AudiobookBadge"
      case .ebook:
        fatalError("No asset yet")
      }
    }
  }

  @objc required init(badgeImage: TPPBadgeImage) {
    super.init(image: UIImage(named: badgeImage.assetName()))
    setupView()
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    backgroundColor = TPPConfiguration.audiobookIconColor()
    contentMode = .scaleAspectFit

    layer.cornerRadius = 12
    layer.masksToBounds = true
  }

  @objc class func pin(badge: UIImageView, toView view: UIView) {
    if badge.superview == nil {
      view.addSubview(badge)
    }
    badge.autoSetDimensions(to: CGSize(width: 24, height: 24))
    badge.autoPinEdge(.trailing, to: .trailing, of: view, withOffset: -5)
    badge.autoPinEdge(.bottom, to: .bottom, of: view, withOffset: -5)
  }
}

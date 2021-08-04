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
        return "EbookBadge"
      }
    }
  }

  @objc required init(badgeImage: TPPBadgeImage) {
    super.init(image: UIImage(named: badgeImage.assetName()))
    backgroundColor = TPPConfiguration.palaceRed()
    contentMode = .scaleAspectFit
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc class func pin(badge: UIImageView, toView view: UIView) {
    if (badge.superview == nil) {
      view.addSubview(badge)
    }
    badge.autoSetDimensions(to: CGSize(width: 24, height: 24))
    badge.autoPinEdge(.trailing, to: .trailing, of: view)
    badge.autoPinEdge(.bottom, to: .bottom, of: view)
  }
}

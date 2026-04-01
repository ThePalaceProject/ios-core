import UIKit

@objc enum TPPLinearViewContentVerticalAlignment: Int {
  case top
  case middle
  case bottom
}

@objc class TPPLinearView: UIView {

  @objc var contentVerticalAlignment: TPPLinearViewContentVerticalAlignment = .top {
    didSet { setNeedsLayout() }
  }

  @objc var padding: CGFloat = 0 {
    didSet { setNeedsLayout() }
  }

  private var minimumRequiredHeight: CGFloat = 0
  private var minimumRequiredWidth: CGFloat = 0

  override func layoutSubviews() {
    var x: CGFloat = 0

    for view in subviews {
      let w = view.frame.width
      let h = view.frame.height
      let y: CGFloat

      switch contentVerticalAlignment {
      case .top:
        y = 0
      case .middle:
        y = round((frame.height - h) / 2.0)
      case .bottom:
        y = frame.height - h
      }

      view.frame = CGRect(x: x, y: y, width: w, height: h)
      minimumRequiredWidth = x + w
      minimumRequiredHeight = max(h, minimumRequiredHeight)
      x += w + padding
    }
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    layoutIfNeeded()

    let w = minimumRequiredWidth
    let h = minimumRequiredHeight

    if size == .zero {
      return CGSize(width: w, height: h)
    }

    return CGSize(
      width: min(w, size.width),
      height: min(h, size.height)
    )
  }
}

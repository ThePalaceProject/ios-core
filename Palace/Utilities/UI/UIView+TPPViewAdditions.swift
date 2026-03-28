import UIKit

extension UIView {

  @objc var preferredHeight: CGFloat {
    sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude)).height
  }

  @objc var preferredWidth: CGFloat {
    sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude)).width
  }

  @objc func centerInSuperview() {
    guard let superview = superview else { return }
    center = CGPoint(x: superview.bounds.width * 0.5,
                     y: superview.bounds.height * 0.5)
    integralizeFrame()
  }

  @objc func centerInSuperview(withOffset offset: CGPoint) {
    guard let superview = superview else { return }
    center = CGPoint(x: superview.bounds.width * 0.5 + offset.x,
                     y: superview.bounds.height * 0.5 + offset.y)
    integralizeFrame()
  }

  @objc func integralizeFrame() {
    frame = frame.integral
  }
}

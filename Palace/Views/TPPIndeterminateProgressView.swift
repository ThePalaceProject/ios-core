import UIKit

@objc class TPPIndeterminateProgressView: UIView {

  @objc private(set) var animating: Bool = false

  @objc var color: UIColor = .lightGray {
    didSet { setNeedsLayout() }
  }

  @objc var speedMultiplier: CGFloat = 1.0 {
    didSet { setNeedsLayout() }
  }

  private var replicatorLayer: CAReplicatorLayer?
  private var stripeShape: CAShapeLayer?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.transform = CATransform3DMakeScale(1, -1, 1)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    clipsToBounds = true
    layer.transform = CATransform3DMakeScale(1, -1, 1)
  }

  override func layoutSubviews() {
    replicatorLayer?.removeFromSuperlayer()
    setup()
  }

  @objc func startAnimating() {
    animating = true
    setNeedsLayout()
  }

  @objc func stopAnimating() {
    animating = false
    setNeedsLayout()
  }

  private func setup() {
    let stripeWidth = frame.height

    layer.borderColor = color.cgColor

    let stripe = CAShapeLayer()
    stripe.fillColor = color.cgColor
    stripe.frame = CGRect(x: 0, y: 0, width: bounds.height * 2, height: bounds.height)
    self.stripeShape = stripe

    let path = CGMutablePath()
    path.move(to: .zero)
    path.addLine(to: CGPoint(x: stripeWidth, y: 0))
    path.addLine(to: CGPoint(x: stripeWidth * 2, y: stripeWidth))
    path.addLine(to: CGPoint(x: stripeWidth, y: stripeWidth))
    stripe.path = path

    let replicator = CAReplicatorLayer()
    replicator.frame = bounds
    replicator.instanceCount = Int(ceil(frame.width / (frame.height * 2))) + 1
    replicator.instanceTransform = CATransform3DMakeTranslation(stripeWidth * 2, 0, 0)
    replicator.addSublayer(stripe)
    self.replicatorLayer = replicator

    if animating {
      let animation = CABasicAnimation(keyPath: "transform.translation.x")
      animation.fromValue = 0
      animation.toValue = -(frame.height * 2)
      animation.repeatCount = .infinity
      animation.duration = CFTimeInterval(stripeWidth * 0.025 * (1.0 / speedMultiplier))
      replicator.add(animation, forKey: nil)
    }

    layer.addSublayer(replicator)
  }
}

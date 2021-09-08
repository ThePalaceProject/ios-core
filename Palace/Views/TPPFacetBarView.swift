import Foundation

@objc protocol TPPFacetBarViewDelegate {
  func present(_ viewController: UIViewController)
}

@objcMembers class TPPFacetBarView : UIView {
  var entryPointView: TPPEntryPointView
  var facetView: TPPFacetView
  var imageView: UIImageView
  var imageViewBackground: UIView
  weak var delegate: TPPFacetBarViewDelegate?
  
  @available(*, unavailable)
  private override init(frame: CGRect) {
    entryPointView = TPPEntryPointView()
    facetView = TPPFacetView()
    imageView = UIImageView(image: AccountsManager.shared.currentAccount?.logo)
    imageViewBackground = UIView()
    
    super.init(frame: frame)
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  init(origin: CGPoint, width: CGFloat) {
    entryPointView = TPPEntryPointView()
    facetView = TPPFacetView()
    imageView = UIImageView(image: AccountsManager.shared.currentAccount?.logo)
    imageView.contentMode = .scaleAspectFit
    imageViewBackground = UIView()
    
    let borderHeight = 1.0 / UIScreen.main.scale;
    let toolbarHeight = CGFloat(40);

    super.init(frame: CGRect(x: origin.x, y: origin.y, width: width, height: borderHeight + toolbarHeight))
    backgroundColor = TPPConfiguration.backgroundColor()

    entryPointView.isHidden = true;
    facetView.isHidden = true;

    let bottomBorderView = UIView()
    bottomBorderView.backgroundColor = UIColor.lightGray.withAlphaComponent(0.9)
    let topBorderView = UIView()
    topBorderView.backgroundColor = UIColor.lightGray.withAlphaComponent(0.9)

    addSubview(facetView)
    addSubview(imageViewBackground)
    addSubview(entryPointView)
    
    entryPointView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .bottom)
    facetView.autoPinEdge(toSuperviewEdge: .leading)
    facetView.autoPinEdge(toSuperviewEdge: .trailing)
    imageViewBackground.autoPinEdge(.top, to: .bottom, of: facetView, withOffset: 10.0)
    imageViewBackground.autoPinEdge(toSuperviewEdge: .bottom, withInset: 10.0)
    imageViewBackground.autoAlignAxis(toSuperviewMarginAxis: .vertical)
    imageViewBackground.autoSetDimension(.height, toSize: 56.0)
    imageViewBackground.autoSetDimension(.width, toSize: 100.0)
    imageViewBackground.layer.cornerRadius = 23.0
    imageViewBackground.backgroundColor = .white
    
    imageViewBackground.addSubview(imageView)
    imageView.autoSetDimension(.height, toSize: 50.0)
    imageView.autoPinEdgesToSuperviewEdges()
    
    let logoTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(showAccountPage))
    imageView.addGestureRecognizer(logoTapRecognizer)
    imageView.isUserInteractionEnabled = true
    
    entryPointView.autoPinEdge(.bottom, to: .top, of: facetView)

    facetView.addSubview(bottomBorderView)
    bottomBorderView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .top)
    bottomBorderView.autoSetDimension(.height, toSize: borderHeight)
    facetView.addSubview(topBorderView)
    topBorderView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .bottom)
    topBorderView.autoSetDimension(.height, toSize:borderHeight)
  }
  
  @objc private func showAccountPage() {
    guard let homePageUrl = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: homePageUrl) else { return }
    let webController = BundledHTMLViewController(fileURL: url, title: AccountsManager.shared.currentAccount?.name.capitalized ?? "")
    webController.hidesBottomBarWhenPushed = true
    delegate?.present(webController)
  }
}

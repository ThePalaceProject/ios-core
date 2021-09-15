import Foundation

@objc protocol TPPFacetBarViewDelegate {
  func present(_ viewController: UIViewController)
}

@objcMembers class TPPFacetBarView : UIView {
  var entryPointView: TPPEntryPointView
  var facetView: TPPFacetView
  
  private let imageView = UIImageView(image: AccountsManager.shared.currentAccount?.logo)
  private var accountSiteButton = UIButton()
  private let titleLabel = UILabel()

  private let borderHeight = 1.0 / UIScreen.main.scale;
  private let toolbarHeight = CGFloat(40.0);

  weak var delegate: TPPFacetBarViewDelegate?

  @available(*, unavailable)
  private override init(frame: CGRect) {
    entryPointView = TPPEntryPointView()
    facetView = TPPFacetView()
    super.init(frame: frame)
    NotificationCenter.default.addObserver(self, selector: #selector(updateLogo), name: NSNotification.TPPCurrentAccountDidChange, object: nil)
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  init(origin: CGPoint, width: CGFloat) {
    entryPointView = TPPEntryPointView()
    facetView = TPPFacetView()

    super.init(frame: CGRect(x: origin.x, y: origin.y, width: width, height: borderHeight + toolbarHeight))
    setupViews()
    NotificationCenter.default.addObserver(self, selector: #selector(updateLogo), name: NSNotification.TPPCurrentAccountDidChange, object: nil)
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  private func setupViews() {
    backgroundColor = TPPConfiguration.backgroundColor()
    setupFacetView()
  }
  
  private func setupFacetView() {
    entryPointView.isHidden = true;
    facetView.isHidden = true;
    
    let bottomBorderView = UIView()
    bottomBorderView.backgroundColor = UIColor.lightGray.withAlphaComponent(0.9)
    let topBorderView = UIView()
    topBorderView.backgroundColor = UIColor.lightGray.withAlphaComponent(0.9)
    
    addSubview(facetView)
    addLogoView()
    addSubview(entryPointView)
    
    entryPointView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .bottom)
    facetView.autoPinEdge(toSuperviewEdge: .leading)
    facetView.autoPinEdge(toSuperviewEdge: .trailing)
    
    entryPointView.autoPinEdge(.bottom, to: .top, of: facetView)

    facetView.addSubview(bottomBorderView)
    bottomBorderView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .top)
    bottomBorderView.autoSetDimension(.height, toSize: borderHeight)
    facetView.addSubview(topBorderView)
    topBorderView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .bottom)
    topBorderView.autoSetDimension(.height, toSize:borderHeight)
  }

  private func addLogoView() {
    let logoView = UIView()
    addSubview(logoView)

    imageView.contentMode = .scaleAspectFit

    logoView.autoPinEdge(.top, to: .bottom, of: facetView, withOffset: 10.0)
    logoView.autoPinEdge(toSuperviewEdge: .bottom, withInset: 10.0)
    logoView.autoAlignAxis(toSuperviewMarginAxis: .vertical)
    logoView.autoConstrainAttribute(.width, to: .width, of: self, withMultiplier: 0.8, relation: .lessThanOrEqual)
    
    logoView.layer.cornerRadius = 23.0
    logoView.backgroundColor = TPPConfiguration.readerBackgroundColor()
    
    let imageHolder = UIView()
    imageHolder.autoSetDimension(.height, toSize: 50.0)
    imageHolder.autoSetDimension(.width, toSize: 50.0)
    imageHolder.addSubview(imageView)
    
    imageView.autoPinEdgesToSuperviewEdges()
    
    let container = UIView()
    logoView.addSubview(container)
    container.addSubview(imageHolder)

    container.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 0.0, left: 10.0, bottom: 0.0, right: 10.0))
    imageHolder.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 10.0, left: 10.0, bottom: 10.0, right: 10.0), excludingEdge: .trailing)

    titleLabel.lineBreakMode = .byWordWrapping
    titleLabel.numberOfLines = 0
    titleLabel.textAlignment = .center
    titleLabel.text = AccountsManager.shared.currentAccount?.name
    titleLabel.textColor = .gray
    titleLabel.font = UIFont.boldSystemFont(ofSize: 18.0)
    
    let titleContainer = UIView()
    titleContainer.addSubview(titleLabel)
    titleLabel.autoPinEdgesToSuperviewEdges()

    container.addSubview(titleContainer)
    titleContainer.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 10.0, left: 10.0, bottom: 10.0, right: 10.0), excludingEdge: .leading)
    titleContainer.autoPinEdge(.leading, to: .trailing, of: imageView, withOffset: 10.0)

    logoView.addSubview(accountSiteButton)
    accountSiteButton.autoPinEdgesToSuperviewEdges()
    accountSiteButton.addTarget(self, action: #selector(showAccountPage), for: .touchUpInside)
    updateLogo()
  }

  @objc func updateLogo() {
    imageView.image = AccountsManager.shared.currentAccount?.logo
    titleLabel.text = AccountsManager.shared.currentAccount?.name
  }
  
  @objc private func showAccountPage() {
    
    guard let homePageUrl = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: homePageUrl) else { return }
    let webController = BundledHTMLViewController(fileURL: url, title: AccountsManager.shared.currentAccount?.name.capitalized ?? "")
    webController.hidesBottomBarWhenPushed = true
    delegate?.present(webController)
  }
}

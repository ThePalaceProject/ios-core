import Foundation

@objc protocol TPPFacetBarViewDelegate {
  func present(_ viewController: UIViewController)
}

@objcMembers class TPPFacetBarView : UIView {
  var entryPointView: TPPEntryPointView = TPPEntryPointView()
 
  private let accountSiteButton = UIButton()
  private let borderHeight = 1.0 / UIScreen.main.scale;
  private let toolbarHeight = CGFloat(40.0);

  weak var delegate: TPPFacetBarViewDelegate?
  
  lazy var facetView: TPPFacetView = {
    let view = TPPFacetView()
    
    let topBorderView = UIView()
    let bottomBorderView = UIView()
    
    topBorderView.backgroundColor = UIColor.lightGray.withAlphaComponent(0.9)
    bottomBorderView.backgroundColor = UIColor.lightGray.withAlphaComponent(0.9)
        
    view.addSubview(bottomBorderView)
    view.addSubview(topBorderView)

    bottomBorderView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .top)
    bottomBorderView.autoSetDimension(.height, toSize: borderHeight)
    topBorderView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .bottom)
    topBorderView.autoSetDimension(.height, toSize:borderHeight)
    return view
  }()
  
  private lazy var logoView: UIView = {
    let logoView = UIView()
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
    
    let titleContainer = UIView()
    titleContainer.addSubview(titleLabel)
    titleLabel.autoPinEdgesToSuperviewEdges()
    
    container.addSubview(titleContainer)
    titleContainer.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 10.0, left: 10.0, bottom: 10.0, right: 10.0), excludingEdge: .leading)
    titleContainer.autoPinEdge(.leading, to: .trailing, of: imageView, withOffset: 10.0)
    
    logoView.addSubview(accountSiteButton)
    accountSiteButton.autoPinEdgesToSuperviewEdges()
    accountSiteButton.addTarget(self, action: #selector(showAccountPage), for: .touchUpInside)
    return logoView
  }()
  
  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.lineBreakMode = .byWordWrapping
    label.numberOfLines = 0
    label.textAlignment = .center
    label.text = AccountsManager.shared.currentAccount?.name
    label.textColor = .gray
    label.font = UIFont.boldSystemFont(ofSize: 18.0)
    return label
  }()
  
  private lazy var imageView: UIImageView = {
    let view = UIImageView(image: AccountsManager.shared.currentAccount?.logo)
    view.contentMode = .scaleAspectFit
    return view
  }()
  
  @available(*, unavailable)
  private override init(frame: CGRect) {
    super.init(frame: frame)
    NotificationCenter.default.addObserver(self, selector: #selector(updateLogo), name: NSNotification.TPPCurrentAccountDidChange, object: nil)
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  init(origin: CGPoint, width: CGFloat) {
    super.init(frame: CGRect(x: origin.x, y: origin.y, width: width, height: borderHeight + toolbarHeight))
    
    setupViews()
    NotificationCenter.default.addObserver(self, selector: #selector(updateLogo), name: NSNotification.TPPCurrentAccountDidChange, object: nil)
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    logoView.layer.cornerRadius = logoView.frame.height/2
  }

  private func setupViews() {
    backgroundColor = TPPConfiguration.backgroundColor()
    entryPointView.isHidden = true;
    facetView.isHidden = true;

    addSubview(facetView)
    addSubview(logoView)
    addSubview(entryPointView)
    setupConstraints()
    updateLogo()
  }
  
  private func setupConstraints() {
    entryPointView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets.zero, excludingEdge: .bottom)
    facetView.autoPinEdge(toSuperviewEdge: .leading)
    facetView.autoPinEdge(toSuperviewEdge: .trailing)
    
    entryPointView.autoPinEdge(.bottom, to: .top, of: facetView)
    logoView.autoPinEdge(.top, to: .bottom, of: facetView, withOffset: 10.0)
    logoView.autoPinEdge(toSuperviewEdge: .bottom, withInset: 10.0)
    logoView.autoAlignAxis(toSuperviewMarginAxis: .vertical)
    logoView.autoConstrainAttribute(.width, to: .width, of: self, withMultiplier: 0.8, relation: .lessThanOrEqual)
  }

  @objc func updateLogo() {
    imageView.image = AccountsManager.shared.currentAccount?.logo
    titleLabel.text = AccountsManager.shared.currentAccount?.name
  }
  
  @objc private func showAccountPage() {
    guard let homePageUrl = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: homePageUrl) else { return }
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
  }
}

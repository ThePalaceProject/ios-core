import UIKit
import PureLayout


/// Welcome screen for a first-time user
@objcMembers final class TPPWelcomeScreenViewController: UIViewController, TPPLoadingViewController {
  
  var completion: ((Account) -> ())?
  var loadingView: UIView?
  
  required init(completion: ((Account) -> ())?) {
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    self.view.backgroundColor = TPPConfiguration.backgroundColor()
    setupViews()
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    self.navigationController?.setNavigationBarHidden(true, animated: false)
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    self.navigationController?.setNavigationBarHidden(false, animated: false)
  }
  
  //MARK -
  
  func setupViews() {
    let view1 = splashScreenView(
      buttonTitle: NSLocalizedString("Find Your Library", comment: "Button that lets user know they can select a library they have a card for"),
      buttonTargetSelector: #selector(pickYourLibraryTapped)
    )
        
    let logoView = UIImageView(image: UIImage(named: "WelcomeLogo"))
    logoView.contentMode = .scaleAspectFit
    
    let containerView = UIView()
    containerView.addSubview(logoView)
    containerView.addSubview(view1)
    
    self.view.addSubview(containerView)
    
    logoView.autoPinEdge(toSuperviewMargin: .top)
    logoView.autoPinEdge(toSuperviewMargin: .leading)
    logoView.autoPinEdge(toSuperviewMargin: .trailing)
    logoView.autoAlignAxis(toSuperviewAxis: .vertical)

    view1.autoAlignAxis(toSuperviewAxis: .vertical)
    view1.autoPinEdge(.top, to: .bottom, of: logoView, withOffset: -12)
    view1.autoPinEdge(toSuperviewMargin: .left)
    view1.autoPinEdge(toSuperviewMargin: .right)
    view1.autoPinEdge(toSuperviewEdge: .bottom)
    
    containerView.autoAlignAxis(toSuperviewAxis: .vertical)
    containerView.autoPinEdge(toSuperviewEdge: .left, withInset: 24, relation: .greaterThanOrEqual)
    containerView.autoPinEdge(toSuperviewEdge: .right, withInset: 24, relation: .greaterThanOrEqual)
    containerView.autoPinEdge(toSuperviewEdge: .top, withInset: 0, relation: .greaterThanOrEqual)
    containerView.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0, relation: .greaterThanOrEqual)
    
    NSLayoutConstraint.autoSetPriority(UILayoutPriority.defaultHigh) {
      containerView.autoSetDimension(.width, toSize: 350)
      containerView.autoAlignAxis(toSuperviewAxis: .horizontal)
    }
    NSLayoutConstraint.autoSetPriority(UILayoutPriority.defaultLow) {
      logoView.autoSetDimensions(to: CGSize(width: 180, height: 150))
    }
  }
  
  func splashScreenView(buttonTitle: String, buttonTargetSelector: Selector) -> UIView {
    let tempView = UIView()
    
    let button = UIButton()
    button.accessibilityLabel = buttonTitle
    button.setTitle(buttonTitle, for: UIControl.State())
    button.titleLabel?.font = UIFont.palaceFont(ofSize: 16)
    button.setTitleColor(.white, for: .normal)
    button.layer.backgroundColor = UIColor.black.cgColor
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.33).cgColor
    button.layer.borderWidth = 2
    button.layer.cornerRadius = 6

    button.contentEdgeInsets = UIEdgeInsets.init(top: 8.0, left: 16.0, bottom: 8.0, right: 16.0)
    button.addTarget(self, action: buttonTargetSelector, for: .touchUpInside)
    tempView.addSubview(button)
    
    button.autoPinEdge(toSuperviewMargin: .top)
    button.autoAlignAxis(toSuperviewMarginAxis: .vertical)
    button.autoPinEdge(toSuperviewMargin: .bottom)
    
    return tempView
  }
  
  func showLoadingFailureAlert() {
    let alert = TPPAlertUtils.alert(title:nil, message:"We can’t get your library right now. Please close and reopen the app to try again.", style: .cancel)
    present(alert, animated: true, completion: nil)
  }

  func pickYourLibraryTapped() {
    if completion == nil {
      self.dismiss(animated: true, completion: nil)
      return
    }
    
    let pickLibrary = {
      let listVC = TPPAccountList { account in
        if account.details != nil {
          self.completion?(account)
        } else {
          // Show loading overlay while we load the auth document
          self.startLoading()
          account.loadAuthenticationDocument { (success) in
            DispatchQueue.main.async {
              self.stopLoading()
              guard success else {
                self.showLoadingFailureAlert()
                return
              }
                
              TPPSettings.shared.settingsAccountIdsList = [account.uuid]
              self.completion?(account)
            }
          }
        }
      }
      self.navigationController?.pushViewController(listVC, animated: true)
    }

    if AccountsManager.shared.accountsHaveLoaded {
      pickLibrary()
    } else {
      // Show loading overlay while loading library list, which is required for pickLibrary
      startLoading()
      AccountsManager.shared.loadCatalogs() { (success) in
        DispatchQueue.main.async {
          self.stopLoading()
          guard success else {
            self.showLoadingFailureAlert()
            return
          }
          pickLibrary()
        }
      }
    }
  }

  func instantClassicsTapped() {
    let classicsId = AccountsManager.TPPAccountUUIDs[2]
    
    let selectInstantClassics = {
      guard let classicsAccount = AccountsManager.shared.account(classicsId) else {
        DispatchQueue.main.async {
          self.stopLoading()
          self.showLoadingFailureAlert()
        }
        return
      }
      //Show indicator while loading the auth document
      self.startLoading()
      // Load the auth document for the classics library
      classicsAccount.loadAuthenticationDocument { (authSuccess) in
        DispatchQueue.main.async {
          self.stopLoading()
          if authSuccess {
            TPPSettings.shared.settingsAccountIdsList = [classicsId]
            self.completion?(AccountsManager.shared.account(classicsId)!)
          } else {
            self.showLoadingFailureAlert()
          }
        }
      }
    }
    
    if AccountsManager.shared.accountsHaveLoaded {
      selectInstantClassics()
    } else {
      // Make sure the library list is loaded
      startLoading()
      AccountsManager.shared.loadCatalogs() { success in
        DispatchQueue.main.async {
          if success {
            selectInstantClassics()
          } else {
            self.stopLoading()
            self.showLoadingFailureAlert()
          }
        }
      }
    }
  }
}

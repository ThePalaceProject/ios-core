import UIKit

protocol TPPRegistryDebugger: TPPLoadingViewController {}

class TPPRegistryDebuggingCell: UITableViewCell {
  
  private var inputField = UITextField()
  weak var delegate: TPPLoadingViewController?
  
  private var reloadInProgress: Bool = false {
    didSet {
      reloadInProgress ?  delegate?.startLoading() : delegate?.stopLoading()
    }
  }
  
  lazy var horizontalStackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.distribution = .fillProportionally
    stack.spacing = 5
    stack.alignment = .center
    return stack
  }()
  
  lazy var prefixLabel: UILabel = {
    let label = UILabel()
    label.text = "https://"
    label.adjustsFontSizeToFitWidth = true
    label.textColor = .gray
    label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    return label
  }()
  
  lazy var postfixLabel: UILabel = {
    let label = UILabel()
    label.text = "/libraries/qa"
    label.adjustsFontSizeToFitWidth = true
    label.textColor = .gray
    label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    return label
  }()
  
  lazy var inputStackView: UIStackView = {
    let stackView = UIStackView()
    stackView.axis = .vertical
    
    inputField.placeholder = "Input custom server"
    inputField.text = TPPSettings.shared.customLibraryRegistryServer
    inputField.autocapitalizationType = .none
    inputField.autocorrectionType = .no
    
    stackView.addArrangedSubview(inputField)
    inputField.autoSetDimension(.width, toSize: 200, relation: .greaterThanOrEqual)
    
    let underline = UIView()
    underline.backgroundColor = .gray
    stackView.addArrangedSubview(underline)
    underline.autoSetDimension(.height, toSize: 1)
    return stackView
  }()
  
  lazy var buttonStackView: UIStackView = {
    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.spacing = 30
    stackView.distribution = .equalSpacing
    
    let clearButton = UIButton()
    clearButton.layer.cornerRadius = 5
    clearButton.layer.borderWidth = 1
    clearButton.layer.borderColor = UIColor.defaultLabelColor().cgColor
    
    clearButton.setTitle("Clear", for: .normal)
    clearButton.setTitleColor(UIColor.defaultLabelColor(), for: .normal)

    clearButton.addTarget(self, action: #selector(clear), for: .touchUpInside)
    
    clearButton.autoSetDimension(.width, toSize: 125)
    stackView.addArrangedSubview(clearButton)
    
    let setButton = UIButton()
    setButton.layer.cornerRadius = 5
    setButton.layer.borderWidth = 1
    setButton.layer.borderColor = UIColor.defaultLabelColor().cgColor
    setButton.autoSetDimension(.width, toSize: 125)

    setButton.setTitle("Set", for: .normal)
    setButton.setTitleColor(UIColor.defaultLabelColor(), for: .normal)

    setButton.addTarget(self, action: #selector(set), for: .touchUpInside)
    stackView.addArrangedSubview(setButton)
    return stackView
  }()
  
  init() {
    super.init(style: .default, reuseIdentifier: "CustomRegistryCell")
    configure()
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  private func configure() {
    selectionStyle = .none
    
    let containerStack = UIStackView()
    containerStack.axis = .vertical
    containerStack.spacing = 10
    inputField.delegate = self
    
    horizontalStackView.addArrangedSubview(prefixLabel)
    horizontalStackView.addArrangedSubview(inputStackView)
    horizontalStackView.addArrangedSubview(postfixLabel)
    containerStack.addArrangedSubview(horizontalStackView)
    containerStack.addArrangedSubview(buttonStackView)
    contentView.addSubview(containerStack)
    
    containerStack.autoSetDimension(.height, toSize: 100, relation: .greaterThanOrEqual)
    containerStack.autoPinEdgesToSuperviewMargins()
  }
  
  @objc private func clear() {
    inputField.text = nil
    TPPSettings.shared.customLibraryRegistryServer = nil
    AccountsManager.shared.clearCache()
    self.showAlert(title: "Configuration Updated", message: "Registry has been reset to default")
  }
  
  @objc private func set() {
    AccountsManager.shared.clearCache()

    guard let text = inputField.text, !text.isEmpty else {
      self.showAlert(title: "Configuration Update Failed", message: "Please enter a valid server URL")
      return
    }
    
    TPPSettings.shared.customLibraryRegistryServer = text
    let message = String(format: "Registry server: %@", text)
    reloadRegistry { isSuccess in
      if isSuccess {
        self.showAlert(title: "Configuration Updated", message: message)
      } else {
        self.showAlert(title: "Configuration Update Failed", message: "Please enter a valid server URL")
      }
    }
  }
  
  private func reloadRegistry(completion: @escaping (Bool) -> Void) {
    guard !reloadInProgress else { return }
    reloadInProgress.toggle()
    
    AccountsManager.shared.clearCache()
    AccountsManager.shared.updateAccountSet { isSuccess in
      self.reloadInProgress.toggle()
      completion(isSuccess)
    }
  }
  
  private func showAlert(title: String, message: String) {
    let alert = TPPAlertUtils.alert(title: title, message: message)
    DispatchQueue.main.async {
      (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController()?.present(alert, animated: true, completion: nil)
    }
  }
}

extension TPPRegistryDebuggingCell: UITextFieldDelegate {
  func textFieldDidChangeSelection(_ textField: UITextField) {
    textField.text = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

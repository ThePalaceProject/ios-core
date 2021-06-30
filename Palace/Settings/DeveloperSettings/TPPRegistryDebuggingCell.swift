import UIKit

class TPPRegistryDebuggingCell: UITableViewCell {
  
  private var inputField = UITextField()
  
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
    clearButton.layer.borderColor = UIColor.black.cgColor
    
    clearButton.setTitle("Clear", for: .normal)
    clearButton.setTitleColor(UIColor.black, for: .normal)

    clearButton.addTarget(self, action: #selector(clear), for: .touchUpInside)
    
    clearButton.autoSetDimension(.width, toSize: 125)
    stackView.addArrangedSubview(clearButton)
    
    let setButton = UIButton()
    setButton.layer.cornerRadius = 5
    setButton.layer.borderWidth = 1
    setButton.layer.borderColor = UIColor.black.cgColor
    setButton.autoSetDimension(.width, toSize: 125)

    setButton.setTitle("Set", for: .normal)
    setButton.setTitleColor(UIColor.black, for: .normal)

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
    showAlert(title: "Configuration Updated", message: "Custom server has been reset to default")
    reloadRegistry()
  }
  
  @objc private func set() {
    TPPSettings.shared.customLibraryRegistryServer = inputField.text
    let message = String(format: "Custom server: %@", inputField.text ?? "")
    showAlert(title: "Configuration Updated", message: message)
    reloadRegistry()
  }
  
  private func reloadRegistry() {
    AccountsManager.shared.clearCache()
    AccountsManager.shared.updateAccountSet(completion: nil)
  }
  
  private func showAlert(title: String, message: String) {
    let alert = TPPAlertUtils.alert(title: title, message: message)
    UIApplication.shared.keyWindow?.rootViewController?.present(alert, animated: true, completion: nil)
  }
}

 extension UIButton {
  open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    
    alpha = 0.5
  }
  
  open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    
    alpha = 1.0
  }
}

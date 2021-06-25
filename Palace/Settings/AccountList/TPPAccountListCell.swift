import UIKit

class TPPAccountListCell: UITableViewCell {
  
  static let reuseIdentifier = "AccountListCell"

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    setup()
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  override func awakeFromNib() {
    super.awakeFromNib()
  }
  
  private func setup() {
    accessoryType = .disclosureIndicator
    imageView?.contentMode = .scaleAspectFit
    
    textLabel?.font = UIFont.systemFont(ofSize: 16)
    textLabel?.numberOfLines = .zero

    detailTextLabel?.font = UIFont(name: "AvenirNext-Regular", size: 12)
    detailTextLabel?.numberOfLines = .zero
  }
  
  func configure(for account: Account) {
    imageView?.image = account.logo
    textLabel?.text = account.name
    detailTextLabel?.text = account.subtitle
  }
}

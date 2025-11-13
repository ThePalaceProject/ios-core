import UIKit

class TPPAccountListCell: UITableViewCell {
  
  static let reuseIdentifier = "AccountListCell"
  var customImageView = UIImageView()
  var customTextlabel = UILabel()
  var customDetailLabel = UILabel()
  
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: .default, reuseIdentifier: reuseIdentifier)
    setup()
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  override func awakeFromNib() {
    super.awakeFromNib()
  }

  func setup() {
    let container = UIView()
    let textContainer = UIView()
    
    accessoryType = .disclosureIndicator
    customImageView.contentMode = .scaleAspectFit
    
    customTextlabel.font = UIFont.palaceFont(ofSize: 14)
    customTextlabel.numberOfLines = 0
    
    customDetailLabel.font = UIFont.palaceFont(ofSize: 12)
    customDetailLabel.numberOfLines = 0
    
    textContainer.addSubview(customTextlabel)
    textContainer.addSubview(customDetailLabel)
    
    container.addSubview(customImageView)
    container.addSubview(textContainer)
    contentView.addSubview(container)
    
    customImageView.autoAlignAxis(toSuperviewAxis: .horizontal)
    customImageView.autoPinEdge(toSuperviewEdge: .left)
    customImageView.autoSetDimensions(to: CGSize(width: 45, height: 45))
    
    textContainer.autoPinEdge(.left, to: .right, of: customImageView, withOffset: contentView.layoutMargins.left)
    textContainer.autoPinEdge(toSuperviewMargin: .right)
    textContainer.autoAlignAxis(toSuperviewAxis: .horizontal)
    
    NSLayoutConstraint.autoSetPriority(UILayoutPriority.defaultLow) {
      textContainer.autoPinEdge(toSuperviewEdge: .top, withInset: 0, relation: .greaterThanOrEqual)
      textContainer.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0, relation: .greaterThanOrEqual)
    }
    
    customTextlabel.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .bottom)
    
    customDetailLabel.autoPinEdge(.top, to: .bottom, of: customTextlabel)
    customDetailLabel.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .top)
    
    container.autoPinEdgesToSuperviewMargins()
    container.autoSetDimension(.height, toSize: 55, relation: .greaterThanOrEqual)
    
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    customImageView.image = nil
  }
  
  func configure(for account: Account) {
    customImageView.image = account.logo
    customTextlabel.text = account.name
    customDetailLabel.text = account.subtitle
    layoutSubviews()
  }
}

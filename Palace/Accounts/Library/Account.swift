
private let userAboveAgeKey              = "TPPSettingsUserAboveAgeKey"
private let accountSyncEnabledKey        = "TPPAccountSyncEnabledKey"

/// This class is used for mapping details of SAML Identity Provider received in authentication document
@objcMembers
class OPDS2SamlIDP: NSObject, Codable {
  /// url to begin SAML login process with a given IDP
  let url: URL

  private let displayNames: [String: String]?
  private let descriptions: [String: String]?

  var displayName: String? { displayNames?["en"] }
  var idpDescription: String? { descriptions?["en"] }

  init?(opdsLink: OPDS2Link) {
    guard let url = URL(string: opdsLink.href) else { return nil }
    self.url = url
    self.displayNames = opdsLink.displayNames?.reduce(into: [String: String]()) { $0[$1.language] = $1.value }
    self.descriptions = opdsLink.descriptions?.reduce(into: [String: String]()) { $0[$1.language] = $1.value }
  }
}

@objc protocol TPPSignedInStateProvider {
  func isSignedIn() -> Bool
}

// MARK: AccountDetails
// Extra data that gets loaded from an OPDS2AuthenticationDocument,
@objcMembers final class AccountDetails: NSObject {
  enum AuthType: String, Codable {
    case basic = "http://opds-spec.org/auth/basic"
    case coppa = "http://librarysimplified.org/terms/authentication/gate/coppa" //used for Simplified collection
    case anonymous = "http://librarysimplified.org/rel/auth/anonymous"
    case oauthIntermediary = "http://librarysimplified.org/authtype/OAuth-with-intermediary"
    case saml = "http://librarysimplified.org/authtype/SAML-2.0"
    case token = "http://thepalaceproject.org/authtype/basic-token"
    case none
  }
  
  @objc(AccountDetailsAuthentication)
  @objcMembers
  class Authentication: NSObject, Codable, NSCoding {
    let authType:AuthType
    let authPasscodeLength:UInt
    let patronIDKeyboard:LoginKeyboard
    let pinKeyboard:LoginKeyboard
    let patronIDLabel:String?
    let pinLabel:String?
    let supportsBarcodeScanner:Bool
    let supportsBarcodeDisplay:Bool
    let coppaUnderUrl:URL?
    let coppaOverUrl:URL?
    let oauthIntermediaryUrl:URL?
    let methodDescription: String?

    let samlIdps: [OPDS2SamlIDP]?

    init(auth: OPDS2AuthenticationDocument.Authentication) {
      let authType = AuthType(rawValue: auth.type) ?? .none
      self.authType = authType
      authPasscodeLength = auth.inputs?.password.maximumLength ?? 99
      patronIDKeyboard = LoginKeyboard.init(auth.inputs?.login.keyboard) ?? .standard
      pinKeyboard = LoginKeyboard.init(auth.inputs?.password.keyboard) ?? .standard
      patronIDLabel = auth.labels?.login
      pinLabel = auth.labels?.password
      methodDescription = auth.description
      supportsBarcodeScanner = auth.inputs?.login.barcodeFormat == "Codabar"
      supportsBarcodeDisplay = supportsBarcodeScanner

      switch authType {
      case .coppa:
        coppaUnderUrl = URL.init(string: auth.links?.first(where: { $0.rel == "http://librarysimplified.org/terms/rel/authentication/restriction-not-met" })?.href ?? "")
        coppaOverUrl = URL.init(string: auth.links?.first(where: { $0.rel == "http://librarysimplified.org/terms/rel/authentication/restriction-met" })?.href ?? "")
        oauthIntermediaryUrl = nil
        samlIdps = nil

      case .oauthIntermediary:
        oauthIntermediaryUrl = URL.init(string: auth.links?.first(where: { $0.rel == "authenticate" })?.href ?? "")
        coppaUnderUrl = nil
        coppaOverUrl = nil
        samlIdps = nil

      case .saml, .token:
        samlIdps = auth.links?.filter { $0.rel == "authenticate" }.compactMap { OPDS2SamlIDP(opdsLink: $0) }
        oauthIntermediaryUrl = nil
        coppaUnderUrl = nil
        coppaOverUrl = nil

      case .none, .basic, .anonymous:
        oauthIntermediaryUrl = nil
        coppaUnderUrl = nil
        coppaOverUrl = nil
        samlIdps = nil

      }
    }

    var needsAuth:Bool {
      return authType == .basic || authType == .oauthIntermediary || authType == .saml || authType == .token
    }

    var needsAgeCheck:Bool {
      return authType == .coppa
    }

    func coppaURL(isOfAge: Bool) -> URL? {
      isOfAge ? coppaOverUrl : coppaUnderUrl
    }

    var isBasic: Bool {
      return authType == .basic
    }

    var isOauth: Bool {
      return authType == .oauthIntermediary
    }

    var isSaml: Bool {
      return authType == .saml
    }

    var catalogRequiresAuthentication: Bool {
      // you need an oauth token in order to access catalogs if authentication type is either oauth with intermediary (ex. Clever), or SAML
      return authType == .oauthIntermediary || authType == .saml
    }

    func encode(with coder: NSCoder) {
      let jsonEncoder = JSONEncoder()
      guard let data = try? jsonEncoder.encode(self) else { return }
      coder.encode(data as NSData)
    }

    required init?(coder: NSCoder) {
      guard let data = coder.decodeData() else { return nil }
      let jsonDecoder = JSONDecoder()
      guard let authentication = try? jsonDecoder.decode(Authentication.self, from: data) else { return nil }

      authType = authentication.authType
      authPasscodeLength = authentication.authPasscodeLength
      patronIDKeyboard = authentication.patronIDKeyboard
      pinKeyboard = authentication.pinKeyboard
      patronIDLabel = authentication.patronIDLabel
      pinLabel = authentication.pinLabel
      supportsBarcodeScanner = authentication.supportsBarcodeScanner
      supportsBarcodeDisplay = authentication.supportsBarcodeDisplay
      coppaUnderUrl = authentication.coppaUnderUrl
      coppaOverUrl = authentication.coppaOverUrl
      oauthIntermediaryUrl = authentication.oauthIntermediaryUrl
      methodDescription = authentication.methodDescription
      samlIdps = authentication.samlIdps
    }
  }

  let defaults:UserDefaults
  let uuid:String
  let supportsSimplyESync:Bool
  let supportsCardCreator:Bool
  let supportsReservations:Bool
  let auths: [Authentication]

  let mainColor:String?
  let userProfileUrl:String?
  let signUpUrl:URL?
  let loansUrl:URL?
  var defaultAuth: Authentication? {
    guard auths.count > 1 else { return auths.first }
    return auths.first(where: { !$0.catalogRequiresAuthentication }) ?? auths.first
  }
  var needsAgeCheck: Bool {
    // this will tell if any authentication method requires age check
    return auths.contains(where: { $0.needsAgeCheck })
  }

  fileprivate var urlAnnotations:URL?
  fileprivate var urlAcknowledgements:URL?
  fileprivate var urlContentLicenses:URL?
  fileprivate var urlEULA:URL?
  fileprivate var urlPrivacyPolicy:URL?
  
  var eulaIsAccepted:Bool {
    get {
      return getAccountDictionaryKey(TPPSettings.userHasAcceptedEULAKey) as? Bool ?? false

    }
    set {
      setAccountDictionaryKey(TPPSettings.userHasAcceptedEULAKey,
                              toValue: newValue as AnyObject)
    }
  }
  var syncPermissionGranted:Bool {
    get {
      return getAccountDictionaryKey(accountSyncEnabledKey) as? Bool ?? false
    }
    set {
      setAccountDictionaryKey(accountSyncEnabledKey, toValue: newValue as AnyObject)
    }
  }
  var userAboveAgeLimit:Bool {
    get {
      return getAccountDictionaryKey(userAboveAgeKey) as? Bool ?? false

    }
    set {
      setAccountDictionaryKey(userAboveAgeKey, toValue: newValue as AnyObject)
    }
  }
  
  init(authenticationDocument: OPDS2AuthenticationDocument, uuid: String) {
    defaults = .standard
    self.uuid = uuid

    auths = authenticationDocument.authentication?.map({ (opdsAuth) -> Authentication in
      return Authentication.init(auth: opdsAuth)
    }) ?? []

//    // TODO: Code below will remove all oauth only auth methods, this behaviour wasn't tested though
//    // and may produce undefined results in viewcontrollers that do present auth methods if none are available
//    auths = authenticationDocument.authentication?.map({ (opdsAuth) -> Authentication in
//      return Authentication.init(auth: opdsAuth)
//    }).filter { $0.authType != .oauthIntermediary } ?? []

    supportsReservations = authenticationDocument.features?.disabled?.contains("https://librarysimplified.org/rel/policy/reservations") != true
    userProfileUrl = authenticationDocument.links?.first(where: { $0.rel == "http://librarysimplified.org/terms/rel/user-profile" })?.href
    loansUrl = URL.init(string: authenticationDocument.links?.first(where: { $0.rel == "http://opds-spec.org/shelf" })?.href ?? "")
    supportsSimplyESync = userProfileUrl != nil
    
    mainColor = authenticationDocument.colorScheme
    
    let registerUrlStr = authenticationDocument.links?.first(where: { $0.rel == "register" })?.href
    if let registerUrlStr = registerUrlStr {
      let trimmedUrlStr = registerUrlStr.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedUrlStr.lowercased().hasPrefix("nypl.card-creator:") {
        let cartCreatorUrlStr = String(trimmedUrlStr.dropFirst("nypl.card-creator:".count))
        signUpUrl = URL(string: cartCreatorUrlStr)
        supportsCardCreator = (signUpUrl != nil)
      } else {
        // fallback to attempt to use the URL we got even though it doesn't
        // have the scheme we expected.
        signUpUrl = URL(string: trimmedUrlStr)
        supportsCardCreator = false
      }
    } else {
      signUpUrl = nil
      supportsCardCreator = false
    }
    
    super.init()
    
    if let urlString = authenticationDocument.links?.first(where: { $0.rel == "privacy-policy" })?.href,
      let url = URL(string: urlString) {
      setURL(url, forLicense: .privacyPolicy)
    }
    
    if let urlString = authenticationDocument.links?.first(where: { $0.rel == "terms-of-service" })?.href,
      let url = URL(string: urlString) {
      setURL(url, forLicense: .eula)
    }
    
    if let urlString = authenticationDocument.links?.first(where: { $0.rel == "license" })?.href,
      let url = URL(string: urlString) {
      setURL(url, forLicense: .contentLicenses)
    }
    
    if let urlString = authenticationDocument.links?.first(where: { $0.rel == "copyright" })?.href,
      let url = URL(string: urlString) {
      setURL(url, forLicense: .acknowledgements)
    }
  }

  func setURL(_ URL: URL, forLicense urlType: URLType) -> Void {
    switch urlType {
    case .acknowledgements:
      urlAcknowledgements = URL
      setAccountDictionaryKey("urlAcknowledgements", toValue: URL.absoluteString as AnyObject)
    case .contentLicenses:
      urlContentLicenses = URL
      setAccountDictionaryKey("urlContentLicenses", toValue: URL.absoluteString as AnyObject)
    case .eula:
      urlEULA = URL
      setAccountDictionaryKey("urlEULA", toValue: URL.absoluteString as AnyObject)
    case .privacyPolicy:
      urlPrivacyPolicy = URL
      setAccountDictionaryKey("urlPrivacyPolicy", toValue: URL.absoluteString as AnyObject)
    case .annotations:
      urlAnnotations = URL
      setAccountDictionaryKey("urlAnnotations", toValue: URL.absoluteString as AnyObject)
    }
  }
  
  func getLicenseURL(_ type: URLType) -> URL? {
    switch type {
    case .acknowledgements:
      if let url = urlAcknowledgements {
        return url
      } else {
        guard let urlString = getAccountDictionaryKey("urlAcknowledgements") as? String else { return nil }
        guard let result = URL(string: urlString) else { return nil }
        return result
      }
    case .contentLicenses:
      if let url = urlContentLicenses {
        return url
      } else {
        guard let urlString = getAccountDictionaryKey("urlContentLicenses") as? String else { return nil }
        guard let result = URL(string: urlString) else { return nil }
        return result
      }
    case .eula:
      if let url = urlEULA {
        return url
      } else {
        guard let urlString = getAccountDictionaryKey("urlEULA") as? String else { return nil }
        guard let result = URL(string: urlString) else { return nil }
        return result
      }
    case .privacyPolicy:
      if let url = urlPrivacyPolicy {
        return url
      } else {
        guard let urlString = getAccountDictionaryKey("urlPrivacyPolicy") as? String else { return nil }
        guard let result = URL(string: urlString) else { return nil }
        return result
      }
    case .annotations:
      if let url = urlAnnotations {
        return url
      } else {
        guard let urlString = getAccountDictionaryKey("urlAnnotations") as? String else { return nil }
        guard let result = URL(string: urlString) else { return nil }
        return result
      }
    }
  }
  
  fileprivate func setAccountDictionaryKey(_ key: String, toValue value: AnyObject) {
    if var savedDict = defaults.value(forKey: self.uuid) as? [String: AnyObject] {
      savedDict[key] = value
      defaults.set(savedDict, forKey: self.uuid)
    } else {
      defaults.set([key:value], forKey: self.uuid)
    }
  }
  
  fileprivate func getAccountDictionaryKey(_ key: String) -> AnyObject? {
    let savedDict = defaults.value(forKey: self.uuid) as? [String: AnyObject]
    guard let result = savedDict?[key] else { return nil }
    return result
  }
}

// MARK: Account
/// Object representing one library account in the app. Patrons may
/// choose to sign up for multiple Accounts.
@objcMembers final class Account: NSObject
{
  var logo:UIImage
  let uuid:String
  let name:String
  let subtitle:String?
  var supportEmail:EmailAddress? = nil
  var supportURL:URL? = nil
  let catalogUrl:String?
  var details:AccountDetails?
  var homePageUrl: String?
  lazy var hasSupportOption = { supportEmail != nil || supportURL != nil }()

  let authenticationDocumentUrl:String?
  var authenticationDocument:OPDS2AuthenticationDocument? {
    didSet {
      guard let authenticationDocument = authenticationDocument else {
        return
      }
      details = AccountDetails(authenticationDocument: authenticationDocument, uuid: uuid)
    }
  }
  

  var loansUrl: URL? {
    return details?.loansUrl
  }
  
  init(publication: OPDS2Publication) {
    
    name = publication.metadata.title
    subtitle = publication.metadata.description
    uuid = publication.metadata.id
  
    catalogUrl = publication.links.first(where: { $0.rel == "http://opds-spec.org/catalog" })?.href

    if let link = publication.links.first(where: { $0.rel == "help" })?.href {
      if let emailAddress = EmailAddress(rawValue: link) {
        supportEmail = emailAddress
      } else {
        supportURL = URL(string: link)
      }
    }
  
    authenticationDocumentUrl = publication.links.first(where: { $0.type == "application/vnd.opds.authentication.v1.0+json" })?.href
    logo = UIImage(named: "LibraryLogoMagic")!
    
    homePageUrl = publication.links.first(where: { $0.rel == "alternate" })?.href

    super.init()
    loadLogo(imageURL: publication.thumbnailURL)
  }

  /// Load authentication documents from the network or cache.
  /// Providing the signedInStateProvider might lead to presentation of announcements
  /// - Parameter signedInStateProvider: The object providing user signed in state for presenting announcement. nil means no announcements will be present
  /// - Parameter completion: Always invoked at the end of the load process.
  /// No guarantees are being made about whether this is called on the main
  /// thread or not. This closure is not retained by `self`.
  @objc(loadAuthenticationDocumentUsingSignedInStateProvider:completion:)
  func loadAuthenticationDocument(using signedInStateProvider: TPPSignedInStateProvider? = nil, completion: @escaping (Bool) -> ()) {
    Log.debug(#function, "Entering...")
    guard let urlString = authenticationDocumentUrl else {
      TPPErrorLogger.logError(
        withCode: .noURL,
        summary: "Failed to load authentication document because its URL is invalid",
        metadata: ["self.uuid": uuid,
                   "urlString": authenticationDocumentUrl ?? "N/A"]
      )
      completion(false)
      return
    }
    
    fetchAuthenticationDocument(urlString) { (document) in
      guard let authenticationDocument = document else {
        completion(false)
        return
      }
      
      self.authenticationDocument = authenticationDocument

      // Completion should be called before announcements,
      // otherwise the code that presents alerts interferes with catalog presentation.
      completion(true)

      if let announcements = self.authenticationDocument?.announcements {
        DispatchQueue.main.async {
          TPPAnnouncementBusinessLogic.shared.presentAnnouncements(announcements)
        }
      }
    }
  }
  
  private func fetchAuthenticationDocument(_ urlString: String, completion: @escaping (OPDS2AuthenticationDocument?) -> Void) {
    var document: OPDS2AuthenticationDocument?
    
    guard let url = URL(string: urlString) else {
      TPPErrorLogger.logError(
        withCode: .noURL,
        summary: "Failed to load authentication document because its URL is invalid",
        metadata: ["self.uuid": uuid,
                   "urlString": urlString]
      )
      completion(document)
      return
    }
    
    TPPNetworkExecutor.shared.GET(url) { result in
      switch result {
      case .success(let serverData, _):
        do {
          document = try OPDS2AuthenticationDocument.fromData(serverData)
          completion(document)
        } catch (let error) {
          let responseBody = String(data: serverData, encoding: .utf8)
          TPPErrorLogger.logError(
            withCode: .authDocParseFail,
            summary: "Authentication Document Data Parse Error",
            metadata: [
              "underlyingError": error,
              "responseBody": responseBody ?? "N/A",
              "url": url
            ]
          )
          completion(document)
        }
      case .failure(let error, _):
        TPPErrorLogger.logError(
          withCode: .authDocLoadFail,
          summary: "Authentication Document request failed to load",
          metadata: ["loadError": error, "url": url]
        )
        completion(document)
      }
    }
  }
  
  private func loadLogo(imageURL: URL?) {
    guard let url = imageURL else { return }

      self.fetchImage(from: url, completion: {
        guard let image = $0 else { return }
        self.logo = image
      })
  }

  private func fetchImage(from url: URL, completion: @escaping (UIImage?) -> ()) {
    TPPNetworkExecutor.shared.GET(url) { result in
      switch result {
      case .success(let serverData, _):
        completion(UIImage(data: serverData))
      case .failure(let error, _):
        TPPErrorLogger.logError(
          withCode: .authDocLoadFail,
          summary: "Logo image failed to load",
          metadata: ["loadError": error, "url": url]
        )
        completion(nil)
      }
    }
  }
}

extension AccountDetails {
  override var debugDescription: String {
    return """
    supportsSimplyESync=\(supportsSimplyESync)
    supportsCardCreator=\(supportsCardCreator)
    supportsReservations=\(supportsReservations)
    """
  }
}

extension Account {
  override var debugDescription: String {
    return """
    name=\(name)
    uuid=\(uuid)
    catalogURL=\(String(describing: catalogUrl))
    authDocURL=\(String(describing: authenticationDocumentUrl))
    details=\(String(describing: details?.debugDescription))
    """
  }
}

// MARK: URLType
@objc enum URLType: Int {
  case acknowledgements
  case contentLicenses
  case eula
  case privacyPolicy
  case annotations
}

// MARK: LoginKeyboard
@objc enum LoginKeyboard: Int, Codable {
  case standard
  case email
  case numeric
  case none

  init?(_ stringValue: String?) {
    if stringValue == "Default" {
      self = .standard
    } else if stringValue == "Email address" {
      self = .email
    } else if stringValue == "Number pad" {
      self = .numeric
    } else if stringValue == "No input" {
      self = .none
    } else {
      Log.error(#file, "Invalid init parameter for PatronPINKeyboard: \(stringValue ?? "nil")")
      return nil
    }
  }
}

import Foundation

// MARK: - TPPAgeCheckValidationDelegate

protocol TPPAgeCheckValidationDelegate: AnyObject {
  var minYear: Int { get }
  var currentYear: Int { get }
  var birthYearList: [Int] { get }
  var ageCheckCompleted: Bool { get set }

  func isValid(birthYear: Int) -> Bool

  func didCompleteAgeCheck(_ birthYear: Int)
  func didFailAgeCheck()
}

// MARK: - TPPAgeCheckVerifying

@objc protocol TPPAgeCheckVerifying {
  func verifyCurrentAccountAgeRequirement(
    userAccountProvider: TPPUserAccountProvider,
    currentLibraryAccountProvider: TPPCurrentLibraryAccountProvider,
    completion: ((Bool) -> Void)?
  )
}

// MARK: - TPPAgeCheckChoiceStorage

@objc protocol TPPAgeCheckChoiceStorage {
  var userPresentedAgeCheck: Bool { get set }
}

// MARK: - TPPAgeCheck

@objcMembers final class TPPAgeCheck: NSObject, TPPAgeCheckValidationDelegate, TPPAgeCheckVerifying {
  // Members
  private let serialQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).ageCheck")
  private var handlerList = [(Bool) -> Void]()
  private var isPresenting = false
  private let ageCheckChoiceStorage: TPPAgeCheckChoiceStorage
  var ageCheckCompleted: Bool = false

  let minYear: Int
  let currentYear: Int
  let birthYearList: [Int]

  init(ageCheckChoiceStorage: TPPAgeCheckChoiceStorage) {
    self.ageCheckChoiceStorage = ageCheckChoiceStorage
    minYear = 1900
    currentYear = Calendar.current.component(.year, from: Date())
    birthYearList = Array(minYear...currentYear)

    super.init()
  }

  func verifyCurrentAccountAgeRequirement(
    userAccountProvider: TPPUserAccountProvider,
    currentLibraryAccountProvider: TPPCurrentLibraryAccountProvider,
    completion: ((Bool) -> Void)?
  ) {
    serialQueue.async { [weak self] in
      guard let accountDetails = currentLibraryAccountProvider.currentAccount?.details else {
        completion?(false)
        return
      }

      if userAccountProvider.needsAuth == true || accountDetails.userAboveAgeLimit {
        completion?(true)
        return
      }

      if !accountDetails.userAboveAgeLimit && (self?.ageCheckChoiceStorage.userPresentedAgeCheck ?? false) {
        completion?(false)
        return
      }

      // Queue the callback
      if let completion = completion {
        self?.handlerList.append(completion)
      }

      // We're already presenting the age verification, return
      if self?.isPresenting ?? false {
        return
      }

      let accountDetailsCompletion: ((Bool) -> Void) = { aboveAgeLimit in
        accountDetails.userAboveAgeLimit = aboveAgeLimit
      }
      self?.handlerList.append(accountDetailsCompletion)

      // Perform age check presentation
      self?.isPresenting = true
      self?.presentAgeVerificationView()
    }
  }

  fileprivate func presentAgeVerificationView() {
    DispatchQueue.main.async {
      let vc = TPPAgeCheckViewController(ageCheckDelegate: self)
      let navigationVC = UINavigationController(rootViewController: vc)
      TPPPresentationUtils.safelyPresent(navigationVC)
    }
  }

  func isValid(birthYear: Int) -> Bool {
    birthYear >= minYear && birthYear <= currentYear
  }

  func didCompleteAgeCheck(_ birthYear: Int) {
    serialQueue.async { [weak self] in
      let aboveAgeLimit = Calendar.current.component(.year, from: Date()) - birthYear > 13
      self?.ageCheckChoiceStorage.userPresentedAgeCheck = true
      self?.isPresenting = false

      for handler in self?.handlerList ?? [] {
        handler(aboveAgeLimit)
      }
      self?.handlerList.removeAll()
    }
  }

  func didFailAgeCheck() {
    serialQueue.async { [weak self] in
      self?.isPresenting = false
      self?.ageCheckChoiceStorage.userPresentedAgeCheck = false
      self?.handlerList.removeAll()
    }
  }
}

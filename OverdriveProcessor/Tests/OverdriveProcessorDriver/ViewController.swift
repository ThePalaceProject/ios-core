import UIKit
import os
@testable import OverdriveProcessor

class ViewController: UIViewController {

  let clientKey = ""
  let clientSecret = ""
    
  let patronUsername = ""
  let patronPassword = ""
    
  let borrowURL = ""
  let fulfillURL = ""

  var scope = ""
  var manifestURL = ""
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    requestBearerToken()
//    requestPatronToken()
    borrowBook()
//    fulfillBook()
  }
    
  func borrowBook() {
    print("!!! Borrowing Book !!!")
    OverdriveAPIExecutor.shared.borrowBook(urlString: borrowURL, username: patronUsername, PIN: patronPassword) { (json, error) in
      if let error = error {
        print("Error - \(error)")
      }
      
      if let json = json {
        print("\(json)")
      }
      
      self.fulfillBook()
    }
  }
    
  func fulfillBook() {
    print("!!! Fulfilling Loan !!!")
    OverdriveAPIExecutor.shared.fulfillBook(urlString: fulfillURL, username: patronUsername, PIN: patronPassword) { (responseHeader, error) in
      if let error = error {
        print("Error - \(error)")
      }
      
      if let responseHeader = responseHeader {
        guard let scope = (responseHeader["x-overdrive-scope"] ?? responseHeader["X-Overdrive-Scope"]) as? String,
          let urlString = (responseHeader["location"] ?? responseHeader["Location"]) as? String else {
            print("Failed to extract scope and manifest url\n header: \(responseHeader)")
            return
        }
        print("Scope: \(scope)")
        print("Manifest URL: \(urlString)")
        self.scope = scope
        self.manifestURL = urlString
        self.requestPatronToken()
      }
    }
  }
    
  func requestBearerToken() {
    print("!!! Request Bearer Token !!!")
    OverdriveAPIExecutor.shared.refreshBearerToken(key: clientKey, secret: clientSecret) { (error) in
      if let error = error {
        print("Error - \(error)")
      }
    
      if let token = OverdriveAPIExecutor.shared.bearerToken {
        print("OAuth token - \(token)")
      }
    }
  }
    
  func requestPatronToken() {
    print("!!! Request Patron Token !!!")
    OverdriveAPIExecutor.shared.refreshPatronToken(key: clientKey,
                                                   secret: clientSecret,
                                                   username: patronUsername,
                                                   PIN: patronPassword,
                                                   scope: scope) { (error) in
      if let error = error {
        print("Error - \(error)")
      }
      if OverdriveAPIExecutor.shared.hasValidPatronToken(username: self.patronUsername, scope: self.scope) {
        print("Patron token request succeed")
        self.requestManifest(scope: self.scope)
      }
    }
  }
    
  func requestManifest(scope: String) {
    print("!!! Request Manifest !!!")
    OverdriveAPIExecutor.shared.requestManifest(urlString: self.manifestURL, username: patronUsername, scope: scope) { (json, error) in
      if let error = error {
        print("Error - \(error)")
      }
      
      if let json = json {
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
            let prettyPrintedString = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
            print(prettyPrintedString)
        } else {
            print("\(json)")
        }
        
      }
    }
  }
}


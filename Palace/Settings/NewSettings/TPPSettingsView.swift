//
//  TPPSettingsView.swift
//  Palace
//
//  Created by Maurice Carrier on 12/2/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPSettingsView: View {
  typealias Strings = DisplayStrings.Settings
  @State private var showDeveloperSettings = false

  var body: some View {
    List {
      librariesSection
      infoSection
      developerSettingsSection
    }
    .navigationBarTitle(Strings.settings)
    .listStyle(GroupedListStyle())
  }

  @ViewBuilder private var librariesSection: some View {
    let accounts = TPPSettings.shared.settingsAccountsList
    let viewController = TPPSettingsAccountsTableViewController(accounts: accounts)
    let navButton = Button(Strings.addLibrary) {
      viewController.addAccount()
    }

    let wrapper = UIViewControllerWrapper(viewController) { _ in }
      .navigationBarTitle(Text(Strings.libraries))
      .navigationBarItems(trailing: navButton)
    
    Section {
      row(title: Strings.libraries, destination: wrapper.anyView())
    }
  }

  @ViewBuilder private var infoSection: some View {
    let view: AnyView = showDeveloperSettings ? EmptyView().anyView() : versionInfo.anyView()
      Section(footer: view) {
        aboutRow
        privacyRow
        userAgreementRow
        softwareLicenseRow
      }
  }

  @ViewBuilder private var aboutRow: some View {
    let viewController = RemoteHTMLViewController(
      URL: URL(string: TPPSettings.TPPAboutPalaceURLString)!,
      title: DisplayStrings.Settings.aboutApp,
      failureMessage: DisplayStrings.Error.loadFailedError
    )
    
    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(Strings.aboutApp))

    row(title: Strings.aboutApp, destination: wrapper.anyView())
  }

  @ViewBuilder private var privacyRow: some View {
    let viewController = RemoteHTMLViewController(
      URL: URL(string: TPPSettings.TPPPrivacyPolicyURLString)!,
      title: DisplayStrings.Settings.privacyPolicy,
      failureMessage: DisplayStrings.Error.loadFailedError
    )
   
    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(Strings.privacyPolicy))
    
    row(title: Strings.privacyPolicy, destination: wrapper.anyView())
  }

  @ViewBuilder private var userAgreementRow: some View {
    let viewController = RemoteHTMLViewController(
      URL: URL(string: TPPSettings.TPPUserAgreementURLString)!,
      title: DisplayStrings.Settings.eula,
      failureMessage: DisplayStrings.Error.loadFailedError
    )

    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(Strings.eula))
    
    row(title: Strings.eula, destination: wrapper.anyView())
  }

  @ViewBuilder private var softwareLicenseRow: some View {
    let viewController = BundledHTMLViewController(
      fileURL: Bundle.main.url(forResource: "software-licenses", withExtension: "html")!,
      title: DisplayStrings.Settings.softwareLicenses
    )

    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(Strings.softwareLicenses))
    
    row(title: Strings.softwareLicenses, destination: wrapper.anyView())
  }

  @ViewBuilder private var developerSettingsSection: some View {
    if (TPPSettings.shared.customMainFeedURL == nil && showDeveloperSettings) {
      Section(footer: versionInfo) {
        let viewController = TPPDeveloperSettingsTableViewController()
          
        let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
          .navigationBarTitle(Text(Strings.developerSettings))
        
        row(title: Strings.developerSettings, destination: wrapper.anyView())
      }
    }
  }

  @ViewBuilder private var versionInfo: some View {
    let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    let build = Bundle.main.object(forInfoDictionaryKey: (kCFBundleVersionKey as String)) as! String
    
    Text("\(productName) version \(version) (\(build))")
      .font(Font(uiFont: UIFont.palaceFont(ofSize: 12)))
      .foregroundColor(.white)
      .onTapGesture(count: 7) {
        self.showDeveloperSettings = true
      }
      .horizontallyCentered()
  }
  
  private func row(title: String, destination: AnyView) -> some View {
    NavigationLink(destination: destination) {
      Text(title)
    }
  }
}
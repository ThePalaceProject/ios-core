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
  @State private var selectedView: Int? = 0
  @State private var orientation: UIDeviceOrientation = UIDevice.current.orientation

  private var sideBarEnabled: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
      &&  UIDevice.current.orientation != .portrait
      &&  UIDevice.current.orientation != .portraitUpsideDown
  }

  var body: some View {
    if sideBarEnabled {
      NavigationView {
        listView
          .onAppear {
            selectedView = 1
          }
      }
    } else {
      listView
        .onAppear {
          selectedView = 0
        }
    }
  }

  @ViewBuilder private var listView: some View {
    List {
      librariesSection
      infoSection
      developerSettingsSection
    }
    .navigationBarTitle(Strings.settings)
    .listStyle(GroupedListStyle())
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      self.orientation = UIDevice.current.orientation
    }
  }

  @ViewBuilder private var librariesSection: some View {
    let viewController = TPPSettingsAccountsTableViewController(accounts: TPPSettings.shared.settingsAccountsList)
    let navButton = Button(Strings.addLibrary) {
      viewController.addAccount()
    }

    let wrapper = UIViewControllerWrapper(viewController) { _ in }
      .navigationBarTitle(Text(Strings.libraries))
      .navigationBarItems(trailing: navButton)
    
    Section {
      row(title: Strings.libraries, index: 1, selection: self.$selectedView, destination: wrapper.anyView())
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

    row(title: Strings.aboutApp, index: 2, selection: self.$selectedView, destination: wrapper.anyView())
  }

  @ViewBuilder private var privacyRow: some View {
    let viewController = RemoteHTMLViewController(
      URL: URL(string: TPPSettings.TPPPrivacyPolicyURLString)!,
      title: DisplayStrings.Settings.privacyPolicy,
      failureMessage: DisplayStrings.Error.loadFailedError
    )
   
    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(Strings.privacyPolicy))
    
    row(title: Strings.privacyPolicy, index: 3, selection: self.$selectedView, destination: wrapper.anyView())

  }

  @ViewBuilder private var userAgreementRow: some View {
    let viewController = RemoteHTMLViewController(
      URL: URL(string: TPPSettings.TPPUserAgreementURLString)!,
      title: DisplayStrings.Settings.eula,
      failureMessage: DisplayStrings.Error.loadFailedError
    )

    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(Strings.eula))
    
    row(title: Strings.eula, index: 4, selection: self.$selectedView, destination: wrapper.anyView())
  }

  @ViewBuilder private var softwareLicenseRow: some View {
    let viewController = BundledHTMLViewController(
      fileURL: Bundle.main.url(forResource: "software-licenses", withExtension: "html")!,
      title: DisplayStrings.Settings.softwareLicenses
    )

    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(Strings.softwareLicenses))
    
    row(title: Strings.softwareLicenses, index: 5, selection: self.$selectedView, destination: wrapper.anyView())
  }

  @ViewBuilder private var developerSettingsSection: some View {
    if (TPPSettings.shared.customMainFeedURL == nil && showDeveloperSettings) {
      Section(footer: versionInfo) {
        let viewController = TPPDeveloperSettingsTableViewController()
          
        let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
          .navigationBarTitle(Text(Strings.developerSettings))
        
        row(title: Strings.developerSettings, index: 6, selection: self.$selectedView, destination: wrapper.anyView())
      }
    }
  }

  @ViewBuilder private var versionInfo: some View {
    let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    let build = Bundle.main.object(forInfoDictionaryKey: (kCFBundleVersionKey as String)) as! String
    
    Text("\(productName) version \(version) (\(build))")
      .font(Font(uiFont: UIFont.palaceFont(ofSize: 12)))
      .onTapGesture(count: 7) {
        self.showDeveloperSettings = true
      }
      .frame(height: 40)
      .horizontallyCentered()
  }
  
  private func row(title: String, index: Int, selection: Binding<Int?>, destination: AnyView) -> some View {
    NavigationLink(
      destination: destination,
      tag: index,
      selection: selection,
      label: { Text(title) }
    )
  }
}

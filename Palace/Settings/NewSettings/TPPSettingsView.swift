//
//  TPPSettingsView.swift
//  Palace
//
//  Created by Maurice Carrier on 12/2/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPSettingsView: View {
  typealias DisplayStrings = Strings.Settings

  @AppStorage(TPPSettings.showDeveloperSettingsKey) private var showDeveloperSettings: Bool = false
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
    .navigationBarTitle(DisplayStrings.settings)
    .listStyle(GroupedListStyle())
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      self.orientation = UIDevice.current.orientation
    }
  }

  @ViewBuilder private var librariesSection: some View {
    let viewController = TPPSettingsAccountsTableViewController(accounts: TPPSettings.shared.settingsAccountsList)
    let navButton = Button(DisplayStrings.addLibrary) {
      viewController.addAccount()
    }

    let wrapper = UIViewControllerWrapper(viewController) { _ in }
      .navigationBarTitle(Text(DisplayStrings.libraries))
      .navigationBarItems(trailing: navButton)

    Section {
      row(title: DisplayStrings.libraries, index: 1, selection: self.$selectedView, destination: wrapper.anyView())
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
      title: Strings.Settings.aboutApp,
      failureMessage: Strings.Error.loadFailedError
    )
    
    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(DisplayStrings.aboutApp))

    row(title: DisplayStrings.aboutApp, index: 2, selection: self.$selectedView, destination: wrapper.anyView())
  }

  @ViewBuilder private var privacyRow: some View {
    let viewController = RemoteHTMLViewController(
      URL: URL(string: TPPSettings.TPPPrivacyPolicyURLString)!,
      title: Strings.Settings.privacyPolicy,
      failureMessage: Strings.Error.loadFailedError
    )

    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(DisplayStrings.privacyPolicy))

    row(title: DisplayStrings.privacyPolicy, index: 3, selection: self.$selectedView, destination: wrapper.anyView())

  }

  @ViewBuilder private var userAgreementRow: some View {
    let viewController = RemoteHTMLViewController(
      URL: URL(string: TPPSettings.TPPUserAgreementURLString)!,
      title: Strings.Settings.eula,
      failureMessage: Strings.Error.loadFailedError
    )
    
    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(DisplayStrings.eula))

    row(title: DisplayStrings.eula, index: 4, selection: self.$selectedView, destination: wrapper.anyView())
  }

  @ViewBuilder private var softwareLicenseRow: some View {
    let viewController = BundledHTMLViewController(
      fileURL: Bundle.main.url(forResource: "software-licenses", withExtension: "html")!,
      title: Strings.Settings.softwareLicenses
    )
    
    let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
      .navigationBarTitle(Text(DisplayStrings.softwareLicenses))

    row(title: DisplayStrings.softwareLicenses, index: 5, selection: self.$selectedView, destination: wrapper.anyView())
  }

  @ViewBuilder private var developerSettingsSection: some View {
    if (TPPSettings.shared.customMainFeedURL == nil && showDeveloperSettings) {
      Section(footer: versionInfo) {
        let viewController = TPPDeveloperSettingsTableViewController()
          
        let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
          .navigationBarTitle(Text(DisplayStrings.developerSettings))
        
        row(title: DisplayStrings.developerSettings, index: 6, selection: self.$selectedView, destination: wrapper.anyView())
      }
    }
  }

  @ViewBuilder private var versionInfo: some View {
    let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    let build = Bundle.main.object(forInfoDictionaryKey: (kCFBundleVersionKey as String)) as! String
    
    Text("\(productName) version \(version) (\(build))")
      .font(Font(uiFont: UIFont.palaceFont(ofSize: 12)))
      .gesture(
        LongPressGesture(minimumDuration: 5.0)
          .onEnded { _ in
                    self.showDeveloperSettings = true
          }
      )
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

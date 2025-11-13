//
//  TPPSettingsView.swift
//  Palace
//
//  Created by Maurice Carrier on 12/2/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

struct TPPSettingsView: View {
  typealias DisplayStrings = Strings.Settings

  @AppStorage(TPPSettings.showDeveloperSettingsKey) private var showDeveloperSettings: Bool = false
  @State private var selectedView: Int? = 0
  @State private var orientation: UIDeviceOrientation = UIDevice.current.orientation
  @State private var showAddLibrarySheet: Bool = false
  @State private var librariesRefreshToken: UUID = UUID()
  @State private var currentAccounts: [Account] = []
  
  init() {
    _currentAccounts = State(initialValue: TPPSettings.shared.settingsAccountsList)
  }

  private var sideBarEnabled: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
      &&  UIDevice.current.orientation != .portrait
      &&  UIDevice.current.orientation != .portraitUpsideDown
  }

  var body: some View {
    if sideBarEnabled {
      NavigationView {
        listView
        detailView
      }
      .navigationViewStyle(.columns)
    } else {
      listView
    }
  }
  
  @ViewBuilder private var detailView: some View {
    let viewController = TPPSettingsAccountsTableViewController(accounts: currentAccounts)
    let navButton = Button(DisplayStrings.addLibrary) {
      showAddLibrarySheet = true
    }

    UIViewControllerWrapper(viewController) { _ in }
      .navigationBarTitle(Text(DisplayStrings.libraries))
      .navigationBarItems(trailing: navButton)
      .id(librariesRefreshToken)
  }

  @ViewBuilder private var listView: some View {
    List {
      librariesSection
      infoSection
      developerSettingsSection
    }
    .navigationBarTitle(DisplayStrings.settings)
    .listStyle(GroupedListStyle())
    .onAppear {
      updateAccountsList()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      self.orientation = UIDevice.current.orientation
    }
    .onReceive(NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)) { _ in
      updateAccountsList()
      librariesRefreshToken = UUID()
    }
    .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)) { _ in
      updateAccountsList()
      librariesRefreshToken = UUID()
    }
    .sheet(isPresented: $showAddLibrarySheet) {
      UIViewControllerWrapper(
        TPPAccountList { account in
          DispatchQueue.main.async {
            MyBooksViewModel().loadAccount(account)
            showAddLibrarySheet = false
          }
        },
        updater: { _ in }
      )
    }
  }

  @ViewBuilder private var librariesSection: some View {
    let viewController = TPPSettingsAccountsTableViewController(accounts: currentAccounts)
    let navButton = Button(DisplayStrings.addLibrary) {
      showAddLibrarySheet = true
    }

    let wrapper = UIViewControllerWrapper(viewController) { _ in }
      .navigationBarTitle(Text(DisplayStrings.libraries))
      .navigationBarItems(trailing: navButton)
      .id(librariesRefreshToken)

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
    let viewController = RemoteHTMLViewController(
      URL: URL(string: TPPSettings.TPPSoftwareLicensesURLString)!,
      title: Strings.Settings.softwareLicenses,
      failureMessage: Strings.Error.loadFailedError
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
    let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Palace"
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: (kCFBundleVersionKey as String)) as? String ?? "Unknown"
    
    Text("\(productName) version \(version) (\(build))")
      .palaceFont(size: 12)
      .gesture(
        LongPressGesture(minimumDuration: 5.0)
          .onEnded { _ in
            self.showDeveloperSettings.toggle()
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
      label: {
        Text(title)
          .palaceFont(.body)
      }
    )
  }
  
  private func updateAccountsList() {
    currentAccounts = TPPSettings.shared.settingsAccountsList
  }
}

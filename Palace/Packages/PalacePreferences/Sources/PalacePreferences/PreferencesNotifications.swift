//
//  PreferencesNotifications.swift
//  PalacePreferences
//
//  The settings-change notification names TPPSettings posts, declared here
//  because this package cannot reach app-target declarations. Observers match
//  on the string values: never change them.
//

import Foundation

public extension Notification.Name {
    static let TPPSettingsDidChange = Notification.Name("TPPSettingsDidChange")
    static let TPPUseBetaDidChange = Notification.Name("TPPUseBetaDidChange")
}

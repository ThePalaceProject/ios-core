//
//  PreferencesNotifications.swift
//  PalacePreferences
//
//  The two settings-change notification names TPPSettings posts. Moved here
//  from the app target's NSNotification+TPP.swift in Wave 1a (the Layer-0
//  package cannot reach app-target declarations). String values are wire
//  format — never change them.
//

import Foundation

public extension Notification.Name {
    static let TPPSettingsDidChange = Notification.Name("TPPSettingsDidChange")
    static let TPPUseBetaDidChange = Notification.Name("TPPUseBetaDidChange")
}

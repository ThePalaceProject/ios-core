import XCTest

/// Handles system alerts and permission dialogs automatically
/// This prevents tests from getting blocked by unexpected system popups
final class SystemAlertHandler {
  
  private weak var testCase: XCTestCase?
  private var monitors: [NSObjectProtocol] = []
  
  init(testCase: XCTestCase) {
    self.testCase = testCase
  }
  
  /// Sets up handlers for all common system alerts
  /// Call this in your test's setUp method
  func setupAllHandlers() {
    setupNotificationHandler()
    setupTrackingHandler()
    setupLocationHandler()
    setupPhotosHandler()
    setupCameraHandler()
    setupMicrophoneHandler()
    setupContactsHandler()
    setupCalendarHandler()
    setupHealthHandler()
    setupBluetoothHandler()
    setupLocalNetworkHandler()
    setupGenericAlertHandler()
  }
  
  /// Removes all handlers - call in tearDown
  func removeAllHandlers() {
    monitors.forEach { monitor in
      testCase?.removeUIInterruptionMonitor(monitor)
    }
    monitors.removeAll()
  }
  
  /// Directly dismisses any visible system alert (springboard alerts)
  /// Call this when you suspect a system alert is blocking the test
  /// Returns true if an alert was dismissed
  @discardableResult
  static func dismissSystemAlertIfPresent() -> Bool {
    // Access the springboard (system UI) to find alerts
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    
    // Common button labels for system alerts
    let buttonLabels = ["Allow", "Don't Allow", "OK", "Cancel", "Not Now", 
                        "Ask App Not to Track", "Allow While Using App", 
                        "Allow Once", "Dismiss", "Close"]
    
    for label in buttonLabels {
      let button = springboard.buttons[label]
      if button.waitForExistence(timeout: 1.0) && button.isHittable {
        print("🔔 Dismissing system alert - tapping '\(label)'")
        button.tap()
        Thread.sleep(forTimeInterval: 0.5)
        return true
      }
    }
    
    // Also check alerts collection
    let alert = springboard.alerts.firstMatch
    if alert.exists {
      // Try to find any button in the alert
      let alertButtons = alert.buttons
      if alertButtons.count > 0 {
        // Prefer "Allow" or first button
        let allowButton = alert.buttons["Allow"]
        if allowButton.exists {
          print("🔔 Dismissing alert via Allow button")
          allowButton.tap()
          Thread.sleep(forTimeInterval: 0.5)
          return true
        }
        
        let firstButton = alertButtons.element(boundBy: 0)
        if firstButton.exists && firstButton.isHittable {
          print("🔔 Dismissing alert via first button: \(firstButton.label)")
          firstButton.tap()
          Thread.sleep(forTimeInterval: 0.5)
          return true
        }
      }
    }
    
    return false
  }
  
  /// Repeatedly checks for and dismisses system alerts
  /// Useful at app startup when multiple alerts may appear
  static func dismissAllSystemAlerts(maxAttempts: Int = 5) {
    for attempt in 1...maxAttempts {
      if dismissSystemAlertIfPresent() {
        print("   Dismissed alert (attempt \(attempt))")
        // Check for more alerts
        Thread.sleep(forTimeInterval: 0.5)
      } else {
        // No more alerts
        break
      }
    }
  }
  
  // MARK: - Specific Handlers
  
  /// Notifications: "Would Like to Send You Notifications"
  private func setupNotificationHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Notification Permission") { alert in
      let allowButton = alert.buttons["Allow"]
      let dontAllowButton = alert.buttons["Don't Allow"]
      
      if allowButton.exists {
        allowButton.tap()
        print("🔔 Handled notification permission - tapped Allow")
        return true
      } else if dontAllowButton.exists {
        dontAllowButton.tap()
        print("🔔 Handled notification permission - tapped Don't Allow")
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// App Tracking Transparency: "Allow to track your activity"
  private func setupTrackingHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Tracking Permission") { alert in
      // iOS 14.5+ tracking permission
      let allowButton = alert.buttons["Allow"]
      let askNotToTrack = alert.buttons["Ask App Not to Track"]
      
      if askNotToTrack.exists {
        askNotToTrack.tap()
        print("🔒 Handled tracking permission - tapped Ask Not to Track")
        return true
      } else if allowButton.exists {
        allowButton.tap()
        print("🔒 Handled tracking permission - tapped Allow")
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Location: "Would Like to Use Your Location"
  private func setupLocationHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Location Permission") { alert in
      let allowOnce = alert.buttons["Allow Once"]
      let allowWhileUsing = alert.buttons["Allow While Using App"]
      let dontAllow = alert.buttons["Don't Allow"]
      
      if allowWhileUsing.exists {
        allowWhileUsing.tap()
        print("📍 Handled location permission - tapped Allow While Using")
        return true
      } else if allowOnce.exists {
        allowOnce.tap()
        print("📍 Handled location permission - tapped Allow Once")
        return true
      } else if dontAllow.exists {
        dontAllow.tap()
        print("📍 Handled location permission - tapped Don't Allow")
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Photos: "Would Like to Access Your Photos"
  private func setupPhotosHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Photos Permission") { alert in
      let allowFullAccess = alert.buttons["Allow Full Access"]
      let selectPhotos = alert.buttons["Select Photos..."]
      let dontAllow = alert.buttons["Don't Allow"]
      
      if allowFullAccess.exists {
        allowFullAccess.tap()
        print("🖼️ Handled photos permission - tapped Allow Full Access")
        return true
      } else if selectPhotos.exists {
        selectPhotos.tap()
        print("🖼️ Handled photos permission - tapped Select Photos")
        return true
      } else if dontAllow.exists {
        dontAllow.tap()
        print("🖼️ Handled photos permission - tapped Don't Allow")
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Camera: "Would Like to Access the Camera"
  private func setupCameraHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Camera Permission") { alert in
      if handleOKOrAllowOrDeny(alert, name: "camera") {
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Microphone: "Would Like to Access the Microphone"
  private func setupMicrophoneHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Microphone Permission") { alert in
      if handleOKOrAllowOrDeny(alert, name: "microphone") {
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Contacts: "Would Like to Access Your Contacts"
  private func setupContactsHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Contacts Permission") { alert in
      if handleOKOrAllowOrDeny(alert, name: "contacts") {
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Calendar: "Would Like to Access Your Calendar"
  private func setupCalendarHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Calendar Permission") { alert in
      if handleOKOrAllowOrDeny(alert, name: "calendar") {
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// HealthKit: "Would Like to Access Your Health Data"
  private func setupHealthHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Health Permission") { alert in
      if handleOKOrAllowOrDeny(alert, name: "health") {
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Bluetooth: "Would Like to Use Bluetooth"
  private func setupBluetoothHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Bluetooth Permission") { alert in
      if handleOKOrAllowOrDeny(alert, name: "bluetooth") {
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Local Network: "Would Like to Find and Connect to Devices"
  private func setupLocalNetworkHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Local Network Permission") { alert in
      if handleOKOrAllowOrDeny(alert, name: "local network") {
        return true
      }
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
  
  /// Generic handler for any other alerts
  private func setupGenericAlertHandler() {
    let monitor = testCase?.addUIInterruptionMonitor(withDescription: "Generic Alert") { alert in
      // Common button labels to dismiss alerts
      let dismissButtons = ["OK", "Allow", "Don't Allow", "Cancel", "Close", "Dismiss", "Not Now", "Later"]
      
      for buttonLabel in dismissButtons {
        let button = alert.buttons[buttonLabel]
        if button.exists {
          button.tap()
          print("⚠️ Handled generic alert - tapped \(buttonLabel)")
          return true
        }
      }
      
      // If no known button, try the first button
      if alert.buttons.count > 0 {
        let firstButton = alert.buttons.element(boundBy: 0)
        if firstButton.exists {
          firstButton.tap()
          print("⚠️ Handled unknown alert - tapped first button: \(firstButton.label)")
          return true
        }
      }
      
      return false
    }
    if let monitor = monitor { monitors.append(monitor) }
  }
}

// MARK: - Helper Functions

/// Handles common OK/Allow/Don't Allow patterns
private func handleOKOrAllowOrDeny(_ alert: XCUIElement, name: String) -> Bool {
  let okButton = alert.buttons["OK"]
  let allowButton = alert.buttons["Allow"]
  let dontAllowButton = alert.buttons["Don't Allow"]
  
  if okButton.exists {
    okButton.tap()
    print("✅ Handled \(name) permission - tapped OK")
    return true
  } else if allowButton.exists {
    allowButton.tap()
    print("✅ Handled \(name) permission - tapped Allow")
    return true
  } else if dontAllowButton.exists {
    dontAllowButton.tap()
    print("✅ Handled \(name) permission - tapped Don't Allow")
    return true
  }
  return false
}

// MARK: - XCTestCase Extension

extension XCTestCase {
  
  /// Quick setup for system alert handling
  /// Usage: `let handler = setupSystemAlertHandling()`
  /// Don't forget to call `handler.removeAllHandlers()` in tearDown
  func setupSystemAlertHandling() -> SystemAlertHandler {
    let handler = SystemAlertHandler(testCase: self)
    handler.setupAllHandlers()
    return handler
  }
  
  /// Alternative: Setup and auto-cleanup with completion
  func withSystemAlertHandling(_ test: () -> Void) {
    let handler = SystemAlertHandler(testCase: self)
    handler.setupAllHandlers()
    test()
    handler.removeAllHandlers()
  }
}


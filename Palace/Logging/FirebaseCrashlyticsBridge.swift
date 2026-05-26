import Foundation
import PalaceLogging
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

/// Forwards `Log` non-debug messages to Firebase Crashlytics. Registered on
/// `Log.crashlyticsBridge` at app startup so PalaceLogging itself stays free
/// of any Firebase dependency.
final class FirebaseCrashlyticsBridge: CrashlyticsLogBridge {
    func log(_ message: String) {
        #if canImport(FirebaseCrashlytics)
        Crashlytics.crashlytics().log(message)
        #endif
    }
}

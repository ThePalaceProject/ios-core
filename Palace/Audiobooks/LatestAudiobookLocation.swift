import Foundation

private let latestLocationQueue = DispatchQueue(
  label: "com.palace.latestAudiobookLocation",
  attributes: .concurrent
)

private var _latestAudiobookLocation: (book: String, location: String)?

var latestAudiobookLocation: (book: String, location: String)? {
  get {
    latestLocationQueue.sync { _latestAudiobookLocation }
  }
  set {
    latestLocationQueue.async(flags: .barrier) {
      _latestAudiobookLocation = newValue
    }
  }
}

import Foundation

@objc enum TPPMyBooksDownloadRightsManagement: Int {
  case unknown
  case none
  case adobe
  case simplifiedBearerTokenJSON
  case overdriveManifestJSON
  case lcp
}

@objc class TPPMyBooksDownloadInfo: NSObject {

  @objc private(set) var downloadProgress: CGFloat
  @objc private(set) var downloadTask: URLSessionDownloadTask
  @objc private(set) var rightsManagement: TPPMyBooksDownloadRightsManagement
  @objc private(set) var bearerToken: TPPMyBooksSimplifiedBearerToken?

  @objc init(downloadProgress: CGFloat, downloadTask: URLSessionDownloadTask, rightsManagement: TPPMyBooksDownloadRightsManagement) {
    self.downloadProgress = downloadProgress
    self.downloadTask = downloadTask
    self.rightsManagement = rightsManagement
    self.bearerToken = nil
    super.init()
  }

  @objc init(downloadProgress: CGFloat, downloadTask: URLSessionDownloadTask, rightsManagement: TPPMyBooksDownloadRightsManagement, bearerToken: TPPMyBooksSimplifiedBearerToken?) {
    self.downloadProgress = downloadProgress
    self.downloadTask = downloadTask
    self.rightsManagement = rightsManagement
    self.bearerToken = bearerToken
    super.init()
  }

  @objc func withDownloadProgress(_ downloadProgress: CGFloat) -> TPPMyBooksDownloadInfo {
    return TPPMyBooksDownloadInfo(
      downloadProgress: downloadProgress,
      downloadTask: self.downloadTask,
      rightsManagement: self.rightsManagement,
      bearerToken: self.bearerToken
    )
  }

  @objc func withRightsManagement(_ rightsManagement: TPPMyBooksDownloadRightsManagement) -> TPPMyBooksDownloadInfo {
    return TPPMyBooksDownloadInfo(
      downloadProgress: self.downloadProgress,
      downloadTask: self.downloadTask,
      rightsManagement: rightsManagement,
      bearerToken: self.bearerToken
    )
  }

  @objc var rightsManagementString: String {
    switch rightsManagement {
    case .unknown: return "Unknown"
    case .none: return "None"
    case .adobe: return "Adobe"
    case .simplifiedBearerTokenJSON: return "SimplifiedBearerTokenJSON"
    case .overdriveManifestJSON: return "OverdriveManifestJSON"
    case .lcp: return "LCP"
    }
  }
}

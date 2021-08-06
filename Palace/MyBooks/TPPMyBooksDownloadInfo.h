// When a download starts, its rights management status will be unknown. It will only become known
// after the response from the server has been received and we've gotten back a MIME type.
typedef NS_ENUM(NSInteger, TPPMyBooksDownloadRightsManagement) {
  TPPMyBooksDownloadRightsManagementUnknown,
  TPPMyBooksDownloadRightsManagementNone,
  TPPMyBooksDownloadRightsManagementAdobe,
  TPPMyBooksDownloadRightsManagementSimplifiedBearerTokenJSON,
  TPPMyBooksDownloadRightsManagementOverdriveManifestJSON,
  TPPMyBooksDownloadRightsManagementLCP
};

@interface TPPMyBooksDownloadInfo : NSObject

@property (nonatomic, readonly) CGFloat downloadProgress;
@property (nonatomic, readonly) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic, readonly) TPPMyBooksDownloadRightsManagement rightsManagement;

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

- (instancetype)initWithDownloadProgress:(CGFloat)downloadProgress
                            downloadTask:(NSURLSessionDownloadTask *)downloadTask
                        rightsManagement:(TPPMyBooksDownloadRightsManagement)rightsManagement;

- (instancetype)withDownloadProgress:(CGFloat)downloadProgress;

- (instancetype)withRightsManagement:(TPPMyBooksDownloadRightsManagement)rightsManagement;

- (NSString *)rightsManagementString;

@end

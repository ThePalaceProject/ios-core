#import "TPPMyBooksDownloadInfo.h"

@interface TPPMyBooksDownloadInfo ()

@property (nonatomic) CGFloat downloadProgress;
@property (nonatomic) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic) TPPMyBooksDownloadRightsManagement rightsManagement;
@property (nonatomic) TPPMyBooksSimplifiedBearerToken *bearerToken;

@end

@implementation TPPMyBooksDownloadInfo

- (instancetype)initWithDownloadProgress:(CGFloat const)downloadProgress
                            downloadTask:(NSURLSessionDownloadTask *const)downloadTask
                        rightsManagement:(TPPMyBooksDownloadRightsManagement const)rightsManagement {

  return [[[self class] alloc]
          initWithDownloadProgress:downloadProgress
          downloadTask:downloadTask
          rightsManagement:rightsManagement
          bearerToken:self.bearerToken];
}

- (instancetype)initWithDownloadProgress:(CGFloat const)downloadProgress
                            downloadTask:(NSURLSessionDownloadTask *const)downloadTask
                        rightsManagement:(TPPMyBooksDownloadRightsManagement const)rightsManagement
                             bearerToken:(TPPMyBooksSimplifiedBearerToken *)bearerToken
{
  self = [super init];
  if(!self) return nil;
  
  self.downloadProgress = downloadProgress;
  
  if(!downloadTask) @throw NSInvalidArgumentException;
  self.downloadTask = downloadTask;

  self.rightsManagement = rightsManagement;
  self.bearerToken = bearerToken;
  
  return self;
}

- (instancetype)withDownloadProgress:(CGFloat const)downloadProgress
{
  return [[[self class] alloc]
          initWithDownloadProgress:downloadProgress
          downloadTask:self.downloadTask
          rightsManagement:self.rightsManagement];
}

- (instancetype)withRightsManagement:(TPPMyBooksDownloadRightsManagement const)rightsManagement
{
  return [[[self class] alloc]
          initWithDownloadProgress:self.downloadProgress
          downloadTask:self.downloadTask
          rightsManagement:rightsManagement];
}

- (NSString *)rightsManagementString
{
  switch (self.rightsManagement) {
    case TPPMyBooksDownloadRightsManagementUnknown:
      return @"Unknown";
    case TPPMyBooksDownloadRightsManagementNone:
      return @"None";
    case TPPMyBooksDownloadRightsManagementAdobe:
      return @"Adobe";
    case TPPMyBooksDownloadRightsManagementSimplifiedBearerTokenJSON:
      return @"SimplifiedBearerTokenJSON";
    case TPPMyBooksDownloadRightsManagementOverdriveManifestJSON:
      return @"OverdriveManifestJSON";
    default:
      return [NSString stringWithFormat:@"Unexpected value: %ld",
              (long)self.rightsManagement];
  }
}

@end

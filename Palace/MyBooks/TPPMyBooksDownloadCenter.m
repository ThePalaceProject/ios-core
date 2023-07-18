@import NYPLAudiobookToolkit;
#if FEATURE_OVERDRIVE
@import OverdriveProcessor;
#endif

#import "NSString+TPPStringAdditions.h"
#import "TPPAccountSignInViewController.h"
#import "TPPOPDS.h"
#import "TPPJSON.h"
#import "TPPMyBooksDownloadCenter.h"
#import "TPPMyBooksDownloadInfo.h"
#import "TPPMyBooksSimplifiedBearerToken.h"
#import "Palace-Swift.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
@interface TPPMyBooksDownloadCenter () <NYPLADEPTDelegate>
@end
#endif

@interface TPPMyBooksDownloadCenter ()
  <NSURLSessionDownloadDelegate, NSURLSessionTaskDelegate>

@property (nonatomic) NSString *bookIdentifierOfBookToRemove;
@property (nonatomic) NSMutableDictionary *bookIdentifierToDownloadInfo;
@property (nonatomic) NSMutableDictionary *bookIdentifierToDownloadProgress;
@property (nonatomic) NSMutableDictionary *bookIdentifierToDownloadTask;
@property (nonatomic) BOOL broadcastScheduled;
@property (nonatomic) NSURLSession *session;
@property (nonatomic) NSMutableDictionary *taskIdentifierToBook;
@property (nonatomic) TPPReauthenticator *reauthenticator;

/// Maps a task identifier to a non-negative redirect attempt count. This
/// tracks the number of redirect attempts for a particular download task.
/// If a task identifier is not present in the dictionary, the redirect
/// attempt count for the associated task should be considered 0.
///
/// Tracking this explicitly is required because we override
/// @c URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler
/// in order to handle redirects when performing bearer token authentication.
@property (nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *taskIdentifierToRedirectAttempts;

@end

@implementation TPPMyBooksDownloadCenter

+ (TPPMyBooksDownloadCenter *)sharedDownloadCenter
{
  static dispatch_once_t predicate;
  static TPPMyBooksDownloadCenter *sharedDownloadCenter = nil;
  
  dispatch_once(&predicate, ^{
    sharedDownloadCenter = [[self alloc] init];
    if(!sharedDownloadCenter) {
      TPPLOG(@"Failed to create shared download center.");
    }
  });
  
  return sharedDownloadCenter;
}

#pragma mark NSObject

- (instancetype)init
{
  self = [super init];
  if(!self) return nil;
  
#if defined(FEATURE_DRM_CONNECTOR)
  // If Adobe certificate is expired, but we still are trying to download an Adobe DRM-protected book,
  // the app will crash
  if (!AdobeCertificate.defaultCertificate.hasExpired) {
    [NYPLADEPT sharedInstance].delegate = self;
  }
#endif
  
  NSURLSessionConfiguration *const configuration =
    [NSURLSessionConfiguration ephemeralSessionConfiguration];
  
  self.bookIdentifierToDownloadInfo = [NSMutableDictionary dictionary];
  self.bookIdentifierToDownloadProgress = [NSMutableDictionary dictionary];
  self.bookIdentifierToDownloadTask = [NSMutableDictionary dictionary];
  
  self.session = [NSURLSession
                  sessionWithConfiguration:configuration
                  delegate:self
                  delegateQueue:[NSOperationQueue mainQueue]];
  
  self.taskIdentifierToBook = [NSMutableDictionary dictionary];
  self.taskIdentifierToRedirectAttempts = [NSMutableDictionary dictionary];
  self.reauthenticator = [[TPPReauthenticator alloc] init];
  
  return self;
}

#pragma mark NSURLSessionDownloadDelegate

// All of these delegate methods can be called (in very rare circumstances) after the shared
// download center has been reset. As such, they must be careful to bail out immediately if that is
// the case.

- (void)URLSession:(__attribute__((unused)) NSURLSession *)session
      downloadTask:(__attribute__((unused)) NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(__attribute__((unused)) int64_t)fileOffset
expectedTotalBytes:(__attribute__((unused)) int64_t)expectedTotalBytes
{
  TPPLOG(@"Ignoring unexpected resumption.");
}

- (void)URLSession:(__attribute__((unused)) NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *const)downloadTask
      didWriteData:(int64_t const)bytesWritten
 totalBytesWritten:(int64_t const)totalBytesWritten
totalBytesExpectedToWrite:(int64_t const)totalBytesExpectedToWrite
{
  NSNumber *const key = @(downloadTask.taskIdentifier);
  TPPBook *const book = self.taskIdentifierToBook[key];
  
  if(!book) {
    // A reset must have occurred.
    return;
  }
  
  // We update the rights management status based on the MIME type given to us by the server. We do
  // this only once at the point when we first start receiving data.
  if(bytesWritten == totalBytesWritten) {
    if([downloadTask.response.MIMEType isEqualToString:ContentTypeAdobeAdept]) {
      self.bookIdentifierToDownloadInfo[book.identifier] =
      [[self downloadInfoForBookIdentifier:book.identifier]
       withRightsManagement:TPPMyBooksDownloadRightsManagementAdobe];
    } else if([downloadTask.response.MIMEType isEqualToString:ContentTypeReadiumLCP]) {
        self.bookIdentifierToDownloadInfo[book.identifier] =
        [[self downloadInfoForBookIdentifier:book.identifier]
         withRightsManagement:TPPMyBooksDownloadRightsManagementLCP];
    } else if([downloadTask.response.MIMEType isEqualToString:ContentTypeEpubZip]) {
      self.bookIdentifierToDownloadInfo[book.identifier] =
      [[self downloadInfoForBookIdentifier:book.identifier]
       withRightsManagement:TPPMyBooksDownloadRightsManagementNone];
    } else if ([downloadTask.response.MIMEType
                isEqualToString:ContentTypeBearerToken]) {
      self.bookIdentifierToDownloadInfo[book.identifier] =
        [[self downloadInfoForBookIdentifier:book.identifier]
         withRightsManagement:TPPMyBooksDownloadRightsManagementSimplifiedBearerTokenJSON];
#if FEATURE_OVERDRIVE
    } else if ([downloadTask.response.MIMEType
                   isEqualToString:@"application/json"]) {
         self.bookIdentifierToDownloadInfo[book.identifier] =
           [[self downloadInfoForBookIdentifier:book.identifier]
            withRightsManagement:TPPMyBooksDownloadRightsManagementOverdriveManifestJSON];
#endif
    } else if ([TPPOPDSAcquisitionPath.supportedTypes containsObject:downloadTask.response.MIMEType]) {
      // if response type represents supported type of book, proceed
      TPPLOG_F(@"Presuming no DRM for unrecognized MIME type \"%@\".", downloadTask.response.MIMEType);
      TPPMyBooksDownloadInfo *info =
      [[self downloadInfoForBookIdentifier:book.identifier]
       withRightsManagement:TPPMyBooksDownloadRightsManagementNone];
      if (info) {
        self.bookIdentifierToDownloadInfo[book.identifier] = info;
      }
    } else {
      TPPLOG(@"Authentication might be needed after all");
      [downloadTask cancel];
      [[TPPBookRegistry shared] setState:TPPBookStateDownloadFailed for:book.identifier];
      [self broadcastUpdate];
      return;
    }
  }
  
  // If the book is protected by Adobe DRM or a Simplified bearer token flow/Overdrive manifest JSON, the download will be very tiny and a later
  // fulfillment step will be required to get the actual content. As such, we do not report progress.
  TPPMyBooksDownloadRightsManagement rightManagement = [self downloadInfoForBookIdentifier:book.identifier].rightsManagement;
  if((rightManagement != TPPMyBooksDownloadRightsManagementAdobe)
     && (rightManagement != TPPMyBooksDownloadRightsManagementSimplifiedBearerTokenJSON)
     && (rightManagement != TPPMyBooksDownloadRightsManagementOverdriveManifestJSON))
  {
    if(totalBytesExpectedToWrite > 0) {
      self.bookIdentifierToDownloadInfo[book.identifier] =
        [[self downloadInfoForBookIdentifier:book.identifier]
         withDownloadProgress:(totalBytesWritten / (double) totalBytesExpectedToWrite)];
      
      [self broadcastUpdate];
    }
  }
}

- (void)URLSession:(__attribute__((unused)) NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *const)downloadTask
didFinishDownloadingToURL:(NSURL *const)tmpSavedFileURL
{
  TPPBook *const book = self.taskIdentifierToBook[@(downloadTask.taskIdentifier)];
  
  if(!book) {
    // A reset must have occurred.
    return;
  }

  [self.taskIdentifierToRedirectAttempts removeObjectForKey:@(downloadTask.taskIdentifier)];
  
  BOOL failureRequiringAlert = NO;
  NSError *failureError = downloadTask.error;
  TPPProblemDocument *problemDoc = nil;
  TPPMyBooksDownloadRightsManagement rights = [self downloadInfoForBookIdentifier:book.identifier].rightsManagement;

  if ([downloadTask.response isProblemDocument]) {
    NSError *problemDocumentParseError = nil;
    NSData *problemDocData = [NSData dataWithContentsOfURL:tmpSavedFileURL];
    problemDoc = [TPPProblemDocument fromData:problemDocData
                                         error:&problemDocumentParseError];
    if (problemDocumentParseError) {
      [TPPErrorLogger
       logProblemDocumentParseError:problemDocumentParseError
       problemDocumentData:problemDocData
       url:tmpSavedFileURL
       summary:[NSString stringWithFormat:@"Error parsing problem doc downloading %@ book", book.distributor]
       metadata:@{ @"book": [book loggableShortString] }];
    }

    [[NSFileManager defaultManager] removeItemAtURL:tmpSavedFileURL error:NULL];
    failureRequiringAlert = YES;
  }

  if (![book canCompleteDownloadWithContentType:downloadTask.response.MIMEType]) {
    [[NSFileManager defaultManager] removeItemAtURL:tmpSavedFileURL error:NULL];
    failureRequiringAlert = YES;
  }

  if (failureRequiringAlert) {
    [self logBookDownloadFailure:book
                          reason:@"Download Error"
                    downloadTask:downloadTask
                        metadata:@{@"problemDocument":
                                     problemDoc.dictionaryValue ?: @"N/A"}];
  } else {
    [[TPPProblemDocumentCacheManager sharedInstance] clearCachedDocForBookIdentifier:book.identifier];

    switch(rights) {
      case TPPMyBooksDownloadRightsManagementUnknown:
        [self logBookDownloadFailure:book
                              reason:@"Unknown rights management"
                        downloadTask:downloadTask
                            metadata:nil];
        failureRequiringAlert = YES;
        break;
      case TPPMyBooksDownloadRightsManagementAdobe: {
#if defined(FEATURE_DRM_CONNECTOR)
        NSData *ACSMData = [NSData dataWithContentsOfURL:tmpSavedFileURL];
        NSString *PDFString = @">application/pdf</dc:format>";
        if([[[NSString alloc] initWithData:ACSMData encoding:NSUTF8StringEncoding] containsString:PDFString]) {
          NSString *msg = [NSString
                           stringWithFormat:NSLocalizedString(@"%@ is an Adobe PDF, which is not supported.", nil),
                           book.title];
          failureError = [NSError errorWithDomain:TPPErrorLogger.clientDomain
                                             code:TPPErrorCodeIgnore
                                         userInfo:@{ NSLocalizedDescriptionKey: msg }];
          [self logBookDownloadFailure:book
                                reason:@"Received PDF for AdobeDRM rights"
                          downloadTask:downloadTask
                              metadata:nil];
          failureRequiringAlert = YES;
        } else {
          TPPLOG_F(@"Download finished. Fulfilling with userID: %@",[[TPPUserAccount sharedAccount] userID]);
          [[NYPLADEPT sharedInstance]
           fulfillWithACSMData:ACSMData
           tag:book.identifier
           userID:[[TPPUserAccount sharedAccount] userID]
           deviceID:[[TPPUserAccount sharedAccount] deviceID]];
        }
#endif
        break;
      }
      case TPPMyBooksDownloadRightsManagementLCP: {
        [self fulfillLCPLicense:tmpSavedFileURL forBook:book downloadTask:downloadTask];
        break;
      }
      case TPPMyBooksDownloadRightsManagementSimplifiedBearerTokenJSON: {
        NSData *const data = [NSData dataWithContentsOfURL:tmpSavedFileURL];
        if (!data) {
          [self logBookDownloadFailure:book
                                reason:@"No Simplified Bearer Token data available on disk"
                          downloadTask:downloadTask
                              metadata:nil];
          [self failDownloadWithAlertForBook:book];
          break;
        }

        NSDictionary *const dictionary = TPPJSONObjectFromData(data);
        if (![dictionary isKindOfClass:[NSDictionary class]]) {
          [self logBookDownloadFailure:book
                                reason:@"Unable to deserialize Simplified Bearer Token data"
                          downloadTask:downloadTask
                              metadata:nil];
          [self failDownloadWithAlertForBook:book];
          break;
        }

        TPPMyBooksSimplifiedBearerToken *const simplifiedBearerToken =
          [TPPMyBooksSimplifiedBearerToken simplifiedBearerTokenWithDictionary:dictionary];

        if (!simplifiedBearerToken) {
          [self logBookDownloadFailure:book
                                reason:@"No Simplified Bearer Token in deserialized data"
                          downloadTask:downloadTask
                              metadata:nil];
          [self failDownloadWithAlertForBook:book];
          break;
        }

        // execute bearer token request
        NSMutableURLRequest *const mutableRequest = [NSMutableURLRequest requestWithURL:simplifiedBearerToken.location];
        [mutableRequest setValue:[NSString stringWithFormat:@"Bearer %@", simplifiedBearerToken.accessToken]
              forHTTPHeaderField:@"Authorization"];
        NSURLSessionDownloadTask *const task = [self.session downloadTaskWithRequest:mutableRequest];
        self.bookIdentifierToDownloadInfo[book.identifier] =
          [[TPPMyBooksDownloadInfo alloc]
           initWithDownloadProgress:0.0
           downloadTask:task
           rightsManagement:TPPMyBooksDownloadRightsManagementNone
           bearerToken:simplifiedBearerToken];
        
        book.bearerToken = simplifiedBearerToken.accessToken;
        self.taskIdentifierToBook[@(task.taskIdentifier)] = book;
        [task resume];
        break;
      }
      case TPPMyBooksDownloadRightsManagementOverdriveManifestJSON: {
        failureRequiringAlert = ![self replaceBook:book
                                     withFileAtURL:tmpSavedFileURL
                                   forDownloadTask:downloadTask];
        break;
      }
      case TPPMyBooksDownloadRightsManagementNone: {
        failureRequiringAlert = ![self moveFileAtURL:tmpSavedFileURL
                                toDestinationForBook:book
                                     forDownloadTask:downloadTask];
        break;
      }
    }
  }
  
  if (failureRequiringAlert) {
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL hasCredentials = [TPPUserAccount.sharedAccount hasCredentials];
      BOOL loginRequired = TPPUserAccount.sharedAccount.authDefinition.needsAuth;
      if ([downloadTask.response indicatesAuthenticationNeedsRefresh:problemDoc]
          || (!hasCredentials && loginRequired)) {

        // re-auth so that when we "Try again" we won't fail for the same reason
        [self.reauthenticator authenticateIfNeeded:TPPUserAccount.sharedAccount
                          usingExistingCredentials:hasCredentials
                          authenticationCompletion:nil];
      }

      [self alertForProblemDocument:problemDoc error:failureError book:book];
    });
    
    [[TPPBookRegistry shared]
     setState:TPPBookStateDownloadFailed
     for:book.identifier];
  }

  [self broadcastUpdate];
}

// this doesn't log to crashlytics because it assumes that the caller
// is responsible for that.
- (void)alertForProblemDocument:(TPPProblemDocument *)problemDoc
                          error:(NSError *)error
                           book:(TPPBook *)book
{
  NSString *msg = [NSString stringWithFormat:
                   NSLocalizedString(@"The download for %@ could not be completed.", nil),
                   book.title];
  UIAlertController *alert = [TPPAlertUtils alertWithTitle:@"DownloadFailed"
                                                    message:msg];
  if (problemDoc) {
    [[TPPProblemDocumentCacheManager sharedInstance]
     cacheProblemDocument:problemDoc
     key:book.identifier];
    [TPPAlertUtils setProblemDocumentWithController:alert
                                            document:problemDoc
                                              append:YES];
    if ([problemDoc.type isEqualToString:TPPProblemDocument.TypeNoActiveLoan]) {
      [[TPPBookRegistry shared] removeBookForIdentifier:book.identifier];
    }
  } else if (error && !error.localizedDescriptionWithRecovery.isEmptyNoWhitespace) {
    alert.message = [NSString stringWithFormat:@"%@\n\nError: %@",
                     msg, error.localizedDescriptionWithRecovery];
  }

  [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
}

#pragma mark NSURLSessionTaskDelegate

// As with the NSURLSessionDownloadDelegate methods, we need to be mindful of resets for the task
// delegate methods too.

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
  NSString *authenticationMethod = challenge.protectionSpace.authenticationMethod;
  
  if ([authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]) {
    TPPBasicAuth *handler = [[TPPBasicAuth alloc] initWithCredentialsProvider:TPPUserAccount.sharedAccount];
    [handler handleChallenge:challenge completion:completionHandler];
  } else {
    completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
  }
}

// This is implemented in order to be able to handle redirects when using
// bearer token authentication.
- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *const)task
willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *const)request
 completionHandler:(void (^ const)(NSURLRequest *_Nullable))completionHandler
{
  NSUInteger const maxRedirectAttempts = 10;

  NSNumber *const redirectAttemptsNumber = self.taskIdentifierToRedirectAttempts[@(task.taskIdentifier)];
  NSUInteger const redirectAttempts = redirectAttemptsNumber ? redirectAttemptsNumber.unsignedIntegerValue : 0;

  if (redirectAttempts >= maxRedirectAttempts) {
    completionHandler(nil);
    return;
  }

  self.taskIdentifierToRedirectAttempts[@(task.taskIdentifier)] = @(redirectAttempts + 1);

  NSString *const authorizationKey = @"Authorization";

  // Since any "Authorization" header will be dropped on redirection for security
  // reasons, we need to again manually set the header for the redirected request
  // if we originally manually set the header to a bearer token. There's no way
  // to use NSURLSession's standard challenge handling approach for bearer tokens,
  // sadly.
  if ([task.originalRequest.allHTTPHeaderFields[authorizationKey] hasPrefix:@"Bearer"]) {
    // Do not pass on the bearer token to other domains.
    if (![task.originalRequest.URL.host isEqual:request.URL.host]) {
      completionHandler(request);
      return;
    }

    // Prevent redirection from HTTPS to a non-HTTPS URL.
    if ([task.originalRequest.URL.scheme isEqualToString:@"https"]
        && ![request.URL.scheme isEqualToString:@"https"]) {
      completionHandler(nil);
      return;
    }

    // Add the originally used bearer token to a new request.
    NSMutableDictionary *const mutableAllHTTPHeaderFields =
      [NSMutableDictionary dictionaryWithDictionary:request.allHTTPHeaderFields];
    mutableAllHTTPHeaderFields[authorizationKey] = task.originalRequest.allHTTPHeaderFields[authorizationKey];
    NSMutableURLRequest *const mutableRequest = [NSMutableURLRequest requestWithURL:request.URL];
    mutableRequest.allHTTPHeaderFields = mutableAllHTTPHeaderFields;

    // Redirect with the bearer token.
    completionHandler(mutableRequest);
  } else {
    completionHandler(request);
  }
}

- (void)URLSession:(__attribute__((unused)) NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
  TPPBook *const book = self.taskIdentifierToBook[@(task.taskIdentifier)];
  
  if(!book) {
    // A reset must have occurred.
    return;
  }

  [self.taskIdentifierToRedirectAttempts removeObjectForKey:@(task.taskIdentifier)];

  // FIXME: This is commented out because we can't remove this stuff if a book will need to be
  // fulfilled. Perhaps this logic should just be put a different place.
  /*
  [self.bookIdentifierToDownloadInfo removeObjectForKey:book.identifier];
  
  // Even though |URLSession:downloadTask|didFinishDownloadingToURL:| needs this, it's safe to
  // remove it here because the aforementioned method will be called first.
  [self.taskIdentifierToBook removeObjectForKey:
      @(task.taskIdentifier)];
  */
  
  if(error && error.code != NSURLErrorCancelled) {
    // TODO: Filter out codes in TPPErrorLogger
    [self logBookDownloadFailure:book
                          reason:@"networking error"
                    downloadTask:task
                        metadata:@{
                          @"urlSessionError": error
                        }];
    [self failDownloadWithAlertForBook:book];
    return;
  }
}

#pragma mark -

- (void)deleteLocalContentForBookIdentifier:(NSString *const)identifier
{
  [self deleteLocalContentForBookIdentifier:identifier account:[AccountsManager sharedInstance].currentAccountId];
}

- (void)deleteLocalContentForBookIdentifier:(NSString *const)identifier account:(NSString * const)account
{
  TPPBook *const book = [[TPPBookRegistry shared] bookForIdentifier:identifier];
  if (!book) {
    TPPLOG(@"WARNING: Could not find book to delete local content.");
    return;
  }
  
  NSURL *bookURL = [self fileURLForBookIndentifier:identifier account:account];
  
  switch (book.defaultBookContentType) {
    case TPPBookContentTypeEpub: {
      NSError *error = nil;
      if(![[NSFileManager defaultManager] removeItemAtURL:bookURL error:&error]){
        TPPLOG_F(@"Failed to remove local content for download: %@", error.localizedDescription);
      }
      break;
    }
    case TPPBookContentTypeAudiobook: {
      [self deleteLocalContentForAudiobook:book atURL:bookURL];
      break;
    }
    case TPPBookContentTypePdf: {
      NSError *error = nil;
      if (![[NSFileManager defaultManager] removeItemAtURL:bookURL error:&error]) {
        TPPLOG_F(@"Failed to remove local content for download: %@", error.localizedDescription);
      }
      // Remove any unarchived content
#if LCP
      [LCPPDFs deletePdfContentWithUrl:bookURL error:&error];
#endif
      if (error) {
        TPPLOG_F(@"Failed to remove local unarchived content for download: %@", error.localizedDescription);
      }
      break;
    }
    case TPPBookContentTypeUnsupported:
      break;
  }
}

/// Delete downloaded audiobook content
/// @param book Audiobook
/// @param bookURL Location of the book
- (void)deleteLocalContentForAudiobook:(TPPBook *)book atURL:(NSURL *)bookURL
{
  NSData *const data = [NSData dataWithContentsOfURL:bookURL];

  if (!data) {
    return;
  }

  id const json = TPPJSONObjectFromData(data);
  
  NSMutableDictionary *dict = nil;
  
#if FEATURE_OVERDRIVE
  if ([book.distributor isEqualToString:OverdriveDistributorKey]) {
    dict = [(NSMutableDictionary *)json mutableCopy];
    dict[@"id"] = book.identifier;
  }
#endif
  
#if defined(LCP)
  if ([LCPAudiobooks canOpenBook:book]) {
    LCPAudiobooks *lcpAudiobooks = [[LCPAudiobooks alloc] initFor:bookURL];
    [lcpAudiobooks contentDictionaryWithCompletion:^(NSDictionary * _Nullable dict, NSError * _Nullable error) {
      if (error) {
        // LCPAudiobooks logs this error
        return;
      }
      if (dict) {
        // Delete decrypted content for the book
        NSMutableDictionary *mutableDict = [dict mutableCopy];
        [[AudiobookFactory audiobook:mutableDict] deleteLocalContent];
      }
    }];
    // Delete LCP book file
    if ([[NSFileManager defaultManager] fileExistsAtPath:bookURL.path]) {
      NSError *error = nil;
      [[NSFileManager defaultManager] removeItemAtURL:bookURL error:&error];
      if (error) {
        [TPPErrorLogger logError:error
                          summary:@"Failed to delete LCP audiobook local content"
                         metadata:@{ @"book": [book loggableShortString] }];
      }
    }
  } else {
    // Not an LCP book
    [[AudiobookFactory audiobook:dict ?: json] deleteLocalContent];
  }
#else
  [[AudiobookFactory audiobook:dict ?: json] deleteLocalContent];
#endif
}
  
- (void)returnBookWithIdentifier:(NSString *)identifier
{
  TPPBook *book = [[TPPBookRegistry shared] bookForIdentifier:identifier];
  TPPBookState state = [[TPPBookRegistry shared] stateFor:identifier];
  BOOL downloaded = state == TPPBookStateDownloadSuccessful| state == TPPBookStateUsed;

  // Process Adobe Return
#if defined(FEATURE_DRM_CONNECTOR)
  NSString *fulfillmentId = [[TPPBookRegistry shared] fulfillmentIdForIdentifier:identifier];
  if (fulfillmentId && TPPUserAccount.sharedAccount.authDefinition.needsAuth) {
    TPPLOG_F(@"Return attempt for book. userID: %@",[[TPPUserAccount sharedAccount] userID]);
    [[NYPLADEPT sharedInstance] returnLoan:fulfillmentId
                                    userID:[[TPPUserAccount sharedAccount] userID]
                                  deviceID:[[TPPUserAccount sharedAccount] deviceID]
                                completion:^(BOOL success, __unused NSError *error) {
                                  if(!success) {
                                    TPPLOG(@"Failed to return loan via NYPLAdept.");
                                  }
                                }];
  }
#endif

  if (!book.revokeURL) {
    if (downloaded) {
      [self deleteLocalContentForBookIdentifier:identifier];
    }
    [[TPPBookRegistry shared] removeBookForIdentifier:identifier];
  } else {
    [[TPPBookRegistry shared] setProcessing:YES for:book.identifier];
    [TPPOPDSFeed withURL:book.revokeURL shouldResetCache:NO completionHandler:^(TPPOPDSFeed *feed, NSDictionary *error) {

      [[TPPBookRegistry shared] setProcessing:NO for:book.identifier];
      
      if(feed && feed.entries.count == 1)  {
        TPPOPDSEntry *const entry = feed.entries[0];
        if(downloaded) {
          [self deleteLocalContentForBookIdentifier:identifier];
        }
        TPPBook *returnedBook = [[TPPBook alloc] initWithEntry:entry];
        if(returnedBook) {
          [[TPPBookRegistry shared] updateAndRemoveBook:returnedBook];
        } else {
          TPPLOG(@"Failed to create book from entry. Book not removed from registry.");
        }
      } else {
        if ([error[@"type"] isEqualToString:TPPProblemDocument.TypeNoActiveLoan]) {
          if(downloaded) {
            [self deleteLocalContentForBookIdentifier:identifier];
          }
          [[TPPBookRegistry shared] removeBookForIdentifier:identifier];
        } else if ([error[@"type"] isEqualToString:TPPProblemDocument.TypeInvalidCredentials]) {
          TPPLOG(@"Invalid credentials problem when returning a book, present sign in VC");
          __weak __auto_type wSelf = self;
          [self.reauthenticator authenticateIfNeeded:TPPUserAccount.sharedAccount
                            usingExistingCredentials:NO
                            authenticationCompletion:^{
            [wSelf returnBookWithIdentifier:identifier];
          }];
        } else {
          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            NSString *formattedMessage = [NSString stringWithFormat:NSLocalizedString(@"The return of %@ could not be completed.", nil), book.title];
            UIAlertController *alert = [TPPAlertUtils
                                        alertWithTitle:@"ReturnFailed"
                                        message:formattedMessage];
            if (error) {
              [TPPAlertUtils setProblemDocumentWithController:alert document:[TPPProblemDocument fromDictionary:error] append:YES];
            }
            [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
          }];
        }
      }
    }];
  }
}

- (TPPMyBooksDownloadInfo *)downloadInfoForBookIdentifier:(NSString *const)bookIdentifier
{
  return self.bookIdentifierToDownloadInfo[bookIdentifier];
}

- (NSURL *)contentDirectoryURL
{
  return [self contentDirectoryURL:[AccountsManager sharedInstance].currentAccountId];
}

- (NSURL *)contentDirectoryURL:(NSString *)account
{
  NSURL *directoryURL = [[TPPBookContentMetadataFilesHelper directoryFor:account] URLByAppendingPathComponent:@"content"];
  
  if (directoryURL != nil) {
    NSError *error = nil;
    if(![[NSFileManager defaultManager]
         createDirectoryAtURL:directoryURL
         withIntermediateDirectories:YES
         attributes:nil
         error:&error]) {
      TPPLOG(@"Failed to create directory.");
      return nil;
    }
  } else {
    TPPLOG(@"[contentDirectoryURL] nil directory.");
  }
  return directoryURL;
}

/// Path extension depending on book type
/// @param book `TPPBook` book
- (NSString *)pathExtensionForBook:(TPPBook *)book
{
#if defined(LCP)
  if (book) {
    if ([LCPAudiobooks canOpenBook:book]) {
      return @"lcpa";
    }
    
    if ([LCPPDFs canOpenBook:book]) {
      return @"zip";
    }
  }
#endif

  // FIXME: The extension is always "epub" even when the URL refers to content of a different
  // type (e.g. an audiobook). While there's no reason this must change, it's certainly likely
  // to cause confusion for anyone looking at the filesystem.
  return @"epub";
}

- (NSURL *)fileURLForBookIndentifier:(NSString *const)identifier
{
  return [self fileURLForBookIndentifier:identifier account:[AccountsManager sharedInstance].currentAccountId];
}
  
- (NSURL *)fileURLForBookIndentifier:(NSString *const)identifier account:(NSString * const)account
{
  if(!identifier) return nil;
  TPPBook *book = [[TPPBookRegistry shared] bookForIdentifier:identifier];
  NSString *pathExtension = [self pathExtensionForBook:book];
  return [[[self contentDirectoryURL:account] URLByAppendingPathComponent:[identifier SHA256]]
          URLByAppendingPathExtension:pathExtension];
}

- (void)logBookDownloadFailure:(TPPBook *)book
                        reason:(NSString *)reason
                  downloadTask:(NSURLSessionTask *)downloadTask
                      metadata:(NSDictionary<NSString*, id> *)metadata
{
  NSString *rights = [[self downloadInfoForBookIdentifier:book.identifier]
                      rightsManagementString];
  NSString *bookType = [TPPBookContentTypeConverter stringValueOf:
                        [book defaultBookContentType]];
  NSString *context = [NSString stringWithFormat:@"%@ %@ download fail: %@",
                       book.distributor, bookType, reason];

  NSMutableDictionary<NSString*, id> *dict = [[NSMutableDictionary alloc] initWithDictionary:metadata];
  dict[@"book"] = book.loggableDictionary;
  dict[@"rightsManagement"] = rights;
  dict[@"taskOriginalRequest"] = downloadTask.originalRequest.loggableString;
  dict[@"taskCurrentRequest"] = downloadTask.currentRequest.loggableString;
  dict[@"response"] = downloadTask.response ?: @"N/A";
  dict[@"downloadError"] = downloadTask.error ?: @"N/A";

  [TPPErrorLogger logErrorWithCode:TPPErrorCodeDownloadFail
                            summary:context
                           metadata:dict];
}

/// Notifies the book registry AND the user that a book failed to download.
/// @note This method does NOT log to Crashlytics.
/// @param book The book that failed to download.
- (void)failDownloadWithAlertForBook:(TPPBook *const)book
{
  [self failDownloadWithAlertForBook:book withMessage:nil];
}

/// Notifies the book registry AND the user that a book failed to download.
///
/// @note This method does NOT log to Crashlytics
///
/// @param book The book that failed to download.
/// @param message Custom message to show
- (void)failDownloadWithAlertForBook:(TPPBook *const)book withMessage:(NSString *)message
{
  TPPBookLocation *location = [[TPPBookRegistry shared] locationForIdentifier:book.identifier];
  
  [[TPPBookRegistry shared]
   addBook:book
   location:location
   state:TPPBookStateDownloadFailed
   fulfillmentId:nil
   readiumBookmarks:nil
   genericBookmarks:nil];
  
  dispatch_async(dispatch_get_main_queue(), ^{
    // TODO: Rephrase the default "No error message" message
    NSString *errorMessage = message != nil ? message : @"No error message";
    NSString *formattedMessage = [NSString stringWithFormat:NSLocalizedString(@"The download for %@ could not be completed.", nil), book.title];
    NSString *finalMessage = [NSString stringWithFormat:@"%@\n%@", formattedMessage, errorMessage];
    UIAlertController *alert = [TPPAlertUtils alertWithTitle:@"DownloadFailed" message:finalMessage];
    [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
  });

  [self broadcastUpdate];
}

- (void)startBorrowForBook:(TPPBook *)book
           attemptDownload:(BOOL)shouldAttemptDownload
          borrowCompletion:(void (^)(void))borrowCompletion
{
  [[TPPBookRegistry shared] setProcessing:YES for:book.identifier];
  [TPPOPDSFeed withURL:book.defaultAcquisitionIfBorrow.hrefURL shouldResetCache:YES completionHandler:^(TPPOPDSFeed *feed, NSDictionary *error) {
    [[TPPBookRegistry shared] setProcessing:NO for:book.identifier];

    if (error || !feed || feed.entries.count < 1) {
      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (borrowCompletion) {
          borrowCompletion();
          return;
        }

        // create an alert to display for error, feed, or feed count conditions
        NSString *formattedMessage = [NSString stringWithFormat:NSLocalizedString(@"Borrowing %@ could not be completed.", nil), book.title];
        UIAlertController *alert = [TPPAlertUtils alertWithTitle:@"BorrowFailed" message:formattedMessage];

        // set different message for special type of error or just add document message for generic error
        if (error) {
          if ([error[@"type"] isEqualToString:TPPProblemDocument.TypeLoanAlreadyExists]) {
            formattedMessage = [NSString stringWithFormat:NSLocalizedString(@"You have already checked out this loan. You may need to refresh your My Books list to download the title.",
                                                                            comment: @"When book is already checked out on patron's other device(s), they will get this message"), book.title];
            alert = [TPPAlertUtils alertWithTitle:@"BorrowFailed" message:formattedMessage];
          } else if ([error[@"type"] isEqualToString:TPPProblemDocument.TypeInvalidCredentials]) {
            TPPLOG(@"Invalid credentials problem when borrowing a book, present sign in VC");
            __weak __auto_type wSelf = self;
            [self.reauthenticator authenticateIfNeeded:TPPUserAccount.sharedAccount
                              usingExistingCredentials:NO
                              authenticationCompletion:^{
              [wSelf startDownloadForBook:book];
            }];
            return;
          } else {
            [TPPAlertUtils setProblemDocumentWithController:alert document:[TPPProblemDocument fromDictionary:error] append:NO];
          }
        }

        // display the alert
        [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
      }];
      return;
    }

    TPPBook *book = [[TPPBook alloc] initWithEntry:feed.entries[0]];

    if(!book) {
      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (borrowCompletion) {
          borrowCompletion();
          return;
        }
        NSString *formattedMessage = [NSString stringWithFormat:NSLocalizedString(@"Borrowing %@ could not be completed.", nil), book.title];
        UIAlertController *alert = [TPPAlertUtils alertWithTitle:@"BorrowFailed" message:formattedMessage];
        [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
      }];
      return;
    }

    TPPBookLocation *location = [[TPPBookRegistry shared] locationForIdentifier:book.identifier];
    
    [[TPPBookRegistry shared]
     addBook:book
     location:location
     state:TPPBookStateDownloadNeeded
     fulfillmentId:nil
     readiumBookmarks:nil
     genericBookmarks:nil];

    if(borrowCompletion) {
      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        borrowCompletion();
        return;
      }];
    }

    if (shouldAttemptDownload) {
      [book.defaultAcquisition.availability
       matchUnavailable:nil
       limited:^(__unused TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited) {
         [[TPPMyBooksDownloadCenter sharedDownloadCenter] startDownloadForBook:book];
       }
       unlimited:^(__unused TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited) {
         [[TPPMyBooksDownloadCenter sharedDownloadCenter] startDownloadForBook:book];
       }
       reserved:nil
       ready:^(__unused TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready) {
         [[TPPMyBooksDownloadCenter sharedDownloadCenter] startDownloadForBook:book];
       }];
    }
  }];
}

- (void)startDownloadForBook:(TPPBook *const)book
{
  [self startDownloadForBook:book withRequest:nil];
}

- (void)startDownloadForBook:(TPPBook *const)book withRequest:(NSURLRequest *)initedRequest
{
  TPPBookState state = [[TPPBookRegistry shared]
                         stateFor:book.identifier];

  TPPBookLocation *location = [[TPPBookRegistry shared] locationForIdentifier:book.identifier];
  
  BOOL loginRequired = TPPUserAccount.sharedAccount.authDefinition.needsAuth;

  switch(state) {
    case TPPBookStateUnregistered:
      if(!book.defaultAcquisitionIfBorrow
         && (book.defaultAcquisitionIfOpenAccess || !loginRequired)) {

        [[TPPBookRegistry shared]
         addBook:book
         location:location
         state:TPPBookStateDownloadNeeded
         fulfillmentId:nil
         readiumBookmarks:nil
         genericBookmarks:nil];
        state = TPPBookStateDownloadNeeded;
      }
      break;
    case TPPBookStateDownloading:
      // Ignore double button presses, et cetera.
      return;
    case TPPBookStateDownloadFailed:
      break;
    case TPPBookStateDownloadNeeded:
      break;
    case TPPBookStateHolding:
      break;
    case TPPBookStateSAMLStarted:
      break;
    case TPPBookStateDownloadSuccessful:
      // fallthrough
    case TPPBookStateUsed:
      // fallthrough
    case TPPBookStateUnsupported:
      TPPLOG(@"Ignoring nonsensical download request.");
      return;
  }
  
  if([TPPUserAccount sharedAccount].hasCredentials || !loginRequired) {
    if(state == TPPBookStateUnregistered || state == TPPBookStateHolding) {
      // Check out the book
      [self startBorrowForBook:book attemptDownload:YES borrowCompletion:nil];
#if FEATURE_OVERDRIVE
    } else if ([book.distributor isEqualToString:OverdriveDistributorKey] && book.defaultBookContentType == TPPBookContentTypeAudiobook) {
      NSURL *URL = book.defaultAcquisition.hrefURL;
      
      
 
  
      [[OverdriveAPIExecutor shared] fulfillBookWithUrlString:URL.absoluteString
                                                     username:[[TPPUserAccount sharedAccount] barcode]
                                                          pin:[[TPPUserAccount sharedAccount] PIN]
                                                        token:[[TPPUserAccount sharedAccount] authToken]
                                                   completion:^(NSDictionary<NSString *,id> * _Nullable responseHeaders, NSError * _Nullable error) {
        if (error) {
          [TPPErrorLogger logError:error
                            summary:@"Overdrive audiobook fulfillment error"
                           metadata:@{
                             @"responseHeaders": responseHeaders ?: @"N/A",
                             @"acquisitionURL": URL ?: @"N/A",
                             @"book": book.loggableDictionary,
                             @"bookRegistryState": [TPPBookStateHelper stringValueFromBookState:state]
                           }];
          [self failDownloadWithAlertForBook:book];
          return;
        }

        NSString *scope = responseHeaders[@"x-overdrive-scope"] ?: responseHeaders[@"X-Overdrive-Scope"];
        NSString *patronAuthorization = responseHeaders[@"x-overdrive-patron-authorization"] ?: responseHeaders[@"X-Overdrive-Patron-Authorization"];
        NSString *requestURLString = responseHeaders[@"location"] ?: responseHeaders[@"Location"];
        
        if (!scope || !patronAuthorization || !requestURLString) {
          [TPPErrorLogger logErrorWithCode:TPPErrorCodeOverdriveFulfillResponseParseFail
                                    summary:@"Overdrive audiobook fulfillment: wrong headers"
                                   metadata:@{
                                     @"responseHeaders": responseHeaders ?: @"N/A",
                                     @"acquisitionURL": URL ?: @"N/A",
                                     @"book": book.loggableDictionary,
                                     @"bookRegistryState": [TPPBookStateHelper stringValueFromBookState:state]
                                   }];
          [self failDownloadWithAlertForBook:book];
          return;
        }
          
        NSURLRequest *request = [[OverdriveAPIExecutor shared] getManifestRequestWithUrlString:requestURLString token:patronAuthorization scope:scope];
        [self addDownloadTaskWithRequest:request book:book];
      }];
#endif
    } else {
      // Actually download the book.
      NSURL *URL = book.defaultAcquisition.hrefURL;

      NSURLRequest *request;
      if (initedRequest) {
        request = initedRequest;
      } else {
        request = [[TPPNetworkExecutor bearerAuthorizedWithRequest:[NSURLRequest requestWithURL:URL]] mutableCopy];
      }

      if(!request.URL) {
        // Originally this code just let the request fail later on, but apparently resuming an
        // NSURLSessionDownloadTask created from a request with a nil URL pathetically results in a
        // segmentation fault.
        TPPLOG(@"Aborting request with invalid URL.");
        [TPPErrorLogger logErrorWithCode:TPPErrorCodeDownloadFail
                                  summary:@"Book download failure: nil download URL"
                                 metadata:@{
                                   @"acquisitionURL": URL ?: @"N/A",
                                   @"book": book.loggableDictionary,
                                   @"bookRegistryState": [TPPBookStateHelper stringValueFromBookState:state]
                                 }];
        [self failDownloadWithAlertForBook:book];
        return;
      }

      if (TPPUserAccount.sharedAccount.cookies && state != TPPBookStateSAMLStarted) {
        [[TPPBookRegistry shared] setState:TPPBookStateSAMLStarted for:book.identifier];

        NSMutableArray *someCookies = TPPUserAccount.sharedAccount.cookies.mutableCopy;
        NSMutableURLRequest *mutableRequest = request.mutableCopy;

        dispatch_async(dispatch_get_main_queue(), ^{
          __weak TPPMyBooksDownloadCenter *weakSelf = self;

          mutableRequest.cachePolicy = NSURLRequestReloadIgnoringCacheData;

          void (^loginCancelHandler)(void) = ^{
            [[TPPBookRegistry shared] setState:TPPBookStateDownloadNeeded for:book.identifier];
            [weakSelf cancelDownloadForBookIdentifier:book.identifier];
          };

          void (^bookFoundHandler)(NSURLRequest * _Nullable, NSArray<NSHTTPCookie *> * _Nonnull) = ^(NSURLRequest * _Nullable request, NSArray<NSHTTPCookie *> * _Nonnull cookies) {
            [TPPUserAccount.sharedAccount setCookies:cookies];
            [weakSelf startDownloadForBook:book withRequest:request];
          };

          void (^problemFoundHandler)(TPPProblemDocument * _Nullable) = ^(__unused TPPProblemDocument * _Nullable problemDocument) {
            [[TPPBookRegistry shared] setState:TPPBookStateDownloadNeeded for:book.identifier];

            __weak __auto_type wSelf = self;
            [self.reauthenticator authenticateIfNeeded:TPPUserAccount.sharedAccount
                              usingExistingCredentials:NO
                              authenticationCompletion:^{
              [wSelf startDownloadForBook:book];
            }];
          };

          TPPCookiesWebViewModel *model = [[TPPCookiesWebViewModel alloc] initWithCookies:someCookies
                                                                                    request:mutableRequest
                                                                     loginCompletionHandler:nil
                                                                         loginCancelHandler:loginCancelHandler
                                                                           bookFoundHandler:bookFoundHandler
                                                                        problemFoundHandler:problemFoundHandler
                                                                        autoPresentIfNeeded:YES]; // <- this will cause a web view to retain a cycle

          TPPCookiesWebViewController *cookiesVC = [[TPPCookiesWebViewController alloc] initWithModel:model];
          [cookiesVC loadViewIfNeeded];
        });
      } else {
        // clear all cookies
        NSHTTPCookieStorage *cookieStorage = self.session.configuration.HTTPCookieStorage;
        for (NSHTTPCookie *each in cookieStorage.cookies) {
          [cookieStorage deleteCookie:each];
        }

        // set new cookies
        for (NSHTTPCookie *cookie in TPPUserAccount.sharedAccount.cookies) {
          [self.session.configuration.HTTPCookieStorage setCookie:cookie];
        }

        [self addDownloadTaskWithRequest:request book:book];
      }
    }
  } else {
#if FEATURE_DRM_CONNECTOR
    if ([AdobeCertificate.defaultCertificate hasExpired] == YES) {
      // ADEPT crashes the app with expired certificate.
      [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:[TPPAlertUtils expiredAdobeDRMAlert] viewController:nil animated:YES completion:nil];
    } else {
      [TPPAccountSignInViewController
       requestCredentialsWithCompletion:^{
         [[TPPMyBooksDownloadCenter sharedDownloadCenter] startDownloadForBook:book];
       }];
    }
#else
    [TPPAccountSignInViewController
     requestCredentialsWithCompletion:^{
       [[TPPMyBooksDownloadCenter sharedDownloadCenter] startDownloadForBook:book];
     }];
#endif
  }
}

- (void)addDownloadTaskWithRequest:(NSURLRequest *)request
                              book:(TPPBook *)book {
  if (book == nil) {
    return;
  }
    
  NSURLSessionDownloadTask *const task = [self.session downloadTaskWithRequest:request];
  
  self.bookIdentifierToDownloadInfo[book.identifier] =
    [[TPPMyBooksDownloadInfo alloc]
     initWithDownloadProgress:0.0
     downloadTask:task
     rightsManagement:TPPMyBooksDownloadRightsManagementUnknown];
  
  self.taskIdentifierToBook[@(task.taskIdentifier)] = book;
  
  [task resume];
  
  TPPBookLocation *location = [[TPPBookRegistry shared] locationForIdentifier:book.identifier];
  
  [[TPPBookRegistry shared]
   addBook:book
   location:location
   state:TPPBookStateDownloading
   fulfillmentId:nil
   readiumBookmarks:nil
   genericBookmarks:nil];
  
  // It is important to issue this immediately because a previous download may have left the
  // progress for the book at greater than 0.0 and we do not want that to be temporarily shown to
  // the user. As such, calling |broadcastUpdate| is not appropriate due to the delay.
  [[NSNotificationCenter defaultCenter]
   postNotificationName:NSNotification.TPPMyBooksDownloadCenterDidChange
   object:self];
}

- (void)cancelDownloadForBookIdentifier:(NSString *)identifier
{
  
  TPPMyBooksDownloadInfo *info = [self downloadInfoForBookIdentifier:identifier];
  
  if (info) {
    #if defined(FEATURE_DRM_CONNECTOR)
      if (info.rightsManagement == TPPMyBooksDownloadRightsManagementAdobe) {
          [[NYPLADEPT sharedInstance] cancelFulfillmentWithTag:identifier];
        return;
      }
    #endif
    
    [info.downloadTask
     cancelByProducingResumeData:^(__attribute__((unused)) NSData *resumeData) {
       [[TPPBookRegistry shared]
        setState:TPPBookStateDownloadNeeded for:identifier];
       
       [self broadcastUpdate];
     }];
  } else {
    // The download was not actually going, so we just need to convert a failed download state.
    TPPBookState const state = [[TPPBookRegistry shared]
                                 stateFor:identifier];
    
    if(state != TPPBookStateDownloadFailed) {
      TPPLOG(@"Ignoring nonsensical cancellation request.");
      return;
    }
    
    [[TPPBookRegistry shared]
     setState:TPPBookStateDownloadNeeded for:identifier];
  }
}

- (void)deleteAudiobooksForAccount:(NSString * const)account
{
  [[TPPBookRegistry shared] withAccount:account perform:^(TPPBookRegistry * registry) {
    NSArray<TPPBook *> const *books = registry.allBooks;
    for (TPPBook *const book in books) {
      if (book.defaultBookContentType == TPPBookContentTypeAudiobook) {
        [[TPPMyBooksDownloadCenter sharedDownloadCenter]
         deleteLocalContentForBookIdentifier:book.identifier
         account:account];
      }
    }
  }];
}

- (void)reset:(NSString *)account
{
  if ([[AccountsManager shared].currentAccountId isEqualToString:account])
  {
    [self reset];
  }
  else
  {
    [self deleteAudiobooksForAccount:account];
    [[NSFileManager defaultManager]
     removeItemAtURL:[self contentDirectoryURL:account]
     error:NULL];
  }
}


- (void)reset
{
  [self deleteAudiobooksForAccount:[AccountsManager sharedInstance].currentAccountId];
  
  for(TPPMyBooksDownloadInfo *const info in [self.bookIdentifierToDownloadInfo allValues]) {
    [info.downloadTask cancelByProducingResumeData:^(__unused NSData *resumeData) {}];
  }
  
  [self.bookIdentifierToDownloadInfo removeAllObjects];
  [self.taskIdentifierToBook removeAllObjects];
  self.bookIdentifierOfBookToRemove = nil;
  
  [[NSFileManager defaultManager]
   removeItemAtURL:[self contentDirectoryURL]
   error:NULL];
  
  [self broadcastUpdate];
}

- (double)downloadProgressForBookIdentifier:(NSString *const)bookIdentifier
{
  return [self downloadInfoForBookIdentifier:bookIdentifier].downloadProgress;
}

- (void)broadcastUpdate
{
  // We avoid issuing redundant notifications to prevent overwhelming UI updates.
  if(self.broadcastScheduled) return;
  
  self.broadcastScheduled = YES;
  
  // This needs to be queued on the main run loop. If we queue it elsewhere, it may end up never
  // firing due to a run loop becoming inactive.
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [self performSelector:@selector(broadcastUpdateNow)
               withObject:nil
               afterDelay:0.2];
  }];
}

- (void)broadcastUpdateNow
{
  self.broadcastScheduled = NO;
  
  [[NSNotificationCenter defaultCenter]
   postNotificationName:NSNotification.TPPMyBooksDownloadCenterDidChange
   object:self];
}

- (BOOL)moveFileAtURL:(NSURL *)sourceLocation
 toDestinationForBook:(TPPBook *)book
      forDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
  NSError *removeError = nil, *moveError = nil;
  NSURL *finalFileURL = [self fileURLForBookIndentifier:book.identifier];

  [[NSFileManager defaultManager]
   removeItemAtURL:finalFileURL
   error:&removeError];

  BOOL success = [[NSFileManager defaultManager]
                  moveItemAtURL:sourceLocation
                  toURL:finalFileURL
                  error:&moveError];

  if (success) {
    [[TPPBookRegistry shared]
     setState:TPPBookStateDownloadSuccessful for:book.identifier];
  } else if (moveError) {
    [self logBookDownloadFailure:book
                          reason:@"Couldn't move book to final disk location"
                    downloadTask:downloadTask
                        metadata:@{
                          @"moveError": moveError,
                          @"removeError": removeError.debugDescription ?: @"N/A",
                          @"sourceLocation": sourceLocation ?: @"N/A",
                          @"finalFileURL": finalFileURL ?: @"N/A",
                        }];
  }

  return success;
}

- (BOOL)replaceBook:(TPPBook *)book
      withFileAtURL:(NSURL *)sourceLocation
    forDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
  NSError *replaceError = nil;
  NSURL *destURL = [self fileURLForBookIndentifier:book.identifier];
  BOOL success = [[NSFileManager defaultManager] replaceItemAtURL:destURL
                                                    withItemAtURL:sourceLocation
                                                   backupItemName:nil
                                                          options:NSFileManagerItemReplacementUsingNewMetadataOnly
                                                 resultingItemURL:nil
                                                            error:&replaceError];
  
  if(success) {
    [[TPPBookRegistry shared] setState:TPPBookStateDownloadSuccessful for:book.identifier];
  } else {
    [self logBookDownloadFailure:book
                          reason:@"Couldn't replace downloaded book"
                    downloadTask:downloadTask
                        metadata:@{
                          @"replaceError": replaceError ?: @"N/A",
                          @"destinationFileURL": destURL ?: @"N/A",
                          @"sourceFileURL": sourceLocation ?: @"N/A",
                        }];
  }

  return success;
}

#if defined(FEATURE_DRM_CONNECTOR)
  
#pragma mark NYPLADEPTDelegate
  
- (void)adept:(__attribute__((unused)) NYPLADEPT *)adept didUpdateProgress:(double)progress tag:(NSString *)tag
{
  self.bookIdentifierToDownloadInfo[tag] =
  [[self downloadInfoForBookIdentifier:tag] withDownloadProgress:progress];

  [self broadcastUpdate];
}

- (void)    adept:(__attribute__((unused)) NYPLADEPT *)adept
didFinishDownload:(BOOL)didFinishDownload
            toURL:(NSURL *)adeptToURL
    fulfillmentID:(NSString *)fulfillmentID
     isReturnable:(BOOL)isReturnable
       rightsData:(NSData *)rightsData
              tag:(NSString *)tag
            error:(NSError *)adeptError
{
  TPPBook *const book = [[TPPBookRegistry shared] bookForIdentifier:tag];
  NSString *rights = [[NSString alloc] initWithData:rightsData encoding:kCFStringEncodingUTF8];
  BOOL didSucceedCopying = NO;

  if(didFinishDownload) {
    [[NSFileManager defaultManager]
     removeItemAtURL:[self fileURLForBookIndentifier:book.identifier]
     error:NULL];

    if (![self fileURLForBookIndentifier:book.identifier]) {
      [TPPErrorLogger logErrorWithCode:TPPErrorCodeAdobeDRMFulfillmentFail
                                summary:@"Adobe DRM error: destination file URL unavailable"
                               metadata:@{
                                 @"adeptError": adeptError ?: @"N/A",
                                 @"fileURLToRemove": adeptToURL ?: @"N/A",
                                 @"book": book.loggableDictionary ?: @"N/A",
                                 @"AdobeFulfilmmentID": fulfillmentID ?: @"N/A",
                                 @"AdobeRights": rights ?: @"N/A",
                                 @"AdobeTag": tag ?: @"N/A"
                               }];
      [self failDownloadWithAlertForBook:book];
      return;
    }
    
    // This needs to be a copy else the Adept connector will explode when it tries to delete the
    // temporary file.
    NSError *copyError = nil;
    NSURL *destURL = [self fileURLForBookIndentifier:book.identifier];
    didSucceedCopying = [[NSFileManager defaultManager]
                         copyItemAtURL:adeptToURL
                         toURL:destURL
                         error:&copyError];
    if(!didSucceedCopying) {
      [TPPErrorLogger logErrorWithCode:TPPErrorCodeAdobeDRMFulfillmentFail
                                summary:@"Adobe DRM error: failure copying file"
                               metadata:@{
                                 @"adeptError": adeptError ?: @"N/A",
                                 @"copyError": copyError ?: @"N/A",
                                 @"fromURL": adeptToURL ?: @"N/A",
                                 @"destURL": destURL ?: @"N/A",
                                 @"book": book.loggableDictionary ?: @"N/A",
                                 @"AdobeFulfilmmentID": fulfillmentID ?: @"N/A",
                                 @"AdobeRights": rights ?: @"N/A",
                                 @"AdobeTag": tag ?: @"N/A"
                               }];
    }
  } else {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeAdobeDRMFulfillmentFail
                              summary:@"Adobe DRM error: did not finish download"
                             metadata:@{
                               @"adeptError": adeptError ?: @"N/A",
                               @"adeptToURL": adeptToURL ?: @"N/A",
                               @"book": book.loggableDictionary ?: @"N/A",
                               @"AdobeFulfilmmentID": fulfillmentID ?: @"N/A",
                               @"AdobeRights": rights ?: @"N/A",
                               @"AdobeTag": tag ?: @"N/A"
                             }];
  }

  if(didFinishDownload == NO || didSucceedCopying == NO) {
    [self failDownloadWithAlertForBook:book];
    return;
  }

  //
  // The rights data are stored in {book_filename}_rights.xml,
  // alongside with the book because Readium+DRM expect this when
  // opening the EPUB 3.
  // See Container::Open(const string& path) in container.cpp.
  //
  if(![rightsData writeToFile:[[[self fileURLForBookIndentifier:book.identifier] path]
                               stringByAppendingString:@"_rights.xml"]
                   atomically:YES]) {
    TPPLOG(@"Failed to store rights data.");
  }
  
  if(isReturnable && fulfillmentID) {
    [[TPPBookRegistry shared]
     setFulfillmentId:fulfillmentID for:book.identifier];
  }

  [[TPPBookRegistry shared]
   setState:TPPBookStateDownloadSuccessful for:book.identifier];

  [self broadcastUpdate];
}
  
- (void)adept:(__attribute__((unused)) NYPLADEPT *)adept didCancelDownloadWithTag:(NSString *)tag
{
  [[TPPBookRegistry shared]
   setState:TPPBookStateDownloadNeeded for:tag];

  [self broadcastUpdate];
}

- (void)didIgnoreFulfillmentWithNoAuthorizationPresent
{
  // NOTE: This is cut and pasted from a previous implementation:
  // "This handles a bug that seems to occur when the user updates,
  // where the barcode and pin are entered but according to ADEPT the device
  // is not authorized. To be used, the account must have a barcode and pin."
  [self.reauthenticator authenticateIfNeeded:[TPPUserAccount sharedAccount]
                    usingExistingCredentials:YES
                    authenticationCompletion:nil];
}

#endif


#pragma mark - LCP

/// Fulfill LCP license
/// @param fileUrl Downloaded LCP license URL
/// @param book `TPPBook` Book
/// @param downloadTask download task
- (void)fulfillLCPLicense:(NSURL *)fileUrl
                  forBook:(TPPBook *)book
             downloadTask:(NSURLSessionDownloadTask *)downloadTask
{
  #if defined(LCP)
  LCPLibraryService *lcpService = [[LCPLibraryService alloc] init];
  // Ensure correct license extension
  NSURL *licenseUrl = [[fileUrl URLByDeletingPathExtension] URLByAppendingPathExtension:lcpService.licenseExtension];
  NSError *replaceError;
  [[NSFileManager defaultManager] replaceItemAtURL:licenseUrl
                                     withItemAtURL:fileUrl
                                    backupItemName:nil
                                           options:NSFileManagerItemReplacementUsingNewMetadataOnly
                                  resultingItemURL:nil
                                             error:&replaceError];
  if (replaceError) {
    [TPPErrorLogger logError:replaceError summary:@"Error renaming LCP license file" metadata:@{
      @"fileUrl": fileUrl ?: @"nil",
      @"licenseUrl": licenseUrl ?: @"nil",
      @"book": [book loggableDictionary] ?: @"nil"
    }];
    [self failDownloadWithAlertForBook:book];
    return;
  }

  // LCP library expects an .lcpl file at licenseUrl
  // localUrl is URL of downloaded file with embedded license
  NSURLSessionDownloadTask *fulfillmentDownloadTask = [lcpService fulfill:licenseUrl progress:^(double progressValue) {
    self.bookIdentifierToDownloadInfo[book.identifier] =
      [[self downloadInfoForBookIdentifier:book.identifier] withDownloadProgress:progressValue];
    [self broadcastUpdate];
  } completion:^(NSURL *localUrl, NSError *error) {
    if (error) {
      NSString *summary = [NSString stringWithFormat:@"%@ LCP license fulfillment error",
                           book.distributor];
      [TPPErrorLogger logError:error
                       summary:summary
                      metadata:@{
        @"book": book.loggableDictionary ?: @"N/A",
        @"licenseURL": licenseUrl  ?: @"N/A",
        @"localURL": localUrl  ?: @"N/A",
      }];
      NSString *errorMessage = [NSString stringWithFormat:@"Fulfilment Error: %@", error.localizedDescription];
      [self failDownloadWithAlertForBook:book withMessage:errorMessage];
      return;
    }
    BOOL success = [self replaceBook:book
                       withFileAtURL:localUrl
                     forDownloadTask:downloadTask];
    if (!success) {
      NSString *errorMessage = [NSString stringWithFormat:@"Error replacing license file with file %@", localUrl];
      [self failDownloadWithAlertForBook:book withMessage:errorMessage];
    } else {
      // Store license ID
      TPPLCPLicense *license = [[TPPLCPLicense alloc] initWithUrl: licenseUrl];
      [[TPPBookRegistry shared] setFulfillmentId:license.identifier for:book.identifier];
      // For pdfs, try to unarchive the file to spped up the access
      if (book.defaultBookContentType == TPPBookContentTypePdf) {
        NSURL *bookURL = [self fileURLForBookIndentifier:book.identifier];
        [[TPPBookRegistry shared] setState:TPPBookStateDownloading for:book.identifier];
        [[[LCPPDFs alloc] initWithUrl:bookURL] extractWithUrl:bookURL completion:^(NSURL *url, NSError *error) {
          [[TPPBookRegistry shared] setState:TPPBookStateDownloadSuccessful for:book.identifier];
        }];
      }
    }
  }];
  // If downlad task is created correctly, reassign download task for current book identifier
  if (fulfillmentDownloadTask) {
    self.bookIdentifierToDownloadInfo[book.identifier] =
      [[TPPMyBooksDownloadInfo alloc]
       initWithDownloadProgress:0.0
       downloadTask:fulfillmentDownloadTask
       rightsManagement:TPPMyBooksDownloadRightsManagementNone];
  }
  #endif
}

@end

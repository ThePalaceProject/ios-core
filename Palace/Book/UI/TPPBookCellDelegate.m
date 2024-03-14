@import MediaPlayer;
#if FEATURE_OVERDRIVE
@import OverdriveProcessor;
#endif
@import PDFKit;

#import "TPPAccountSignInViewController.h"
#import "TPPBookDownloadFailedCell.h"
#import "TPPBookDownloadingCell.h"
#import "TPPBookNormalCell.h"
#import "TPPRootTabBarController.h"

#import "NSURLRequest+NYPLURLRequestAdditions.h"
#import "TPPJSON.h"
#import "TPPReachabilityManager.h"

#import "TPPBookCellDelegate.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#endif

@interface TPPBookCellDelegate () <RefreshDelegate>
{
  @private NSTimeInterval previousPlayheadOffset;
}

@property (nonatomic) NSTimer *timer;
@property (nonatomic) NSDate *lastServerUpdate;
@property (nonatomic) id<AudiobookManager> manager;
@property (nonatomic, weak) UIViewController *audiobookViewController;
@property (strong) NSLock *refreshAudiobookLock;
@property (nonatomic, strong) LoadingViewController *loadingViewController;
@property (nonatomic, strong) AudiobookBookmarkBusinessLogic *audiobookBookmarkBusinessLogic;

@end

@implementation TPPBookCellDelegate

static const int kServerUpdateDelay = 15;

+ (instancetype)sharedDelegate
{
  static dispatch_once_t predicate;
  static TPPBookCellDelegate *sharedDelegate = nil;
  
  dispatch_once(&predicate, ^{
    sharedDelegate = [[self alloc] init];
    if(!sharedDelegate) {
      TPPLOG(@"Failed to create shared delegate.");
    }
  });
  
  return sharedDelegate;
}

- (instancetype)init
{
  self = [super init];
  
  _refreshAudiobookLock = [[NSLock alloc] init];
  _lastServerUpdate = [NSDate date];
  
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark TPPBookButtonsDelegate

- (void)didSelectReturnForBook:(TPPBook *)book completion:(void (^ __nullable)(void))completion
{
  [[MyBooksDownloadCenter shared] returnBookWithIdentifier:book.identifier completion: completion];
}

- (void)didSelectDownloadForBook:(TPPBook *)book
{
  [[MyBooksDownloadCenter shared] startDownloadFor:book withRequest:nil];
}

- (void)didSelectReadForBook:(TPPBook *)book
{ 
#if defined(FEATURE_DRM_CONNECTOR)
  // Try to prevent blank books bug

  TPPUserAccount *user = [TPPUserAccount sharedAccount];
  if ([user hasCredentials]) {
    if ([user hasAuthToken]) {
      [self openBook:book];
    } else
      if ([AdobeCertificate.defaultCertificate hasExpired] == NO
          && ![[NYPLADEPT sharedInstance] isUserAuthorized:[user userID]
                                                withDevice:[user deviceID]]) {
        // NOTE: This was cut and pasted while refactoring preexisting work:
        // "This handles a bug that seems to occur when the user updates,
        // where the barcode and pin are entered but according to ADEPT the device
        // is not authorized. To be used, the account must have a barcode and pin."
        TPPReauthenticator *reauthenticator = [[TPPReauthenticator alloc] init];
        [reauthenticator authenticateIfNeeded:user
                     usingExistingCredentials:YES
                     authenticationCompletion:^{
          dispatch_async(dispatch_get_main_queue(), ^{
            [self openBook:book];   // with successful DRM activation
          });
        }];
      } else {
        [self openBook:book];
      }
  } else {
    [self openBook:book];
  }
#else
  [self openBook:book];
#endif
}

- (void)openBook:(TPPBook *)book
{
  [TPPCirculationAnalytics postEvent:@"open_book" withBook:book];

  switch (book.defaultBookContentType) {
    case TPPBookContentTypeEpub:
      [self openEPUB:book];
      break;
    case TPPBookContentTypePdf:
      [self openPDF:book];
      break;
    case TPPBookContentTypeAudiobook:
      [self openAudiobook:book];
      break;
    default:
      [self presentUnsupportedItemError];
      break;
  }
}

- (void)openEPUB:(TPPBook *)book
{
  [[TPPRootTabBarController sharedController] presentBook:book];
  
  [TPPAnnotations requestServerSyncStatusForAccount:[TPPUserAccount sharedAccount] completion:^(BOOL enableSync) {
    if (enableSync == YES) {
      Account *currentAccount = [[AccountsManager sharedInstance] currentAccount];
      currentAccount.details.syncPermissionGranted = enableSync;
    }
  }];
}

- (void)openPDF:(TPPBook *)book {
#if LCP
  if ([LCPPDFs canOpenBook:book]) {
    NSURL *bookUrl = [[MyBooksDownloadCenter shared] fileUrlFor:book.identifier];
    LCPPDFs *decryptor = [[LCPPDFs alloc] initWithUrl:bookUrl];
    [decryptor extractWithUrl:bookUrl completion:^(NSURL *encryptedUrl, NSError *error) {
      if (error) {
        NSString *errorMessage = NSLocalizedString(@"Error extracting encrypted PDF file", nil);
        [TPPErrorLogger logError:error
                         summary:errorMessage
                        metadata:@{ @"error": error }];
        UIAlertController *alert = [TPPAlertUtils alertWithTitle:errorMessage error:error];
        [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
        return;
      }
      NSData *encryptedData = [[NSData alloc] initWithContentsOfURL:encryptedUrl options:NSDataReadingMappedAlways error:nil];

      TPPPDFDocumentMetadata *metadata = [[TPPPDFDocumentMetadata alloc] initWith:book.identifier];
      metadata.title = book.title;
      
      TPPPDFDocument *document = [[TPPPDFDocument alloc] initWithEncryptedData:encryptedData decryptor:^NSData * _Nonnull(NSData *data, NSUInteger start, NSUInteger end) {
        return [decryptor decryptDataWithData:data start:start end:end];
      }];
      
      UIViewController *vc = [TPPPDFViewController createWithDocument:document metadata:metadata];
      [[TPPRootTabBarController sharedController] pushViewController:vc animated:YES];
    }];
  } else {
    [self presentPDF:book];
  }
#else
  [self presentPDF:book];
#endif
}

/// Present Palace PDF reader
/// @param book PDF Book object
- (void)presentPDF:(TPPBook *)book {
  NSURL *bookUrl = [[MyBooksDownloadCenter shared] fileUrlFor:book.identifier];
  NSData *data = [[NSData alloc] initWithContentsOfURL:bookUrl options:NSDataReadingMappedAlways error:nil];

  TPPPDFDocumentMetadata *metadata = [[TPPPDFDocumentMetadata alloc] initWith:book.identifier];
  metadata.title = book.title;
  
  TPPPDFDocument *document = [[TPPPDFDocument alloc] initWithData:data];
  
  UIViewController *vc = [TPPPDFViewController createWithDocument:document metadata:metadata];
  [[TPPRootTabBarController sharedController] pushViewController:vc animated:YES];
}

- (void)openAudiobook:(TPPBook *)book {
  NSURL *const url = [[MyBooksDownloadCenter shared] fileUrlFor:book.identifier];
  NSMutableDictionary *dict = nil;
  
#if defined(LCP)
  if ([LCPAudiobooks canOpenBook:book]) {
    LCPAudiobooks *lcpAudiobooks = [[LCPAudiobooks alloc] initFor:url];
    [lcpAudiobooks contentDictionaryWithCompletion:^(NSDictionary * _Nullable dict, NSError * _Nullable error) {
      if (error) {
        [self presentUnsupportedItemError];
        return;
      }
      if (dict) {
        NSMutableDictionary *mutableDict = [dict mutableCopy];
        mutableDict[@"id"] = book.identifier;
        [self openAudiobook:book withJSON:mutableDict decryptor:lcpAudiobooks];
      }
    }];
    return;
  }
#endif

  NSError *error = nil;
  NSData *const data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error];
  if (data == nil) {
    [self presentCorruptedItemErrorForBook:book fromURL:url];
    return;
  }
  id const json = TPPJSONObjectFromData(data);

#if FEATURE_OVERDRIVE
  if ([book.distributor isEqualToString:OverdriveDistributorKey]) {
    dict = [(NSMutableDictionary *)json mutableCopy];
    dict[@"id"] = book.identifier;
  }
#endif

  [self openAudiobook:book withJSON:dict ?: json decryptor:nil];
}

- (void)openAudiobook:(TPPBook *)book withJSON:(NSDictionary *)json decryptor:(id<DRMDecryptor>)audiobookDrmDecryptor {
  [AudioBookVendorsHelper updateVendorKeyWithBook:json completion:^(NSError * _Nullable error) {
    [NSOperationQueue.mainQueue addOperationWithBlock:^{
      id<Audiobook> const audiobook = [AudiobookFactory audiobook:json bookID:book.identifier decryptor:audiobookDrmDecryptor token:book.bearerToken];

      if (!audiobook) {
        if (error) {
          [self presentDRMKeyError:error];
        } else {
          [self presentUnsupportedItemError];
        }
        return;
      }

      AudiobookTimeTracker *timeTracker;
      if (book.timeTrackingURL) {
        timeTracker = [[AudiobookTimeTracker alloc] initWithLibraryId:AccountsManager.shared.currentAccount.uuid bookId:book.identifier timeTrackingUrl:book.timeTrackingURL];
      }
      
      AudiobookMetadata *const metadata = [[AudiobookMetadata alloc]
                                           initWithTitle:book.title
                                           authors:@[book.authors]];
      id<AudiobookManager> const manager = [[DefaultAudiobookManager alloc]
                                            initWithMetadata:metadata
                                            audiobook:audiobook
                                            playbackTrackerDelegate:timeTracker];
      
      
      self.book = book;
      self.audiobookBookmarkBusinessLogic = [[AudiobookBookmarkBusinessLogic alloc] initWithBook:book];

      manager.refreshDelegate = self;
      manager.playbackPositionDelegate = self;
      manager.bookmarkDelegate = self.audiobookBookmarkBusinessLogic;

      AudiobookPlayer *audiobookPlayer = [[AudiobookPlayer alloc] initWithAudiobookManager:manager];

      [self registerCallbackForLogHandler];

      [[TPPBookRegistry shared] coverImageFor:book handler:^(UIImage *image) {
        if (image) {
          [audiobookPlayer updateImage:image];
        }
      }];

      [[TPPRootTabBarController sharedController] pushViewController:audiobookPlayer animated:YES];

      __weak UIViewController *weakAudiobookVC = audiobookPlayer;
      [manager setPlaybackCompletionHandler:^{
        NSSet<NSString *> *types = [[NSSet alloc] initWithObjects:
                                    ContentTypeFindaway,
                                    ContentTypeBearerToken,
                                    ContentTypeOpenAccessAudiobook,
                                    ContentTypeOverdriveAudiobook,
                                    ContentTypeFeedbooksAudiobook,
                                    nil
        ];
        NSArray<TPPOPDSAcquisitionPath *> *paths = [TPPOPDSAcquisitionPath
                                                     supportedAcquisitionPathsForAllowedTypes:types
                                                    allowedRelations:(TPPOPDSAcquisitionRelationSetBorrow |
                                                                      TPPOPDSAcquisitionRelationSetGeneric)
                                                     acquisitions:book.acquisitions];
        if (paths.count > 0) {
          UIAlertController *alert = [TPPReturnPromptHelper audiobookPromptWithCompletion:^(BOOL returnWasChosen) {
            if (returnWasChosen) {
              [weakAudiobookVC.navigationController popViewControllerAnimated:YES];
              [self didSelectReturnForBook:book completion:nil];
            }
            [TPPAppStoreReviewPrompt presentIfAvailable];
          }];
          [[TPPRootTabBarController sharedController] presentViewController:alert animated:YES completion:nil];
        } else {
          TPPLOG(@"Skipped Return Prompt with no valid acquisition path.");
          [TPPAppStoreReviewPrompt presentIfAvailable];
        }
      }];

      [self startLoading:audiobookPlayer];

      TPPBookLocation *localAudiobookLocation = [[TPPBookRegistry shared] locationForIdentifier:book.identifier];
      NSData *localLocationData = [localAudiobookLocation.locationString dataUsingEncoding:NSUTF8StringEncoding];
      ChapterLocation *localLocation = [ChapterLocation fromData:localLocationData];
  
      // Player error handler
      void (^moveCompletionHandler)(NSError *) = ^(NSError *error) {
        if (error) {
          [self presentLocationRecoveryError:error];
          return;
        }
        [self stopLoading];
      };
      
      // The player moves to the local position before loading a remote one.
      // This way the user sees the last playhead position.
      if (localLocation) {
        [manager.audiobook.player movePlayheadToLocation:localLocation completion:moveCompletionHandler];
        [self stopLoading];
      }
      
      [[TPPBookRegistry shared] syncLocationFor:book completion:^(ChapterLocation * _Nullable remoteLocation) {
        [self chooseLocalLocation:localLocation orRemoteLocation:remoteLocation forOperation:^(ChapterLocation *location) {
          [NSOperationQueue.mainQueue addOperationWithBlock:^{
            TPPLOG_F(@"Returning to Audiobook Location: %@", location);
            if (location) {
              [manager.audiobook.player movePlayheadToLocation:location completion:moveCompletionHandler];
            } else {
              [self stopLoading];
            }
          }];
        }];
      }];
      
      [self scheduleTimerForAudiobook:book manager:manager viewController:audiobookPlayer];
    }];
  }];
}

/// Requests whether the user wants to ysnc current listening position
/// - Parameter completion: completion with `YES` or `NO` to the sync
- (void) requestSyncWithCompletion:(void (^)(BOOL))completion {
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    NSString *title = LocalizedStrings.syncListeningPositionAlertTitle;
    NSString *message = LocalizedStrings.syncListeningPositionAlertBody;
    NSString *moveTitle = LocalizedStrings.move;
    NSString *stayTitle = LocalizedStrings.stay;
    
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *moveAction = [UIAlertAction actionWithTitle:moveTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull __unused action) {
      completion(YES);
    }];
    UIAlertAction *stayAction = [UIAlertAction actionWithTitle:stayTitle style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull __unused action) {
      completion(NO);
    }];
    [ac addAction:moveAction];
    [ac addAction:stayAction];
    [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:ac viewController:nil animated:YES completion:nil];
  }];
}

/// Pick one of the locations
/// - Parameters:
///   - localLocation: local player location
///   - remoteLocation: remote player location
///   - operation: operation block on the selected location
- (void) chooseLocalLocation:(ChapterLocation *)localLocation orRemoteLocation:(ChapterLocation *)remoteLocation forOperation:(void (^)(ChapterLocation *))operation {
  
  BOOL remoteLocationIsNewer = NO;
  if (localLocation == nil && remoteLocation != nil) {
    remoteLocationIsNewer = YES;
  } else if (localLocation != nil && remoteLocation != nil) {
    remoteLocationIsNewer = [NSString isDate:remoteLocation.lastSavedTimeStamp moreRecentThan:localLocation.lastSavedTimeStamp with:kServerUpdateDelay];
  }
  if (remoteLocation && (![remoteLocation.description isEqualToString:localLocation.description]) && remoteLocationIsNewer) {
    [self requestSyncWithCompletion:^(BOOL shouldSync) {
      ChapterLocation *location = shouldSync ? remoteLocation : localLocation;
      operation(location);
    }];
  } else {
    operation(localLocation);
  }
}

- (void) startLoading:(UIViewController *)hostViewController {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.loadingViewController = [[LoadingViewController alloc] init];
    [hostViewController addChildViewController:self.loadingViewController];
    self.loadingViewController.view.frame = hostViewController.view.frame;
    [hostViewController.view addSubview:self.loadingViewController.view];
    [self.loadingViewController didMoveToParentViewController:hostViewController];
  });
}

- (void) stopLoading {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.loadingViewController willMoveToParentViewController:nil];
    [self.loadingViewController.view removeFromSuperview];
    [self.loadingViewController removeFromParentViewController];
    self.loadingViewController = nil;
  });
}

#pragma mark - Audiobook Methods

- (void)registerCallbackForLogHandler
{
  [DefaultAudiobookManager setLogHandler:^(enum LogLevel level, NSString * _Nonnull message, NSError * _Nullable error) {
    NSString *msg = [NSString stringWithFormat:@"Level: %ld. Message: %@",
                     (long)level, message];

    if (error) {
      [TPPErrorLogger logError:error
                        summary:@"Error registering audiobook callback for logging"
                       metadata:@{ @"context": msg ?: @"N/A" }];
    } else if (level > LogLevelDebug) {
      NSString *logLevel = (level == LogLevelInfo ?
                            @"info" :
                            (level == LogLevelWarn ? @"warning" : @"error"));
      NSString *summary = [NSString stringWithFormat:@"PalaceAudiobookToolkit::AudiobookManager %@", logLevel];
      [TPPErrorLogger logErrorWithCode:TPPErrorCodeAudiobookExternalError
                                summary:summary
                               metadata:@{ @"context": msg ?: @"N/A" }];
    }
  }];
}

- (void)scheduleTimerForAudiobook:(TPPBook *)book
                          manager:(id<AudiobookManager>)manager
                   viewController:(UIViewController *)viewController
{
  self.audiobookViewController = viewController;
  self.manager = manager;
  // Target-Selector method required for iOS <10.0
  self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                target:self
                                              selector:@selector(pollAudiobookReadingLocation)
                                              userInfo:nil
                                               repeats:YES];
}

- (void)pollAudiobookReadingLocation
{
  if (!self.audiobookViewController) {
    [self.timer invalidate];
    self.timer = nil;
    self.manager = nil;
    return;
  }
  
  // Only update audiobook location when we are not loading
  if (self.loadingViewController != nil) {
    return;
  }

  NSString *const string = [[NSString alloc]
                            initWithData:self.manager.audiobook.player.currentChapterLocation.toData
                            encoding:NSUTF8StringEncoding];

  // Save updated playhead position in audiobook chapter
  NSTimeInterval playheadOffset = self.manager.audiobook.player.currentChapterLocation.actualOffset;
  if (previousPlayheadOffset != playheadOffset && playheadOffset > 0) {
    previousPlayheadOffset = playheadOffset;
  
    [[TPPBookRegistry shared]
     setLocation:[[TPPBookLocation alloc] initWithLocationString:string renderer:@"PalaceAudiobookToolkit"]
     forIdentifier:self.book.identifier];
    
    if ([[NSDate date] timeIntervalSinceDate: self.lastServerUpdate] >= kServerUpdateDelay) {
      self.lastServerUpdate = [NSDate date];
      // Save updated location on server
      [self saveListeningPositionAt:string completion:nil];
    }
  }
}

- (void)presentDRMKeyError:(NSError *) error {
  NSString *title = NSLocalizedString(@"DRM Error", nil);
  NSString *message = error.localizedDescription;
  UIAlertController *alert = [TPPAlertUtils alertWithTitle:title message:message];
  [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
}

- (void)presentUnsupportedItemError
{
  NSString *title = NSLocalizedString(@"Unsupported Item", nil);
  NSString *message = NSLocalizedString(@"The item you are trying to open is not currently supported.", nil);
  UIAlertController *alert = [TPPAlertUtils alertWithTitle:title message:message];
  [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
}

- (void)presentCorruptedItemErrorForBook:(TPPBook*)book fromURL:(NSURL*)url
{
  NSString *title = NSLocalizedString(@"Corrupted Audiobook", nil);
  NSString *message = NSLocalizedString(@"The audiobook you are trying to open appears to be corrupted. Try downloading it again.", nil);
  UIAlertController *alert = [TPPAlertUtils alertWithTitle:title message:message];
  [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];

  [TPPErrorLogger logErrorWithCode:TPPErrorCodeAudiobookCorrupted
                            summary:@"Audiobooks: corrupted audiobook"
                           metadata:@{
                             @"book": book.loggableDictionary ?: @"N/A",
                             @"fileURL": url ?: @"N/A"
                           }];
}


- (void)presentLocationRecoveryError:(NSError *)error {
  NSString *title = NSLocalizedString(@"Location Recovery Error", nil);
  NSString *message = error.localizedDescription;
  UIAlertController *alert = [TPPAlertUtils alertWithTitle:title message:message];
  [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
}

#pragma mark TPPBookDownloadFailedDelegate

- (void)didSelectCancelForBookDownloadFailedCell:(TPPBookDownloadFailedCell *const)cell
{
  [[MyBooksDownloadCenter shared]
   cancelDownloadFor:cell.book.identifier];
}

- (void)didSelectTryAgainForBookDownloadFailedCell:(TPPBookDownloadFailedCell *const)cell
{
  [[MyBooksDownloadCenter shared] startDownloadFor: cell.book withRequest:nil];
}

#pragma mark TPPBookDownloadingCellDelegate

- (void)didSelectCancelForBookDownloadingCell:(TPPBookDownloadingCell *const)cell
{
  [[MyBooksDownloadCenter shared]
   cancelDownloadFor:cell.book.identifier];
}

#pragma mark Audiobook Manager Refresh Delegate

- (void)audiobookManagerDidRequestRefresh {
  if (![self.refreshAudiobookLock tryLock]) {
    return;
  }
    
  [[TPPBookRegistry shared] setState:TPPBookStateDownloadNeeded for:self.book.identifier];

#if FEATURE_OVERDRIVE
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateODAudiobookManifest) name:NSNotification.TPPMyBooksDownloadCenterDidChange object:nil];
#endif
  [[MyBooksDownloadCenter shared] startDownloadFor:self.book withRequest:nil];
}

#if FEATURE_OVERDRIVE
- (void)updateODAudiobookManifest {
  if ([[TPPBookRegistry shared] stateFor:self.book.identifier] == TPPBookStateDownloadSuccessful) {
    OverdriveAudiobook *odAudiobook = (OverdriveAudiobook *)self.manager.audiobook;

    NSURL *const url = [[MyBooksDownloadCenter shared] fileUrlFor: self.book.identifier];
    NSData *const data = [NSData dataWithContentsOfURL:url];
    if (data == nil) {
      [self presentCorruptedItemErrorForBook:self.book fromURL:url];
      return;
    }

    id const json = TPPJSONObjectFromData(data);

    NSMutableDictionary *dict = [(NSMutableDictionary *)json mutableCopy];

    dict[@"id"] = self.book.identifier;

    if ([odAudiobook respondsToSelector:@selector(updateManifestWithJSON:)]) {
      [odAudiobook updateManifestWithJSON:dict];
    }
  
    DefaultAudiobookManager *audiobookManager = (DefaultAudiobookManager *)_manager;
    [audiobookManager updateAudiobookWith:odAudiobook.spine];
      
    [[NSNotificationCenter defaultCenter] removeObserver:self];
      
    [self.refreshAudiobookLock unlock];
  }
}
#endif

@end

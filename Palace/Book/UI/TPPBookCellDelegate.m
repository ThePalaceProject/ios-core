@import MediaPlayer;
@import NYPLAudiobookToolkit;
@import PDFRendererProvider;
#if FEATURE_OVERDRIVE
@import OverdriveProcessor;
#endif

#import "TPPAccountSignInViewController.h"
#import "TPPBook.h"
#import "TPPBookDownloadFailedCell.h"
#import "TPPBookDownloadingCell.h"
#import "TPPBookLocation.h"
#import "TPPBookNormalCell.h"
#import "TPPMyBooksDownloadCenter.h"
#import "TPPRootTabBarController.h"

#import "NSURLRequest+NYPLURLRequestAdditions.h"
#import "TPPJSON.h"
#import "TPPReachabilityManager.h"

#import "TPPBookCellDelegate.h"
#import "Palace-Swift.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#endif

@interface TPPBookCellDelegate () <RefreshDelegate>

@property (nonatomic) NSTimer *timer;
@property (nonatomic) TPPBook *book;
@property (nonatomic) id<AudiobookManager> manager;
@property (nonatomic, weak) AudiobookPlayerViewController *audiobookViewController;
@property (strong) NSLock *refreshAudiobookLock;

@end

@implementation TPPBookCellDelegate

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
  
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark TPPBookButtonsDelegate

- (void)didSelectReturnForBook:(TPPBook *)book
{
  [[TPPMyBooksDownloadCenter sharedDownloadCenter] returnBookWithIdentifier:book.identifier];
}

- (void)didSelectDownloadForBook:(TPPBook *)book
{
  [[TPPMyBooksDownloadCenter sharedDownloadCenter] startDownloadForBook:book];
}

- (void)didSelectReadForBook:(TPPBook *)book
{ 
#if defined(FEATURE_DRM_CONNECTOR)
  // Try to prevent blank books bug

  TPPUserAccount *user = [TPPUserAccount sharedAccount];
  if ([user hasCredentials]
      && [AdobeCertificate.defaultCertificate hasExpired] == NO
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
#else
  [self openBook:book];
#endif
}

- (void)openBook:(TPPBook *)book
{
  [TPPCirculationAnalytics postEvent:@"open_book" withBook:book];

  switch (book.defaultBookContentType) {
    case TPPBookContentTypeEPUB:
      [self openEPUB:book];
      break;
    case TPPBookContentTypePDF:
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

  NSURL *const url = [[TPPMyBooksDownloadCenter sharedDownloadCenter] fileURLForBookIndentifier:book.identifier];

  NSArray<TPPBookLocation *> *const genericMarks = [[TPPBookRegistry sharedRegistry] genericBookmarksForIdentifier:book.identifier];
  NSMutableArray<MinitexPDFPage *> *const bookmarks = [NSMutableArray array];
  for (TPPBookLocation *loc in genericMarks) {
    NSData *const data = [loc.locationString dataUsingEncoding:NSUTF8StringEncoding];
    MinitexPDFPage *const page = [MinitexPDFPage fromData:data];
    [bookmarks addObject:page];
  }

  MinitexPDFPage *startingPage;
  TPPBookLocation *const startingBookLocation = [[TPPBookRegistry sharedRegistry] locationForIdentifier:book.identifier];
  NSData *const data = [startingBookLocation.locationString dataUsingEncoding:NSUTF8StringEncoding];
  if (data) {
    startingPage = [MinitexPDFPage fromData:data];
    TPPLOG_F(@"Returning to PDF Location: %@", startingPage);
  }

  id<MinitexPDFViewController> pdfViewController = [MinitexPDFViewControllerFactory createWithFileUrl:url openToPage:startingPage bookmarks:bookmarks annotations:nil];

  if (pdfViewController) {
    pdfViewController.delegate = [[TPPPDFViewControllerDelegate alloc] initWithBookIdentifier:book.identifier];
    [(UIViewController *)pdfViewController setHidesBottomBarWhenPushed:YES];
    [[TPPRootTabBarController sharedController] pushViewController:(UIViewController *)pdfViewController animated:YES];
  } else {
    [self presentUnsupportedItemError];
    return;
  }
}

- (void)openAudiobook:(TPPBook *)book {
  NSURL *const url = [[TPPMyBooksDownloadCenter sharedDownloadCenter] fileURLForBookIndentifier:book.identifier];
  NSData *const data = [NSData dataWithContentsOfURL:url];
  if (data == nil) {
    [self presentCorruptedItemErrorForBook:book fromURL:url];
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
  } else {
    // Not an LCP book
    [self openAudiobook:book withJSON:dict ?: json decryptor:nil];
  }
#else
  [self openAudiobook:book withJSON:dict ?: json decryptor:nil];
#endif
}

- (void)openAudiobook:(TPPBook *)book withJSON:(NSDictionary *)json decryptor:(id<DRMDecryptor>)audiobookDrmDecryptor {
  [AudioBookVendorsHelper updateVendorKeyWithBook:json completion:^(NSError * _Nullable error) {
    [NSOperationQueue.mainQueue addOperationWithBlock:^{
      id<Audiobook> const audiobook = [AudiobookFactory audiobook:json decryptor:audiobookDrmDecryptor];
      
      if (!audiobook) {
        if (error) {
          [self presentDRMKeyError:error];
        } else {
          [self presentUnsupportedItemError];
        }
        return;
      }

      AudiobookMetadata *const metadata = [[AudiobookMetadata alloc]
                                           initWithTitle:book.title
                                           authors:@[book.authors]];
      id<AudiobookManager> const manager = [[DefaultAudiobookManager alloc]
                                            initWithMetadata:metadata
                                            audiobook:audiobook];
      manager.refreshDelegate = self;

      AudiobookPlayerViewController *const audiobookVC = [[AudiobookPlayerViewController alloc]
                                                          initWithAudiobookManager:manager];

      [self registerCallbackForLogHandler];

      [[TPPBookRegistry sharedRegistry] coverImageForBook:book handler:^(UIImage *image) {
        if (image) {
          [audiobookVC.coverView setImage:image];
        }
      }];

      audiobookVC.hidesBottomBarWhenPushed = YES;
      audiobookVC.view.tintColor = [TPPConfiguration mainColor];
      [[TPPRootTabBarController sharedController] pushViewController:audiobookVC animated:YES];

      __weak AudiobookPlayerViewController *weakAudiobookVC = audiobookVC;
      [manager setPlaybackCompletionHandler:^{
        NSSet<NSString *> *types = [[NSSet alloc] initWithObjects:ContentTypeFindaway, ContentTypeOpenAccessAudiobook, ContentTypeFeedbooksAudiobook, nil];
        NSArray<TPPOPDSAcquisitionPath *> *paths = [TPPOPDSAcquisitionPath
                                                     supportedAcquisitionPathsForAllowedTypes:types
                                                    allowedRelations:(TPPOPDSAcquisitionRelationSetBorrow |
                                                                      TPPOPDSAcquisitionRelationSetGeneric)
                                                     acquisitions:book.acquisitions];
        if (paths.count > 0) {
          UIAlertController *alert = [TPPReturnPromptHelper audiobookPromptWithCompletion:^(BOOL returnWasChosen) {
            if (returnWasChosen) {
              [weakAudiobookVC.navigationController popViewControllerAnimated:YES];
              [self didSelectReturnForBook:book];
            }
            [TPPAppStoreReviewPrompt presentIfAvailable];
          }];
          [[TPPRootTabBarController sharedController] presentViewController:alert animated:YES completion:nil];
        } else {
          TPPLOG(@"Skipped Return Prompt with no valid acquisition path.");
          [TPPAppStoreReviewPrompt presentIfAvailable];
        }
      }];

      TPPBookLocation *const bookLocation =
      [[TPPBookRegistry sharedRegistry] locationForIdentifier:book.identifier];

      if (bookLocation) {
        NSData *const data = [bookLocation.locationString dataUsingEncoding:NSUTF8StringEncoding];
        ChapterLocation *const chapterLocation = [ChapterLocation fromData:data];
        TPPLOG_F(@"Returning to Audiobook Location: %@", chapterLocation);
        [manager.audiobook.player movePlayheadToLocation:chapterLocation];
      }

      [self scheduleTimerForAudiobook:book manager:manager viewController:audiobookVC];
    }];
  }];
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
      NSString *summary = [NSString stringWithFormat:@"NYPLAudiobookToolkit::AudiobookManager %@", logLevel];
      [TPPErrorLogger logErrorWithCode:TPPErrorCodeAudiobookExternalError
                                summary:summary
                               metadata:@{ @"context": msg ?: @"N/A" }];
    }
  }];
}

- (void)scheduleTimerForAudiobook:(TPPBook *)book
                          manager:(id<AudiobookManager>)manager
                   viewController:(AudiobookPlayerViewController *)viewController
{
  self.audiobookViewController = viewController;
  self.book = book;
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
    self.book = nil;
    self.manager = nil;
    return;
  }

  NSString *const string = [[NSString alloc]
                            initWithData:self.manager.audiobook.player.currentChapterLocation.toData
                            encoding:NSUTF8StringEncoding];
  [[TPPBookRegistry sharedRegistry]
   setLocation:[[TPPBookLocation alloc] initWithLocationString:string renderer:@"NYPLAudiobookToolkit"]
   forIdentifier:self.book.identifier];
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

#pragma mark TPPBookDownloadFailedDelegate

- (void)didSelectCancelForBookDownloadFailedCell:(TPPBookDownloadFailedCell *const)cell
{
  [[TPPMyBooksDownloadCenter sharedDownloadCenter]
   cancelDownloadForBookIdentifier:cell.book.identifier];
}

- (void)didSelectTryAgainForBookDownloadFailedCell:(TPPBookDownloadFailedCell *const)cell
{
  [[TPPMyBooksDownloadCenter sharedDownloadCenter] startDownloadForBook:cell.book];
}

#pragma mark TPPBookDownloadingCellDelegate

- (void)didSelectCancelForBookDownloadingCell:(TPPBookDownloadingCell *const)cell
{
  [[TPPMyBooksDownloadCenter sharedDownloadCenter]
   cancelDownloadForBookIdentifier:cell.book.identifier];
}

#pragma mark Audiobook Manager Refresh Delegate

- (void)audiobookManagerDidRequestRefresh {
  if (![self.refreshAudiobookLock tryLock]) {
    return;
  }
    
  [[TPPBookRegistry sharedRegistry] setState:TPPBookStateDownloadNeeded forIdentifier:self.book.identifier];

#if FEATURE_OVERDRIVE
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateODAudiobookManifest) name:NSNotification.TPPMyBooksDownloadCenterDidChange object:nil];
#endif
  [[TPPMyBooksDownloadCenter sharedDownloadCenter] startDownloadForBook:self.book];
}

#if FEATURE_OVERDRIVE
- (void)updateODAudiobookManifest {
  if ([[TPPBookRegistry sharedRegistry] stateForIdentifier:self.book.identifier] == TPPBookStateDownloadSuccessful) {
    OverdriveAudiobook *odAudiobook = (OverdriveAudiobook *)self.manager.audiobook;

    NSURL *const url = [[TPPMyBooksDownloadCenter sharedDownloadCenter] fileURLForBookIndentifier:self.book.identifier];
    NSData *const data = [NSData dataWithContentsOfURL:url];
    if (data == nil) {
      [self presentCorruptedItemErrorForBook:self.book fromURL:url];
      return;
    }

    id const json = TPPJSONObjectFromData(data);

    NSMutableDictionary *dict = [(NSMutableDictionary *)json mutableCopy];

    dict[@"id"] = self.book.identifier;

    [odAudiobook updateManifestWithJSON:dict];

    DefaultAudiobookManager *audiobookManager = (DefaultAudiobookManager *)_manager;
    [audiobookManager updateAudiobookWith:odAudiobook.spine];
      
    [[NSNotificationCenter defaultCenter] removeObserver:self];
      
    [self.refreshAudiobookLock unlock];
  }
}
#endif

@end

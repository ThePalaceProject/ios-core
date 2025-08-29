@import MediaPlayer;
#if FEATURE_OVERDRIVE
@import OverdriveProcessor;
#endif
@import PDFKit;

#import "TPPAccountSignInViewController.h"
#import "TPPBookDownloadFailedCell.h"
#import "TPPBookDownloadingCell.h"
#import "TPPBookNormalCell.h"
#import "Palace-Swift.h"

#import "NSURLRequest+NYPLURLRequestAdditions.h"
#import "TPPJSON.h"

#import "TPPBookCellDelegate.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#endif

@interface TPPBookCellDelegate ()
{
  @private NSTimeInterval previousPlayheadOffset;
}

@property (strong) NSLock *refreshAudiobookLock;
@property (nonatomic, strong) LoadingViewController *loadingViewController;

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

- (void)didSelectReadForBook:(TPPBook *)book completion:(void (^ _Nullable)(void))completion
{ 
#if defined(FEATURE_DRM_CONNECTOR)
  // Try to prevent blank books bug

  TPPUserAccount *user = [TPPUserAccount sharedAccount];
  if ([user hasCredentials]) {
    if ([user hasAuthToken]) {
      [self openBook:book completion:completion];
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
            [self openBook:book completion:completion];   // with successful DRM activation
          });
        }];
      } else {
        [self openBook:book completion:completion];
      }
  } else {
    [self openBook:book completion:completion];
  }
#else
  [self openBook:book completion:completion];
#endif
}

- (void)openBook:(TPPBook *)book completion:(void (^ _Nullable)(void))completion
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
      [self openAudiobook:book completion:completion];
      break;
    default:
      [self presentUnsupportedItemError];
      break;
  }
}

- (void)openEPUB:(TPPBook *)book
{
  // TODO: Bridge to SwiftUI coordinator route for EPUB when available
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

      if (!encryptedUrl) {
        NSError *urlError = [NSError errorWithDomain:@"com.Palace.pdf" code:1001 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Invalid encrypted URL", nil)}];
        NSString *errorMessage = NSLocalizedString(@"Error extracting encrypted PDF file", nil);
        [TPPErrorLogger logError:urlError
                         summary:errorMessage
                        metadata:@{ @"error": urlError }];
        UIAlertController *alert = [TPPAlertUtils alertWithTitle:errorMessage error:urlError];
        [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
        return;
      }

      NSData *encryptedData = [[NSData alloc] initWithContentsOfURL:encryptedUrl options:NSDataReadingMappedAlways error:nil];
      if (!encryptedData) {
        NSError *dataError = [NSError errorWithDomain:@"com.Palace.pdf" code:1002 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Unable to load encrypted PDF data", nil)}];
        NSString *errorMessage = NSLocalizedString(@"Error extracting encrypted PDF file", nil);
        [TPPErrorLogger logError:dataError
                         summary:errorMessage
                        metadata:@{ @"error": dataError }];
        UIAlertController *alert = [TPPAlertUtils alertWithTitle:errorMessage error:dataError];
        [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
        return;
      }

      TPPPDFDocumentMetadata *metadata = [[TPPPDFDocumentMetadata alloc] initWith:book];

      TPPPDFDocument *document = [[TPPPDFDocument alloc] initWithEncryptedData:encryptedData decryptor:^NSData * _Nonnull(NSData *data, NSUInteger start, NSUInteger end) {
        return [decryptor decryptDataWithData:data start:start end:end];
      }];

      // Present PDF via SwiftUI host; fallback removed in migration
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

  TPPPDFDocumentMetadata *metadata = [[TPPPDFDocumentMetadata alloc] initWith:book];

  TPPPDFDocument *document = [[TPPPDFDocument alloc] initWithData:data];
  
  UIViewController *vc = [TPPPDFViewController createWithDocument:document metadata:metadata];
  [TPPPresentationUtils safelyPresent:vc animated:YES completion:nil];
}

- (void)openAudiobook:(TPPBook *)book completion:(void (^ _Nullable)(void))completion {
#if defined(LCP)
  if ([LCPAudiobooks canOpenBook:book]) {
    [self openAudiobookWithUnifiedStreaming:book completion:completion];
    return;
  }
#endif
  
  NSURL *const url = [[MyBooksDownloadCenter shared] fileUrlFor:book.identifier];
  if (!url) {
    [self presentCorruptedItemErrorForBook:book fromURL:url];
    if (completion) completion();
    return;
  }

  NSError *error = nil;
  NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error];

  if (!data) {
    [self presentCorruptedItemErrorForBook:book fromURL:url];
    if (completion) completion();
    return;
  }

  id json = TPPJSONObjectFromData(data);
  if (!json) {
    [self presentUnsupportedItemError];
    if (completion) completion();
    return;
  }

  NSMutableDictionary *dict = [json mutableCopy];
#if FEATURE_OVERDRIVE
  if ([book.distributor isEqualToString:OverdriveDistributorKey]) {
    dict[@"id"] = book.identifier;
  }
#endif

  [self openAudiobookWithBook:book json:dict drmDecryptor:nil completion:completion];
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

- (void) startLoading:(UIViewController *)hostViewController {
  self.isSyncing = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    self.loadingViewController = [[LoadingViewController alloc] init];
    [hostViewController addChildViewController:self.loadingViewController];
    self.loadingViewController.view.frame = hostViewController.view.frame;
    [hostViewController.view addSubview:self.loadingViewController.view];
    [self.loadingViewController didMoveToParentViewController:hostViewController];
  });
}

- (void) stopLoading {
  self.isSyncing = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.loadingViewController willMoveToParentViewController:nil];
    [self.loadingViewController.view removeFromSuperview];
    [self.loadingViewController removeFromParentViewController];
    self.loadingViewController = nil;
  });
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

@end

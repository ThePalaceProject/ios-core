#import "TPPReadiumViewSyncManager.h"

#import "NSDate+NYPLDateAdditions.h"
#import "TPPBook.h"
#import "TPPBookLocation.h"
#import "TPPBookRegistry.h"
#import "TPPConfiguration.h"
#import "TPPJSON.h"
#import "TPPReachability.h"
#import "TPPReaderSettings.h"
#import "TPPRootTabBarController.h"
#import "Palace-Swift.h"

@interface TPPReadiumViewSyncManager ()

@property (nonatomic) NSString *bookID;
@property (nonatomic) NSURL *annotationsURL;
@property (nonatomic) NSDictionary *bookMapDictionary;
@property (nonatomic, weak) id<NYPLReadiumViewSyncManagerDelegate> delegate;
@property (nonatomic) BOOL shouldPostLastRead;
@property (nonatomic) NSString *queuedReadingPosition;
@property (nonatomic) NYPLReadPositionSyncStatus syncStatus;

@end

@implementation TPPReadiumViewSyncManager

const double RequestTimeInterval = 120;

- (instancetype) initWithBookID:(NSString *)bookID
                 annotationsURL:(NSURL *)URL
                        bookMap:(NSDictionary *)map
                       delegate:(id)delegate
{
  self = [super init];
  if (self) {
    self.bookID = bookID;
    self.annotationsURL = URL;
    self.bookMapDictionary = map;
    self.delegate = delegate;
    self.shouldPostLastRead = NO;
    self.syncStatus = NYPLReadPositionSyncStatusIdle;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sendOffAnyQueuedRequest)
                                                 name:UIApplicationWillResignActiveNotification object:nil];
  }
  return self;
}

- (void)dealloc
{
  [self sendOffAnyQueuedRequest];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)syncAllAnnotationsWithPackage:(NSDictionary *)packageDict
{
  if (![TPPAnnotations syncIsPossibleAndPermitted]) {
    return;
  }

  NSMutableDictionary *const dictionary = [NSMutableDictionary dictionary];
  dictionary[@"package"] = packageDict;
  dictionary[@"settings"] = [[TPPReaderSettings sharedSettings] readiumSettingsRepresentation];
  TPPBookLocation *const location = [[TPPBookRegistry sharedRegistry]
                                      locationForIdentifier:self.bookID];

  [self syncReadingPositionForBook:self.bookID
                        atLocation:location
                             toURL:self.annotationsURL
                       withPackage:dictionary];

  [self syncBookmarksWithCompletion:nil];
}

- (void)postLastReadPosition:(NSString *)location
{
  if (!self.shouldPostLastRead) {
    return;
  }

  // Protect against a high frequency of requests to the server
  @synchronized(self) {
    switch (self.syncStatus) {
      case NYPLReadPositionSyncStatusIdle: {
        self.syncStatus = NYPLReadPositionSyncStatusBusy;
        [TPPAnnotations postReadingPositionForBook:self.bookID
                                      selectorValue:location];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RequestTimeInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          @synchronized(self) {
            self.syncStatus = NYPLReadPositionSyncStatusIdle;
            if (self.queuedReadingPosition) {
              [self postLastReadPosition:self.queuedReadingPosition];
              self.queuedReadingPosition = nil;
            }
          }
        });
        break;
      }
      case NYPLReadPositionSyncStatusBusy: {
        self.queuedReadingPosition = location;
        break;
      }
    }
  }
}

- (void)syncReadingPositionForBook:(NSString *)bookID
                        atLocation:(TPPBookLocation *)location
                             toURL:(NSURL *)URL
                       withPackage:(NSMutableDictionary *)dictionary
{
  __weak TPPReadiumViewSyncManager *const weakSelf = self;

  [TPPAnnotations syncReadingPositionOfBook:bookID toURL:URL completion:^(TPPReadiumBookmark * _Nullable bookmark) {

    // Still on a background thread

    if (!weakSelf.delegate) {
      return;
    }

    if (!bookmark) {
      TPPLOG_F(@"No reading position annotation exists on the server for bookID: %@.",
                bookID);
      weakSelf.shouldPostLastRead = YES;
      return;
    }

    NSString* serverLocationString = bookmark.location;
    NSDictionary *responseJSON = [NSJSONSerialization
                                  JSONObjectWithData:[serverLocationString
                                                      dataUsingEncoding:NSUTF8StringEncoding]
                                  options:NSJSONReadingMutableContainers error:nil];
    NSString* deviceIDString = bookmark.device;

    NSString* currentLocationString = location.locationString;
    TPPLOG_F(@"serverLocationString %@",serverLocationString);
    TPPLOG_F(@"currentLocationString %@",currentLocationString);

    // Pass through without presenting the Alert Controller if:
    // 1 - The most recent page on the server comes from the same device
    // 2 - The server and the client have the same page marked
    // 3 - There is no recent page saved on the server
    if ((currentLocationString && [deviceIDString isEqualToString:[TPPUserAccount sharedAccount].deviceID]) ||
        [currentLocationString isEqualToString:serverLocationString] ||
        !serverLocationString) {
      weakSelf.shouldPostLastRead = YES;
      return;
    }
      
    [self presentSyncReadingPositionAlertForResponse:responseJSON
                                      serverLocation:serverLocationString
                                         withPackage:dictionary];
  }];
}

- (void)presentSyncReadingPositionAlertForResponse:(NSDictionary *)response
                                    serverLocation:(NSString *)location
                                       withPackage:(NSMutableDictionary *)dictionary {
  NSDictionary *spineItemDetails = self.bookMapDictionary[response[@"idref"]];
  NSString *elementTitle = spineItemDetails[@"tocElementTitle"];
  if (!elementTitle) {
    elementTitle = @"";
  }
    
  NSString *message = NSLocalizedString(@"Do you want to move to the page on which you left off?", nil);
  NSAttributedString *atrString;
  if (![elementTitle isEqualToString:@"Current Chapter"]) {
    message = [message stringByAppendingString:[NSString stringWithFormat:@"<br><br>Chapter:\n&ldquo;%@&ldquo;", elementTitle]];
    atrString = [[NSAttributedString alloc] initWithData:[message dataUsingEncoding:NSUTF8StringEncoding]
                                                                     options:@{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
                                                                               NSCharacterEncodingDocumentAttribute: @(NSUTF8StringEncoding)}
                                                          documentAttributes:nil error:nil];
  }

  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    UIAlertController *alertController = [UIAlertController
                                          alertControllerWithTitle:NSLocalizedString(@"Sync Reading Position", nil)
                                          message:(atrString != nil) ? [atrString string] : message
                                          preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *stayAction =
     [UIAlertAction actionWithTitle:NSLocalizedString(@"Stay", nil)
                              style:UIAlertActionStyleCancel
                            handler:^(__attribute__((unused))UIAlertAction * _Nonnull action) {
                              if ([self.delegate respondsToSelector:@selector(patronDecidedNavigation:withNavDict:)]) {
                                [self.delegate patronDecidedNavigation:NO withNavDict:nil];
                              }
                              self.shouldPostLastRead = YES;
                            }];

    UIAlertAction *moveAction =
     [UIAlertAction actionWithTitle:NSLocalizedString(@"Move", nil)
                              style:UIAlertActionStyleDefault
                            handler:^(__attribute__((unused))UIAlertAction * _Nonnull action) {

                              self.shouldPostLastRead = YES;

                              NSDictionary *const locationDictionary =
                              TPPJSONObjectFromData([location dataUsingEncoding:NSUTF8StringEncoding]);

                              NSString *contentCFI = locationDictionary[TPPBookmarkDictionaryRepresentation.cfiKey];

                              dictionary[@"openPageRequest"] = @{
                                TPPBookmarkDictionaryRepresentation.idrefKey:
                                  locationDictionary[TPPBookmarkDictionaryRepresentation.idrefKey],
                                TPPBookmarkDictionaryRepresentation.cfiKey:
                                  contentCFI ?: @""};

                              if ([self.delegate respondsToSelector:@selector(patronDecidedNavigation:withNavDict:)]) {
                                [self.delegate patronDecidedNavigation:YES withNavDict:dictionary];
                              }
                            }];

    [alertController addAction: stayAction];
    [alertController addAction: moveAction];

    if (@available (iOS 9.0, *)) {
      alertController.preferredAction = moveAction;
    }

    [[TPPRootTabBarController sharedController] safelyPresentViewController:alertController animated:YES completion:nil];
  }];
}

- (void)addBookmark:(TPPReadiumBookmark *)bookmark
            withCFI:(NSString *)location
            forBook:(NSString *)bookID
{
  Account *currentAccount = [[AccountsManager sharedInstance] currentAccount];
  if (currentAccount.details.syncPermissionGranted) {
    [TPPAnnotations postBookmark:bookmark
                        forBookID:bookID
                       completion:^(NSString * _Nullable serverAnnotationID) {
      if (serverAnnotationID) {
        TPPLOG_F(@"Bookmark upload success: %@", location);
      } else {
        TPPLOG_F(@"Bookmark failed to upload: %@", location);
      }
      bookmark.annotationId = serverAnnotationID;
      [self.delegate uploadFinishedForBookmark:bookmark inBook:bookID];
    }];
  } else {
    [self.delegate uploadFinishedForBookmark:bookmark inBook:bookID];
    TPPLOG(@"Bookmark saving locally. Sync is not enabled for account.");
  }
}

- (void)syncBookmarksWithCompletion:(void(^)(BOOL success, NSArray<TPPReadiumBookmark *> *bookmarks))completion
{
  [[TPPReachability sharedReachability]
   reachabilityForURL:[TPPConfiguration mainFeedURL]
   timeoutInternal:8.0
   handler:^(BOOL reachable) {

     if (!reachable) {
       TPPLOG(@"Error: host was not reachable for bookmark sync attempt.");
       if (completion) {
         completion(NO, [[TPPBookRegistry sharedRegistry] readiumBookmarksForIdentifier:self.bookID]);
       }
       return;
     }

     // First check for and upload any local bookmarks that have never been saved to the server.
     // Wait til that's finished, then download the server's bookmark list and filter out any that can be deleted.
     NSArray<TPPReadiumBookmark *> *localBookmarks = [[TPPBookRegistry sharedRegistry] readiumBookmarksForIdentifier:self.bookID];
     [TPPAnnotations uploadLocalBookmarks:localBookmarks forBook:self.bookID completion:^(NSArray<TPPReadiumBookmark *> * _Nonnull bookmarksUploaded, NSArray<TPPReadiumBookmark *> * _Nonnull bookmarksFailedToUpload) {

       // Replace local bookmarks with server versions
       for (TPPReadiumBookmark *localBKM in localBookmarks) {
         for (TPPReadiumBookmark *uploadedBKM in bookmarksUploaded) {
           if ([localBKM isEqual:uploadedBKM]) {
             [[TPPBookRegistry sharedRegistry] replaceBookmark:localBKM with:uploadedBKM forIdentifier:self.bookID];
           }
         }
       }

       [TPPAnnotations getServerBookmarksForBook:self.bookID atURL:self.annotationsURL completion:^(NSArray<TPPReadiumBookmark *> * _Nullable serverBookmarks) {

         if (!serverBookmarks) {
           TPPLOG(@"Ending sync without running completion. Returning original list of bookmarks.");
           if (completion) {
             completion(NO, [[TPPBookRegistry sharedRegistry] readiumBookmarksForIdentifier:self.bookID]);
           }
           return;
         } else if (serverBookmarks.count == 0) {
           TPPLOG(@"No server bookmarks were returned.");
         } else {
           TPPLOG_F(@"\nServer Bookmarks:\n\n%@", serverBookmarks);
         }

         // Bookmarks that are present on the client, and have a corresponding version on the server
         // with matching annotation ID's should be kept on the client.
         NSMutableArray<TPPReadiumBookmark *> *localBookmarksToKeep = [[NSMutableArray alloc] init];
         // Bookmarks that are present on the client, have been uploaded before,
         // but are no longer on the server, should be deleted on the client.
         NSMutableArray<TPPReadiumBookmark *> *localBookmarksToDelete = [[NSMutableArray alloc] init];
         // Bookmarks that are present on the server, but not the client, should be added to this
         // client as long as they were not created on this device originally.
         NSMutableArray<TPPReadiumBookmark *> *serverBookmarksToKeep = serverBookmarks.mutableCopy;
         // Bookmarks present on the server, that were originally created on this device,
         // and are no longer present on the client, should be deleted on the server.
         NSMutableArray<TPPReadiumBookmark *> *serverBookmarksToDelete = [[NSMutableArray alloc] init];

         for (TPPReadiumBookmark *serverBookmark in serverBookmarks) {
           NSPredicate *predicate = [NSPredicate predicateWithFormat:@"annotationId == %@", serverBookmark.annotationId];
           NSArray *matchingBookmarks = [localBookmarks filteredArrayUsingPredicate:predicate];

           [localBookmarksToKeep addObjectsFromArray:matchingBookmarks];

           if (matchingBookmarks.count == 0 &&
               [serverBookmark.device isEqualToString:[[TPPUserAccount sharedAccount] deviceID]]) {
             [serverBookmarksToDelete addObject:serverBookmark];
             [serverBookmarksToKeep removeObject:serverBookmark];
           }
         }

         for (TPPReadiumBookmark *localBookmark in localBookmarks) {
           if (![localBookmarksToKeep containsObject:localBookmark]) {
             [[TPPBookRegistry sharedRegistry] deleteReadiumBookmark:localBookmark forIdentifier:self.bookID];
             [localBookmarksToDelete addObject:localBookmark];
           }
         }

         NSMutableArray<TPPReadiumBookmark *> *bookmarksToAdd = serverBookmarks.mutableCopy;
         [bookmarksToAdd addObjectsFromArray:bookmarksFailedToUpload];

         for (TPPReadiumBookmark *serverMark in serverBookmarksToKeep) {
           for (TPPReadiumBookmark *localMark in localBookmarksToKeep) {
             if ([serverMark isEqual:localMark]) {
               [bookmarksToAdd removeObject:localMark];
             }
           }
         }

         for (TPPReadiumBookmark *bookmark in bookmarksToAdd) {
           [[TPPBookRegistry sharedRegistry] addReadiumBookmark:bookmark forIdentifier:self.bookID];
         }

         if (serverBookmarksToDelete.count > 0) {
           [TPPAnnotations deleteBookmarks:serverBookmarksToDelete];
         }

         if (completion) {
           completion(YES,[[TPPBookRegistry sharedRegistry] readiumBookmarksForIdentifier:self.bookID]);
         }
       }];
     }];
   }];
}

- (void)sendOffAnyQueuedRequest
{
  @synchronized(self) {
    if (self.queuedReadingPosition) {
      [TPPAnnotations postReadingPositionForBook:self.bookID
                                    selectorValue:self.queuedReadingPosition];
      self.queuedReadingPosition = nil;
    }
  }
}

@end

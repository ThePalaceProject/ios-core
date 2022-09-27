#import "TPPBookRegistry.h"

#import "TPPBook.h"
#import "TPPBookCoverRegistry.h"
#import "TPPBookRegistryRecord.h"
#import "TPPConfiguration.h"
#import "TPPJSON.h"
#import "TPPOPDS.h"
#import "TPPMyBooksDownloadCenter.h"
#import "Palace-Swift.h"

@interface TPPBookRegistry ()

@property (nonatomic) TPPBookCoverRegistry *coverRegistry;
@property (nonatomic) NSMutableDictionary *identifiersToRecords;
@property (atomic) BOOL shouldBroadcast;
@property (atomic) BOOL syncing;
@property (atomic) BOOL syncShouldCommit;
@property (nonatomic) BOOL delaySync;
@property (nonatomic, copy) void (^delayedSyncBlock)(void);
@property (nonatomic) NSMutableSet *processingIdentifiers;

@end

static NSString *const RegistryFilename = @"registry.json";

static NSString *const RecordsKey = @"records";

@implementation TPPBookRegistry

+ (TPPBookRegistry *)sharedRegistry
{
  static dispatch_once_t predicate;
  static TPPBookRegistry *sharedRegistry = nil;
  
  dispatch_once(&predicate, ^{
    // Cast allows access to unavailable |init| method.
    sharedRegistry = [[self alloc] init];
    if(!sharedRegistry) {
      TPPLOG(@"Failed to create shared registry.");
      @throw NSMallocException;
    }
    
    [sharedRegistry justLoad];
  });
  
  return sharedRegistry;
}

#pragma mark NSObject

- (instancetype)init
{
  self = [super init];
  if(!self) return nil;
  
  self.coverRegistry = [[TPPBookCoverRegistry alloc] init];
  self.identifiersToRecords = [NSMutableDictionary dictionary];
  self.processingIdentifiers = [NSMutableSet set];
  self.shouldBroadcast = YES;
  return self;
}

#pragma mark -

- (NSURL *)registryDirectory
{
  NSURL *URL = [[TPPBookContentMetadataFilesHelper currentAccountDirectory]
                URLByAppendingPathComponent:@"registry"];

  return URL;
}
- (NSURL *)registryDirectory:(NSString *)account
{
  NSURL *URL = [[TPPBookContentMetadataFilesHelper directoryFor:account]
                URLByAppendingPathComponent:@"registry"];
  
  return URL;
}

- (NSArray<NSString *> *__nonnull)bookIdentifiersForAccount:(NSString * const)account
{
  NSURL *const url = [[TPPBookContentMetadataFilesHelper directoryFor:account]
                      URLByAppendingPathComponent:@"registry/registry.json"];
  NSData *const data = [NSData dataWithContentsOfURL:url];
  if (!data) {
    return @[];
  }
  
  id const json = TPPJSONObjectFromData(data);
  if (!json) @throw NSInternalInconsistencyException;
  
  NSDictionary *const dictionary = json;
  if (![dictionary isKindOfClass:[NSDictionary class]]) @throw NSInternalInconsistencyException;
  
  NSArray *const records = dictionary[@"records"];
  if (![records isKindOfClass:[NSArray class]]) @throw NSInternalInconsistencyException;
  
  NSMutableArray *const identifiers = [NSMutableArray arrayWithCapacity:records.count];
  for (NSDictionary *const record in records) {
    if (![record isKindOfClass:[NSDictionary class]]) @throw NSInternalInconsistencyException;
    NSDictionary *const metadata = record[@"metadata"];
    if (![metadata isKindOfClass:[NSDictionary class]]) @throw NSInternalInconsistencyException;
    NSString *const identifier = metadata[@"id"];
    if (![identifier isKindOfClass:[NSString class]]) @throw NSInternalInconsistencyException;
    [identifiers addObject:identifier];
  }
  
  return identifiers;
}

- (void)performSynchronizedWithoutBroadcasting:(void (^)(void))block
{
  @synchronized(self) {
    self.shouldBroadcast = NO;
    block();
    self.shouldBroadcast = YES;
  }
}

- (void)broadcastChange
{
  if (!self.shouldBroadcast) {
    return;
  }

  // We send the notification out on the next run through the run loop to avoid deadlocks that could
  // occur due to calling synchronized methods on this object in response to a broadcast that
  // originated from within a synchronized block.
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
      return;
    }

    [[NSNotificationCenter defaultCenter]
     postNotificationName:NSNotification.TPPBookRegistryDidChange
     object:self];
  }];
}

- (void)broadcastProcessingChangeForIdentifier:(NSString *)identifier value:(BOOL)value
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [[NSNotificationCenter defaultCenter]
     postNotificationName:NSNotification.TPPBookProcessingDidChange
     object:self
     userInfo:@{TPPNotificationKeys.bookProcessingBookIDKey: identifier,
                TPPNotificationKeys.bookProcessingValueKey: @(value)}];
  }];
}

- (void)justLoad
{
  [self loadWithoutBroadcastingForAccount:[AccountsManager sharedInstance].currentAccount.uuid];
  [self broadcastChange];
}

- (void)loadWithoutBroadcastingForAccount:(NSString *)account
{
  @synchronized(self) {
    self.identifiersToRecords = [NSMutableDictionary dictionary];
    
    NSData *const savedData = [NSData dataWithContentsOfURL:
                               [[self registryDirectory:account]
                                URLByAppendingPathComponent:RegistryFilename]];
    
    if(!savedData) return;
    
    NSDictionary *const dictionary = TPPJSONObjectFromData(savedData);
    
    if(!dictionary) {
      TPPLOG(@"Failed to interpret saved registry data as JSON.");
      return;
    }
    
    for(NSDictionary *const recordDictionary in dictionary[RecordsKey]) {
      TPPBookRegistryRecord *const record = [[TPPBookRegistryRecord alloc]
                                              initWithDictionary:recordDictionary];
      // If record doesn't exist, proceed to next record
      if (!record) {
        continue;
      }
      // If a download was still in progress when we quit, it must now be failed.
      if(record.state == TPPBookStateDownloading || record.state == TPPBookStateSAMLStarted) {
        self.identifiersToRecords[record.book.identifier] =
        [record recordWithState:TPPBookStateDownloadFailed];
      } else {
        self.identifiersToRecords[record.book.identifier] = record;
      }
    }
  }
}

- (void)save
{
  if ([AccountsManager.sharedInstance currentAccount] == nil) {
    return;
  }
  @synchronized(self) {
    NSError *error = nil;
    if(![[NSFileManager defaultManager]
         createDirectoryAtURL:[self registryDirectory]
         withIntermediateDirectories:YES
         attributes:nil
         error:&error]) {
      TPPLOG(@"Failed to create registry directory.");
      return;
    }
    
    if(![[self registryDirectory] setResourceValue:@YES
                                            forKey:NSURLIsExcludedFromBackupKey
                                             error:&error]) {
      TPPLOG(@"Failed to exclude registry directory from backup.");
      return;
    }
    
    NSOutputStream *const stream =
      [NSOutputStream
       outputStreamWithURL:[[[self registryDirectory]
                             URLByAppendingPathComponent:RegistryFilename]
                            URLByAppendingPathExtension:@"temp"]
       append:NO];
      
    [stream open];
    
    // This try block is necessary to catch an (entirely undocumented) exception thrown by
    // NSJSONSerialization in the event that the provided stream isn't open for writing.
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wassign-enum"
      if(![NSJSONSerialization
           writeJSONObject:[self dictionaryRepresentation]
           toStream:stream
           options:0
           error:&error]) {
#pragma clang diagnostic pop
        TPPLOG(@"Failed to write book registry.");
        return;
      }
    } @catch(NSException *const exception) {
      TPPLOG([exception reason]);
      return;
    } @finally {
      [stream close];
    }
    
    if(![[NSFileManager defaultManager]
         replaceItemAtURL:[[self registryDirectory] URLByAppendingPathComponent:RegistryFilename]
         withItemAtURL:[[[self registryDirectory]
                         URLByAppendingPathComponent:RegistryFilename]
                        URLByAppendingPathExtension:@"temp"]
         backupItemName:nil
         options:NSFileManagerItemReplacementUsingNewMetadataOnly
         resultingItemURL:NULL
         error:&error]) {
      TPPLOG(@"Failed to rename temporary registry file.");
      return;
    }
  }
}

- (void)syncResettingCache:(BOOL)shouldResetCache
         completionHandler:(void (^)(NSDictionary *errorDict))handler
{
  [self syncResettingCache:shouldResetCache
         completionHandler:handler
    backgroundFetchHandler:nil];
}

- (void)syncResettingCache:(BOOL)shouldResetCache
         completionHandler:(void (^)(NSDictionary *errorDict))completion
    backgroundFetchHandler:(void (^)(UIBackgroundFetchResult))fetchHandler
{
  @synchronized(self) {

    [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncBegan object:nil];

    if (self.syncing) {
      TPPLOG(@"[syncWithCompletionHandler] Already syncing");
      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if(fetchHandler) fetchHandler(UIBackgroundFetchResultNoData);
      }];
      return;
    } else if (!TPPUserAccount.sharedAccount.hasCredentials || !AccountsManager.shared.currentAccount.loansUrl) {
      TPPLOG(@"[syncWithCompletionHandler] No valid credentials");
      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if(completion) {
          TPPProblemDocument *problemDoc = [TPPProblemDocument forExpiredOrMissingCredentials:
                                             TPPUserAccount.sharedAccount.hasCredentials];
          [TPPErrorLogger logErrorWithCode:TPPErrorCodeInvalidCredentials
                                    summary:@"Unable to sync loans"
                                   metadata:@{
                                     @"shouldResetCache": @(shouldResetCache),
                                     @"hasCredentials": @(TPPUserAccount.sharedAccount.hasCredentials),
                                     @"synthesize problem doc": problemDoc.dictionaryValue
                                   }];
          completion(problemDoc.dictionaryValue);
        }
        if(fetchHandler) fetchHandler(UIBackgroundFetchResultNoData);
        [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];
      }];
      return;
    } else {
      self.syncing = YES;
      self.syncShouldCommit = YES;
      [self broadcastChange];
    }
  }
  
  [TPPOPDSFeed
   withURL:[[[AccountsManager sharedInstance] currentAccount] loansUrl]
   shouldResetCache:shouldResetCache
   completionHandler:^(TPPOPDSFeed *const feed, NSDictionary *error) {
     if(!feed) {
       TPPLOG(@"Failed to obtain sync data.");
       self.syncing = NO;
       [self broadcastChange];
       [[NSOperationQueue mainQueue]
        addOperationWithBlock:^{
          if(completion) completion(error);
          if(fetchHandler) fetchHandler(UIBackgroundFetchResultFailed);
          [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];
        }];
       [TPPErrorLogger logErrorWithCode:TPPErrorCodeApiCall
                                 summary:@"Unable to fetch loans"
                                metadata:@{
                                  @"shouldResetCache": @(shouldResetCache),
                                  @"errorDict": error ?: @"N/A"
                                }];
       return;
     }

    [TPPErrorLogger setUserID:[[TPPUserAccount sharedAccount] barcode]];
     
     if(!self.syncShouldCommit) {
       TPPLOG(@"[syncWithCompletionHandler] Sync shouldn't commit");
       // A reset must have occurred.
       self.syncing = NO;
       [self broadcastChange];
       [[NSOperationQueue mainQueue]
        addOperationWithBlock:^{
          if(fetchHandler) fetchHandler(UIBackgroundFetchResultNoData);
        }];
       return;
     }
     
     void (^commitBlock)(void) = ^void() {
       [self performSynchronizedWithoutBroadcasting:^{

         if (feed.licensor) {
           [[TPPUserAccount sharedAccount] setLicensor:feed.licensor];
           TPPLOG_F(@"\nLicensor Token Updated: %@\nFor account: %@",feed.licensor[@"clientToken"],[TPPUserAccount sharedAccount].userID);
         } else {
           TPPLOG(@"A Licensor Token was not received or parsed from the OPDS feed.");
         }

         // load local copy before removing identifiers
         [self justLoad];
         NSMutableSet *identifiersToRemove = [NSMutableSet setWithArray:self.identifiersToRecords.allKeys];
         for(TPPOPDSEntry *const entry in feed.entries) {
           TPPBook *const book = [TPPBook bookWithEntry:entry];
           if(!book) {
             TPPLOG_F(@"Failed to create book for entry '%@'.", entry.identifier);
             continue;
           }
           [identifiersToRemove removeObject:book.identifier];
           TPPBook *const existingBook = [self bookForIdentifier:book.identifier];
           if(existingBook) {
             [self updateBook:book];
           } else {
             [self addBook:book location:nil state:TPPBookStateDownloadNeeded fulfillmentId:nil readiumBookmarks:nil genericBookmarks:nil];
           }
         }
         for (NSString *identifier in identifiersToRemove) {
           TPPBookRegistryRecord *record = [self.identifiersToRecords objectForKey:identifier];
           if (record && (record.state == TPPBookStateDownloadSuccessful || record.state == TPPBookStateUsed)) {
             [[TPPMyBooksDownloadCenter sharedDownloadCenter] deleteLocalContentForBookIdentifier:identifier];
           }
           [self removeBookForIdentifier:identifier];
         }
       }];
       self.syncing = NO;
       [self broadcastChange];
       [[NSOperationQueue mainQueue]
        addOperationWithBlock:^{
          [TPPUserNotifications updateAppIconBadgeWithHeldBooks:[self heldBooks]];
          if(completion) completion(nil);
          if(fetchHandler) fetchHandler(UIBackgroundFetchResultNewData);
          [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];
        }];
     };
     
     if (self.delaySync) {
       if (self.delayedSyncBlock) {
         TPPLOG(@"[syncWithCompletionHandler] Delaying sync; block already exists!");
       } else {
         TPPLOG(@"[syncWithCompletionHandler] Delaying sync");
       }
       self.delayedSyncBlock = commitBlock;
     } else {
       commitBlock();
     }
   }];
}

- (void)syncWithStandardAlertsOnCompletion
{
  [self syncResettingCache:YES completionHandler:^(NSDictionary *errorDict) {
    if (errorDict == nil) {
      [self save];
    } else {
      UIAlertController *alert = [TPPAlertUtils alertWithTitle:@"SyncFailed"
                                                        message:@"We found a problem. Please check your connection or close and reopen the app to retry."];
      [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
    }
  }];
}

- (void)addBook:(TPPBook *const)book
       location:(TPPBookLocation *const)location
          state:(NSInteger)state
  fulfillmentId:(NSString *)fulfillmentId
readiumBookmarks:(NSArray<TPPReadiumBookmark *> *)readiumBookmarks
genericBookmarks:(NSArray<TPPBookLocation *> *)genericBookmarks
{
  if(!book) {
    @throw NSInvalidArgumentException;
  }
  
  if(state == TPPBookStateUnregistered) {
    @throw NSInvalidArgumentException;
  }
  
  @synchronized(self) {
    [self.coverRegistry pinThumbnailImageForBook:book];
    self.identifiersToRecords[book.identifier] = [[TPPBookRegistryRecord alloc]
                                                  initWithBook:book
                                                  location:location
                                                  state:state
                                                  fulfillmentId:fulfillmentId
                                                  readiumBookmarks:readiumBookmarks
                                                  genericBookmarks:genericBookmarks];
    [self broadcastChange];
  }
}

- (void)updateBook:(TPPBook *const)book
{
  if(!book) {
    @throw NSInvalidArgumentException;
  }
  
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[book.identifier];
    if(record) {
      [TPPUserNotifications compareAvailabilityWithCachedRecord:record andNewBook:book];
      self.identifiersToRecords[book.identifier] = [record recordWithBook:book];
      [self broadcastChange];
    }
  }
}

- (void)updateAndRemoveBook:(TPPBook *)book
{
  if(!book) {
    @throw NSInvalidArgumentException;
  }
  
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[book.identifier];
    if(record) {
      [self.coverRegistry removePinnedThumbnailImageForBookIdentifier:book.identifier];
      self.identifiersToRecords[book.identifier] = [[record recordWithBook:book] recordWithState:TPPBookStateUnregistered];
      [self broadcastChange];
    }
  }
}

- (TPPBook *)updatedBookMetadata:(TPPBook *)book
{
  if(!book) {
    @throw NSInvalidArgumentException;
  }
  
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[book.identifier];
    if(record) {
      book = [record.book bookWithMetadataFromBook:book];
      TPPBookRegistryRecord *const updatedRecord = [record recordWithBook:book];
      self.identifiersToRecords[book.identifier] = updatedRecord;
      TPPBook *updatedBook = updatedRecord.book;
      [self broadcastChange];
      return updatedBook;
    }
    return nil;
  }
}

- (TPPBook *)bookForIdentifier:(NSString *const)identifier
{
  @synchronized(self) {
    return ((TPPBookRegistryRecord *) self.identifiersToRecords[identifier]).book;
  }
}

- (void)setState:(TPPBookState)state forIdentifier:(NSString *const)identifier
{
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    if(!record) {
      TPPLOG(@"Record Object is nil");
      return;
    }
    
    self.identifiersToRecords[identifier] = [record recordWithState:state];
    
    [self broadcastChange];
  }
}

// TODO: Remove when migration to Swift completed
- (void)setStateWithCode:(NSInteger)stateCode forIdentifier:(nonnull NSString *)identifier
{
  [self setState:stateCode forIdentifier:identifier];
}

- (TPPBookState)stateForIdentifier:(NSString *const)identifier
{
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    if(record) {
      return record.state;
    } else {
      return TPPBookStateUnregistered;
    }
  }
}

- (void)setLocation:(TPPBookLocation *const)location forIdentifier:(NSString *const)identifier
{
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    if(!record) {
      @throw NSInvalidArgumentException;
    }
    
    self.identifiersToRecords[identifier] = [record recordWithLocation:location];
    
    [self broadcastChange];
  }
}

- (TPPBookLocation *)locationForIdentifier:(NSString *const)identifier
{
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    return record.location;
  }
}

- (void)setFulfillmentId:(NSString *)fulfillmentId forIdentifier:(NSString *)identifier
{
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    if(!record) {
      @throw NSInvalidArgumentException;
    }
    
    self.identifiersToRecords[identifier] = [record recordWithFulfillmentId:fulfillmentId];
    
    // This shouldn't be required, since nothing needs to display differently if the fulfillmentId changes
    // [self broadcastChange];
  }
}

- (NSString *)fulfillmentIdForIdentifier:(NSString *)identifier
{
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    return record.fulfillmentId;
  }
}

- (NSArray<TPPReadiumBookmark *> *)readiumBookmarksForIdentifier:(NSString *)identifier
{
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    
    NSArray<TPPReadiumBookmark *> *sortedArray = [record.readiumBookmarks sortedArrayUsingComparator:^NSComparisonResult(TPPReadiumBookmark *obj1, TPPReadiumBookmark *obj2) {
      if (obj1.progressWithinBook > obj2.progressWithinBook)
        return NSOrderedDescending;
      else if (obj1.progressWithinBook < obj2.progressWithinBook)
        return NSOrderedAscending;
      return NSOrderedSame;
    }];
      
    return sortedArray ?: [NSArray array];
  }
}
  
-(void)addReadiumBookmark:(TPPReadiumBookmark *)bookmark forIdentifier:(NSString *)identifier
{
  @synchronized(self) {
    
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
      
    NSMutableArray<TPPReadiumBookmark *> *bookmarks = record.readiumBookmarks.mutableCopy;
    if (!bookmarks) {
      bookmarks = [NSMutableArray array];
    }
    [bookmarks addObject:bookmark];
    
    self.identifiersToRecords[identifier] = [record recordWithReadiumBookmarks:bookmarks];
    
    [[TPPBookRegistry sharedRegistry] save];
  }
}
  
- (void)deleteReadiumBookmark:(TPPReadiumBookmark *)bookmark forIdentifier:(NSString *)identifier
{
  @synchronized(self) {
      
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
      
    NSMutableArray<TPPReadiumBookmark *> *bookmarks = record.readiumBookmarks.mutableCopy;
    if (!bookmarks) {
      return;
    }
    [bookmarks removeObject:bookmark];
    
    self.identifiersToRecords[identifier] = [record recordWithReadiumBookmarks:bookmarks];
    
    [[TPPBookRegistry sharedRegistry] save];
  }
}

- (void)replaceBookmark:(TPPReadiumBookmark *)oldBookmark with:(TPPReadiumBookmark *)newBookmark forIdentifier:(NSString *)identifier
{
  @synchronized(self) {
    
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    
    NSMutableArray<TPPReadiumBookmark *> *bookmarks = record.readiumBookmarks.mutableCopy;
    if (!bookmarks) {
      return;
    }
    [bookmarks removeObject:oldBookmark];
    [bookmarks addObject:newBookmark];

    self.identifiersToRecords[identifier] = [record recordWithReadiumBookmarks:bookmarks];
    
    [[TPPBookRegistry sharedRegistry] save];
  }
}

- (NSArray<TPPBookLocation *> *)genericBookmarksForIdentifier:(NSString *)identifier
{
  @synchronized(self) {
    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];
    return record.genericBookmarks;
  }
}

- (void)addGenericBookmark:(TPPBookLocation *)bookmark forIdentifier:(NSString *)identifier
{
  @synchronized(self) {

    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];

    NSMutableArray<TPPBookLocation *> *bookmarks = record.genericBookmarks.mutableCopy;
    if (!bookmarks) {
      bookmarks = [NSMutableArray array];
    }
    [bookmarks addObject:bookmark];

    self.identifiersToRecords[identifier] = [record recordWithGenericBookmarks:bookmarks];

    [[TPPBookRegistry sharedRegistry] save];
  }
}

- (void)deleteGenericBookmark:(TPPBookLocation *)bookmark forIdentifier:(NSString *)identifier
{
  @synchronized(self) {

    TPPBookRegistryRecord *const record = self.identifiersToRecords[identifier];

    NSMutableArray<TPPBookLocation *> *bookmarks = record.genericBookmarks.mutableCopy;
    if (!bookmarks) {
      return;
    }
    NSArray<TPPBookLocation *> *filteredArray =
    [bookmarks filteredArrayUsingPredicate:
     [NSPredicate predicateWithBlock:
      ^BOOL(TPPBookLocation *object, __unused NSDictionary *bindings) {
        return [object.locationString isEqualToString:bookmark.locationString] == NO;
      }]];

    self.identifiersToRecords[identifier] = [record recordWithGenericBookmarks:filteredArray];

    [[TPPBookRegistry sharedRegistry] save];
  }
}


- (void)setProcessing:(BOOL)processing forIdentifier:(NSString *)identifier
{
  // guard to avoid crash
  if (identifier == nil) {
    return;
  }

  @synchronized(self) {
    if(processing) {
      [self.processingIdentifiers addObject:identifier];
    } else {
      [self.processingIdentifiers removeObject:identifier];
    }
    [self broadcastProcessingChangeForIdentifier:identifier value:processing];
  }
}

- (BOOL)processingForIdentifier:(NSString *)identifier
{
  @synchronized(self) {
    return [self.processingIdentifiers containsObject:identifier];
  }
}

- (void)removeBookForIdentifier:(NSString *const)identifier
{
  @synchronized(self) {
    [self.coverRegistry removePinnedThumbnailImageForBookIdentifier:identifier];
    [self.identifiersToRecords removeObjectForKey:identifier];
    [self broadcastChange];
  }
}

- (void)thumbnailImageForBook:(TPPBook *const)book
                      handler:(void (^)(UIImage *image))handler
{
  [self.coverRegistry thumbnailImageForBook:book handler:handler];
}

- (void)coverImageForBook:(TPPBook *const)book
                  handler:(void (^)(UIImage *image))handler
{
  [self.coverRegistry coverImageForBook:book handler:handler];
}

- (void)thumbnailImagesForBooks:(NSSet *const)books
                        handler:(void (^)(NSDictionary *bookIdentifiersToImages))handler
{
  [self.coverRegistry thumbnailImagesForBooks:books handler:handler];
}

- (UIImage *)cachedThumbnailImageForBook:(TPPBook *const)book
{
  return [self.coverRegistry cachedThumbnailImageForBook:book];
}

- (void)reset:(NSString *)account
{
  if ([[AccountsManager shared].currentAccount.uuid isEqualToString:account])
  {
    [self reset];
  }
  else
  {
    @synchronized(self) {
      [[NSFileManager defaultManager] removeItemAtURL:[self registryDirectory:account] error:NULL];
    }
  }
}


- (void)reset
{
  @synchronized(self) {
    self.syncShouldCommit = NO;
    [self.coverRegistry removeAllPinnedThumbnailImages];
    [self.identifiersToRecords removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtURL:[self registryDirectory] error:NULL];
  }
  
  [self broadcastChange];
}

- (NSDictionary *)dictionaryRepresentation
{
  NSMutableArray *const records =
    [NSMutableArray arrayWithCapacity:self.identifiersToRecords.count];
  
  for(TPPBookRegistryRecord *const record in [self.identifiersToRecords allValues]) {
    [records addObject:[record dictionaryRepresentation]];
  }
  
  return @{RecordsKey: records};
}

- (NSUInteger)count
{
  @synchronized(self) {
    return self.identifiersToRecords.count;
  }
}

- (NSArray *)allBooks
{
  return [self booksMatchingStates:[TPPBookStateHelper allBookStates]];
}

- (NSArray *)heldBooks
{
  return [self booksMatchingStates:@[@(TPPBookStateHolding)]];
}

- (NSArray *)myBooks
{
  return [self booksMatchingStates:@[@(TPPBookStateDownloadNeeded),
                                     @(TPPBookStateDownloading),
                                     @(TPPBookStateSAMLStarted),
                                     @(TPPBookStateDownloadFailed),
                                     @(TPPBookStateDownloadSuccessful),
                                     @(TPPBookStateUsed)]];
}

- (NSArray *)booksMatchingStates:(NSArray * _Nonnull)states {
  @synchronized(self) {
    NSMutableArray *const books =
    [NSMutableArray arrayWithCapacity:self.identifiersToRecords.count];
    
    [self.identifiersToRecords
     enumerateKeysAndObjectsUsingBlock:^(__attribute__((unused)) NSString *identifier,
                                         TPPBookRegistryRecord *const record,
                                         __attribute__((unused)) BOOL *stop) {
      if (record.state && [states containsObject:@(record.state)]) {
        [books addObject:record.book];
      }
    }];
    
    return books;
  }
}

- (void)delaySyncCommit
{
  self.delaySync = YES;
}

- (void)stopDelaySyncCommit
{
  self.delaySync = NO;
  if(self.delayedSyncBlock) {
    self.delayedSyncBlock();
    self.delayedSyncBlock = nil;
  }
}

- (void)performUsingAccount:(NSString * const)account block:(void (^const __nonnull)(void))block
{
  @synchronized (self) {
    if ([account isEqualToString:[AccountsManager sharedInstance].currentAccount.uuid]) {
      // Since we're already set to the account, do not reload data. Doing so would
      // be inefficient, but, more importantly, it would also wipe out download states.
      block();
    } else {
      // Since the function contract specifies that the registry will not be modified
      // by `block`, we have no need to copy `self.identifiersToRecords` here.
      NSMutableDictionary *const currentIdentifiersToRecords = self.identifiersToRecords;
      [self loadWithoutBroadcastingForAccount:account];
      block();
      self.identifiersToRecords = currentIdentifiersToRecords;
    }
  }
}

@end

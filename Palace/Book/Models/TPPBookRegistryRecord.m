#import "TPPBook.h"
#import "TPPBookLocation.h"
#import "TPPBookRegistryRecord.h"
#import "TPPNull.h"
#import "TPPOPDS.h"
#import "Palace-Swift.h"

@interface TPPBookRegistryRecord ()

@property (nonatomic) TPPBook *book;
@property (nonatomic) TPPBookLocation *location;
@property (nonatomic) TPPBookState state;
@property (nonatomic) NSString *fulfillmentId;
@property (nonatomic) NSArray<TPPReadiumBookmark *> *readiumBookmarks;
@property (nonatomic) NSArray<TPPBookLocation *> *genericBookmarks;

@end

static NSString *const BookKey = @"metadata";
static NSString *const StateKey = @"state";
static NSString *const FulfillmentIdKey = @"fulfillmentId";
static NSString *const ReadiumBookmarksKey = @"bookmarks";
static NSString *const GenericBookmarksKey = @"genericBookmarks";

@implementation TPPBookRegistryRecord

- (instancetype)initWithBook:(TPPBook *const)book
                    location:(TPPBookLocation *const)location
                       state:(TPPBookState)state
               fulfillmentId:(NSString *)fulfillmentId
            readiumBookmarks:(NSArray<TPPReadiumBookmark *> *)readiumBookmarks
            genericBookmarks:(NSArray<TPPBookLocation *> *)genericBookmarks
{
  self = [super init];
  if(!self) return nil;
  
  if(!book) {
    @throw NSInvalidArgumentException;
  }
  
  self.book = book;
  self.location = location;
  self.state = state;
  self.fulfillmentId = fulfillmentId;
  self.readiumBookmarks = readiumBookmarks;
  self.genericBookmarks = genericBookmarks;

  if (!book.defaultAcquisition) {
    // Since the book has no default acqusition, there is no reliable way to
    // determine if the book is on hold (although it may be), nor is there any
    // way to download the book if it is available. As such, we give the book a
    // special "unsupported" state which will allow other parts of the app to
    // ignore it as appropriate. Unsupported books should generally only appear
    // when a user has checked out or reserved a book in an unsupported format
    // using another app.
    self.state = TPPBookStateUnsupported;
    return self;
  }

  // FIXME: The logic below is confusing at best. Upon initial inspection, it's
  // unclear why `book.state` needs to be "fixed" in this initializer. If said
  // fixing is appropriate, a rationale should be added here.

  // If the book availability indicates that the book is held, make sure the state
  // reflects that.
  __block BOOL actuallyOnHold = NO;
  [book.defaultAcquisition.availability
   matchUnavailable:nil
   limited:nil
   unlimited:nil
   reserved:^(__unused TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved) {
     self.state = TPPBookStateHolding;
     actuallyOnHold = YES;
   } ready:^(__unused TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready) {
     self.state = TPPBookStateHolding;
     actuallyOnHold = YES;
   }];

  if (!actuallyOnHold) {
    // Set the correct non-holding state.
    if (self.state == TPPBookStateHolding || self.state == TPPBookStateUnsupported)
    {
      // Since we're not in some download-related state and we're not unregistered,
      // we must need to be downloaded.
      self.state = TPPBookStateDownloadNeeded;
    }
  }
  
  return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary
{
  self = [super init];
  if(!self) return nil;
  
  self.book = [[TPPBook alloc] initWithDictionary:dictionary[BookKey]];
  if(![self.book isKindOfClass:[TPPBook class]]) return nil;
  
  self.location = [[TPPBookLocation alloc]
                   initWithDictionary:TPPNullToNil(dictionary[TPPBookmarkDictionaryRepresentation.locationKey])];
  if(self.location && ![self.location isKindOfClass:[TPPBookLocation class]]) return nil;
  
  NSNumber *state = [TPPBookStateHelper bookStateFromString:dictionary[StateKey]];
  if (state) {
    self.state = state.integerValue;
  } else {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeUnknownBookState
                              summary:@"Invalid nil state during BookRegistryRecord init"
                             metadata:@{
                               @"Input dict": dictionary ?: @"N/A"
                             }];
    @throw NSInvalidArgumentException;
  }
  
  self.fulfillmentId = TPPNullToNil(dictionary[FulfillmentIdKey]);
  
  NSMutableArray<TPPReadiumBookmark *> *readiumBookmarks = [NSMutableArray array];
  for (NSDictionary *dict in TPPNullToNil(dictionary[ReadiumBookmarksKey])) {
    [readiumBookmarks addObject:[[TPPReadiumBookmark alloc] initWithDictionary:dict]];
  }
  self.readiumBookmarks = readiumBookmarks;

  NSMutableArray<TPPBookLocation *> *genericBookmarks = [NSMutableArray array];
  for (NSDictionary *dict in TPPNullToNil(dictionary[GenericBookmarksKey])) {
    [genericBookmarks addObject:[[TPPBookLocation alloc] initWithDictionary:dict]];
  }
  self.genericBookmarks = genericBookmarks;
  
  return self;
}

- (NSDictionary *)dictionaryRepresentation
{
  NSMutableArray *readiumBookmarks = [NSMutableArray array];
  for (TPPReadiumBookmark *readiumBookmark in self.readiumBookmarks) {
    [readiumBookmarks addObject:readiumBookmark.dictionaryRepresentation];
  }

  NSMutableArray *genericBookmarks = [NSMutableArray array];
  for (TPPBookLocation *genericBookmark in self.genericBookmarks) {
    [genericBookmarks addObject:genericBookmark.dictionaryRepresentation];
  }
  
  return @{BookKey: [self.book dictionaryRepresentation],
           TPPBookmarkDictionaryRepresentation.locationKey: TPPNullFromNil([self.location dictionaryRepresentation]),
           StateKey: [TPPBookStateHelper stringValueFromBookState:self.state],
           FulfillmentIdKey: TPPNullFromNil(self.fulfillmentId),
           ReadiumBookmarksKey: TPPNullFromNil(readiumBookmarks),
           GenericBookmarksKey: TPPNullFromNil(genericBookmarks)};
}

- (instancetype)recordWithBook:(TPPBook *const)book
{
  return [[[self class] alloc] initWithBook:book location:self.location state:self.state fulfillmentId:self.fulfillmentId readiumBookmarks:self.readiumBookmarks genericBookmarks:self.genericBookmarks];
}

- (instancetype)recordWithLocation:(TPPBookLocation *const)location
{
  return [[[self class] alloc] initWithBook:self.book location:location state:self.state fulfillmentId:self.fulfillmentId readiumBookmarks:self.readiumBookmarks genericBookmarks:self.genericBookmarks];
}

- (instancetype)recordWithState:(TPPBookState const)state
{
  return [[[self class] alloc] initWithBook:self.book location:self.location state:state fulfillmentId:self.fulfillmentId readiumBookmarks:self.readiumBookmarks genericBookmarks:self.genericBookmarks];
}

- (instancetype)recordWithFulfillmentId:(NSString *)fulfillmentId
{
  return [[[self class] alloc] initWithBook:self.book location:self.location state:self.state fulfillmentId:fulfillmentId readiumBookmarks:self.readiumBookmarks genericBookmarks:self.genericBookmarks];
}
  
- (instancetype)recordWithReadiumBookmarks:(NSArray<TPPReadiumBookmark *> *)bookmarks
{
  return [[[self class] alloc] initWithBook:self.book location:self.location state:self.state fulfillmentId:self.fulfillmentId readiumBookmarks:bookmarks genericBookmarks:self.genericBookmarks];
}

- (instancetype)recordWithGenericBookmarks:(NSArray<TPPBookLocation *> *)bookmarks
{
  return [[[self class] alloc] initWithBook:self.book location:self.location state:self.state fulfillmentId:self.fulfillmentId readiumBookmarks:self.readiumBookmarks genericBookmarks:bookmarks];
}
  
@end

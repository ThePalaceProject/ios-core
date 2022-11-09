#import "TPPAsync.h"

#import "TPPCatalogFacet.h"
#import "TPPCatalogFacetGroup.h"
#import "TPPOPDS.h"
#import "TPPOpenSearchDescription.h"
#import "TPPConfiguration.h"
#import "Palace-Swift.h"

#import "TPPCatalogUngroupedFeed.h"

@interface TPPCatalogUngroupedFeed ()

@property (nonatomic) BOOL currentlyFetchingNextURL;
@property (nonatomic) NSMutableArray *books;
@property (nonatomic) NSArray *facetGroups;
@property (nonatomic) NSUInteger greatestPreparationIndex;
@property (nonatomic) NSURL *nextURL;
@property (nonatomic) NSURL *openSearchURL;
@property (nonatomic) NSArray<TPPCatalogFacet *> *entryPoints;


@end

// If fewer than this many books are currently available when |prepareForBookIndex:| is called, an
// attempt to fetch more books will be made.
static NSUInteger const preloadThreshold = 100;

@implementation TPPCatalogUngroupedFeed

+ (void)withURL:(NSURL *)URL
handler:(void (^)(TPPCatalogUngroupedFeed *category))handler
{
  if(!handler) {
    @throw NSInvalidArgumentException;
  }
  
  [TPPOPDSFeed
   withURL:URL
   shouldResetCache:NO
   completionHandler:^(TPPOPDSFeed *const ungroupedFeed, __unused NSDictionary *error) {
     if(!ungroupedFeed) {
       handler(nil);
       return;
     }
     
    if(ungroupedFeed.type != TPPOPDSFeedTypeAcquisitionUngrouped) {
       TPPLOG(@"Ignoring feed of invalid type.");
       handler(nil);
       return;
     }
     
     handler([[self alloc] initWithOPDSFeed:ungroupedFeed]);
   }];
}

- (instancetype)initWithOPDSFeed:(TPPOPDSFeed *const)feed
{
  self = [super init];
  if(!self) return nil;
  
  if(feed.type != TPPOPDSFeedTypeAcquisitionUngrouped) {
    @throw NSInvalidArgumentException;
  }

  self.books = [NSMutableArray array];

  for(TPPOPDSEntry *const entry in feed.entries) {
    TPPBook *book = [[TPPBook alloc] initWithEntry: entry];
    if(!book) {
      TPPLOG(@"Failed to create book from entry.");
      continue;
    }

    if(!book.defaultAcquisition) {
      // The application is not able to support this, so we ignore it.
      continue;
    }

    TPPBook *updatedBook = [[TPPBookRegistry shared] updatedBookMetadata:book];
    if(updatedBook) {
      book = updatedBook;
    }

    // Do not display unsupported titles in feed
    // https://www.notion.so/lyrasis/App-crashes-after-getting-the-book-iPhone8-742898f53e2547efa4c6f5d43296b816
    if (book.defaultBookContentType != TPPBookContentTypeUnsupported) {
      [self.books addObject:book];
    }
  }

  NSMutableArray *const entryPointFacets = [NSMutableArray array];
  NSMutableArray *const facetGroupNames = [NSMutableArray array];
  NSMutableDictionary *const facetGroupNamesToMutableFacetArrays =
    [NSMutableDictionary dictionary];
  
  for(TPPOPDSLink *const link in feed.links) {
    if([link.rel isEqualToString:TPPOPDSRelationFacet]) {

      NSString *groupName = nil;
      TPPCatalogFacet *facet = nil;
      for(NSString *const key in link.attributes) {
        if(TPPOPDSAttributeKeyStringIsFacetGroupType(key)) {
          facet = [TPPCatalogFacet catalogFacetWithLink:link];
          if (facet) {
            [entryPointFacets addObject:facet];
          } else {
            TPPLOG(@"Entrypoint Facet could not be created.");
          }
          break;
        } else if(TPPOPDSAttributeKeyStringIsFacetGroup(key)) {
          groupName = link.attributes[key];
          continue;
        }
      }

      if (facet) {
        continue;
      }
      if(!groupName) {
        TPPLOG(@"Ignoring facet without group due to UI limitations.");
        continue;
      }

      facet = [TPPCatalogFacet catalogFacetWithLink:link];
      if(!facet) {
        TPPLOG(@"Ignoring invalid facet link.");
        continue;
      }

      if(![facetGroupNames containsObject:groupName]) {
        [facetGroupNames addObject:groupName];
        facetGroupNamesToMutableFacetArrays[groupName] = [NSMutableArray arrayWithCapacity:2];
      }
      [facetGroupNamesToMutableFacetArrays[groupName] addObject:facet];
      continue;
    }

    if([link.rel isEqualToString:TPPOPDSRelationPaginationNext]) {
      self.nextURL = link.href;
      continue;
    }
    
    if([link.rel isEqualToString:TPPOPDSRelationSearch] &&
       TPPOPDSTypeStringIsOpenSearchDescription(link.type)) {
      self.openSearchURL = link.href;
      continue;
    }
  }
  
  // Care is taken to preserve facet and facet group order from the original feed.
  NSMutableArray *const facetGroups = [NSMutableArray arrayWithCapacity:facetGroupNames.count];
  for(NSString *const facetGroupName in facetGroupNames) {
    [facetGroups addObject:[[TPPCatalogFacetGroup alloc]
                            initWithFacets:facetGroupNamesToMutableFacetArrays[facetGroupName]
                            name:facetGroupName]];
  }
  
  self.facetGroups = facetGroups;
  self.entryPoints = entryPointFacets;
  
  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(refreshBooks)
   name:NSNotification.TPPBookRegistryDidChange
   object:nil];

  return self;
}

- (void)prepareForBookIndex:(NSUInteger)bookIndex
{
  if(bookIndex >= self.books.count) {
    @throw NSInvalidArgumentException;
  }
  
  if(bookIndex < self.greatestPreparationIndex) {
    return;
  }
  
  self.greatestPreparationIndex = bookIndex;
  
  if(self.currentlyFetchingNextURL) return;
  
  if(!self.nextURL) return;
  
  if(self.books.count - bookIndex > preloadThreshold) {
    return;
  }
  
  self.currentlyFetchingNextURL = YES;
  
  NSUInteger const location = self.books.count;
  
  [TPPCatalogUngroupedFeed
   withURL:self.nextURL
   handler:^(TPPCatalogUngroupedFeed *const ungroupedFeed) {
     [[NSOperationQueue mainQueue] addOperationWithBlock:^{
       if(!ungroupedFeed) {
         TPPLOG(@"Failed to fetch next page.");
         self.currentlyFetchingNextURL = NO;
         return;
       }
       
       [self.books addObjectsFromArray:ungroupedFeed.books];
       self.nextURL = ungroupedFeed.nextURL;
       self.currentlyFetchingNextURL = NO;
       
       [self prepareForBookIndex:self.greatestPreparationIndex];
       
       NSRange const range = {.location = location, .length = ungroupedFeed.books.count};
       
       [self.delegate catalogUngroupedFeed:self
                               didAddBooks:ungroupedFeed.books
                                     range:range];
     }];
   }];
}

- (void)refreshBooks
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    NSMutableArray *const refreshedBooks = [NSMutableArray arrayWithCapacity:self.books.count];
    
    for(TPPBook *const book in self.books) {
      TPPBook *const refreshedBook = [[TPPBookRegistry shared]
                                       bookForIdentifier:book.identifier];
      if(refreshedBook) {
        [refreshedBooks addObject:refreshedBook];
      } else {
        [refreshedBooks addObject:book];
      }
    }
    
    self.books = refreshedBooks;
    
    [self.delegate catalogUngroupedFeed:self didUpdateBooks:self.books];
  }];
}

#pragma mark NSObject

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

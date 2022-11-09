#import "TPPAsync.h"

#import "TPPCatalogLane.h"
#import "TPPNull.h"
#import "TPPOPDS.h"
#import "TPPOpenSearchDescription.h"
#import "TPPXML.h"

#import "TPPConfiguration.h"
#import "TPPCatalogFacet.h"
#import "Palace-Swift.h"

#import "TPPCatalogGroupedFeed.h"

@interface TPPCatalogGroupedFeed ()

@property (nonatomic) NSArray *lanes;
@property (nonatomic) NSURL *openSearchURL;
@property (nonatomic) NSString *title;
@property (nonatomic) NSArray<TPPCatalogFacet *> *entryPoints;


@end

@implementation TPPCatalogGroupedFeed

- (instancetype)initWithOPDSFeed:(TPPOPDSFeed *)feed
{
  if(feed.type != TPPOPDSFeedTypeAcquisitionGrouped) {
    @throw NSInvalidArgumentException;
  }
  
  Account *currentAccount = [[AccountsManager sharedInstance] currentAccount];

  NSURL *openSearchURL = nil;
  NSMutableArray *const entryPointFacets = [NSMutableArray array];
  
  for(TPPOPDSLink *const link in feed.links) {

    if([link.rel isEqualToString:TPPOPDSRelationFacet]) {
      for(NSString *const key in link.attributes) {
        if(TPPOPDSAttributeKeyStringIsFacetGroupType(key)) {
          TPPCatalogFacet *facet = [TPPCatalogFacet catalogFacetWithLink:link];
          if (facet) {
            [entryPointFacets addObject:facet];
          } else {
            TPPLOG(@"Entrypoint Facet could not be created.");
          }
          continue;
        }
      }
    }

    if([link.rel isEqualToString:TPPOPDSRelationSearch] &&
       TPPOPDSTypeStringIsOpenSearchDescription(link.type)) {
      openSearchURL = link.href;
      continue;
    }
    else if ([link.rel isEqualToString:TPPOPDSEULALink]) {
      NSURL *href = link.href;
      [currentAccount.details setURL:href forLicense:URLTypeEula];
      continue;
    }
    else if ([link.rel isEqualToString:TPPOPDSPrivacyPolicyLink]) {
      NSURL *href = link.href;
      [currentAccount.details setURL:href forLicense:URLTypePrivacyPolicy];
      continue;
    }
    else if ([link.rel isEqualToString:TPPOPDSAcknowledgmentsLink]) {
      NSURL *href = link.href;
      [currentAccount.details setURL:href forLicense:URLTypeAcknowledgements];
      continue;
    }
    else if ([link.rel isEqualToString:TPPOPDSContentLicenseLink]) {
      NSURL *href = link.href;
      [currentAccount.details setURL:href forLicense:URLTypeContentLicenses];
      continue;
    }
    else if ([link.rel isEqualToString:TPPOPDSRelationAnnotations]) {
      NSURL *href = link.href;
      [currentAccount.details setURL:href forLicense:URLTypeAnnotations];
      continue;
    }
  }

  self.entryPoints = entryPointFacets;
  
  // This holds group titles in order, without duplicates.
  NSMutableArray *const groupTitles = [NSMutableArray array];
  
  NSMutableDictionary *const groupTitleToMutableBookArray = [NSMutableDictionary dictionary];
  NSMutableDictionary *const groupTitleToURLOrNull = [NSMutableDictionary dictionary];
  
  for(TPPOPDSEntry *const entry in feed.entries) {
    if(!entry.groupAttributes) {
      TPPLOG(@"Ignoring entry with missing group.");
      continue;
    }
    
    NSString *const groupTitle = entry.groupAttributes.title;
    
    TPPBook *book = [[TPPBook alloc] initWithEntry:entry];
    if(!book) {
      TPPLOG_F(@"Failed to create book from entry: %@",entry.title);
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
    
    NSMutableArray *const bookArray = groupTitleToMutableBookArray[groupTitle];
    
    // Do not display unsupported titles in feed
    // https://www.notion.so/lyrasis/App-crashes-after-getting-the-book-iPhone8-742898f53e2547efa4c6f5d43296b816
    if (book.defaultBookContentType != TPPBookContentTypeUnsupported) {
      if(bookArray) {
        // We previously found a book in this group, so we can just add one more.
        [bookArray addObject:book];
      } else {
        // This is the first book we've found in this group, so we need to do a few things.
        [groupTitles addObject:groupTitle];
        groupTitleToMutableBookArray[groupTitle] = [NSMutableArray arrayWithObject:book];
        groupTitleToURLOrNull[groupTitle] = TPPNullFromNil(entry.groupAttributes.href);
      }
    }
  }
  
  NSMutableArray *const lanes = [NSMutableArray array];
  
  for(NSString *const groupTitle in groupTitles) {
    [lanes addObject:[[TPPCatalogLane alloc]
                      initWithBooks:groupTitleToMutableBookArray[groupTitle]
                      subsectionURL:TPPNullToNil(groupTitleToURLOrNull[groupTitle])
                      title:groupTitle]];
  }
  
  return [self initWithLanes:lanes
               openSearchURL:openSearchURL
                       title:feed.title];
}

- (instancetype)initWithLanes:(NSArray *const)lanes
                openSearchURL:(NSURL *const)openSearchURL
                        title:(NSString *const)title
{
  self = [super init];
  if(!self) return nil;
  
  if(!lanes) {
    @throw NSInvalidArgumentException;
  }
  
  for(id const object in lanes) {
    if(![object isKindOfClass:[TPPCatalogLane class]]) {
      @throw NSInvalidArgumentException;
    }
  }
  
  self.lanes = lanes;
  self.openSearchURL = openSearchURL;
  self.title = title;
  
  return self;
}

@end

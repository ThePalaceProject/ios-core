#import "TPPOPDS.h"
#import "Palace-Swift.h"

#import "TPPCatalogFacet.h"

@interface TPPCatalogFacet ()

@property (nonatomic) BOOL active;
@property (nonatomic) NSURL *href;
@property (nonatomic) NSString *title;

@end

@implementation TPPCatalogFacet

+ (TPPCatalogFacet *)catalogFacetWithLink:(TPPOPDSLink *const)link
{
  if(![link.rel isEqualToString:TPPOPDSRelationFacet]) {
    TPPLOG(@"Failing to construct facet with incorrect relation.");
    return nil;
  }
  
  BOOL active = NO;
  
  for(NSString *const key in link.attributes) {
    if(TPPOPDSAttributeKeyStringIsActiveFacet(key)) {
      active = [link.attributes[key] rangeOfString:@"true"
                                           options:NSCaseInsensitiveSearch].location != NSNotFound;
      continue;
    }
  }

  return [[self alloc] initWithActive:active href:link.href title:link.title];
}

- (instancetype)initWithActive:(BOOL const)active
                          href:(NSURL *const)href
                         title:(NSString *const)title
{
  self = [super init];
  if(!self) return nil;

  if(!href) {
    @throw NSInvalidArgumentException;
  }
  
  self.active = active;
  self.href = href;
  self.title = title;
  
  return self;
}

@end

#import "NSDate+NYPLDateAdditions.h"
#import "TPPOPDSAcquisition.h"
#import "TPPOPDSCategory.h"
#import "TPPOPDSEntryGroupAttributes.h"
#import "TPPOPDSLink.h"
#import "TPPOPDSRelation.h"
#import "TPPXML.h"
#import "Palace-Swift.h"

#import "TPPOPDSEntry.h"

@interface TPPOPDSEntry ()

@property (nonatomic) NSArray<TPPOPDSAcquisition *> *acquisitions;
@property (nonatomic) NSString *alternativeHeadline;
@property (nonatomic) NSArray *authorStrings;
@property (nonatomic) NSArray<TPPOPDSLink *> *authorLinks;
@property (nonatomic) TPPOPDSLink *seriesLink;
@property (nonatomic) NSArray<TPPOPDSCategory *> *categories;
@property (nonatomic) NSString *identifier;
@property (nonatomic) NSArray *links;
@property (nonatomic) TPPOPDSLink *annotations;
@property (nonatomic) TPPOPDSLink *alternate;
@property (nonatomic) TPPOPDSLink *relatedWorks;
@property (nonatomic) TPPOPDSAcquisition *previewLink;
@property (nonatomic) NSURL *analytics;
@property (nonatomic) NSString *providerName;
@property (nonatomic) NSDate *published;
@property (nonatomic) NSString *publisher;
@property (nonatomic) NSString *summary;
@property (nonatomic) NSString *title;
@property (nonatomic) NSDate *updated;
@property (nonatomic) NSDictionary<NSString *, NSArray<NSString *>*> *contributors;
@property (nonatomic) TPPOPDSLink *timeTrackingLink;
@property (nonatomic) NSString *duration;

@end

@implementation TPPOPDSEntry

- (instancetype)initWithXML:(TPPXML *const)entryXML
{
  self = [super init];
  if (!self) return nil;
  
  self.alternativeHeadline = [entryXML firstChildWithName:@"alternativeHeadline"].value;
  
  [self parseAuthorsFromXML:entryXML];
  [self parseContributorsFromXML:entryXML];
  [self parseCategoriesFromXML:entryXML];
  
  if (![self parseIdentifierFromXML:entryXML]) return nil;
  
  [self parseLinksFromXML:entryXML];
  
  self.providerName = [entryXML firstChildWithName:@"distribution"].attributes[@"bibframe:ProviderName"];
  
  NSString *dateString = [entryXML firstChildWithName:@"issued"].value;
  if (dateString) {
    self.published = [NSDate dateWithISO8601DateString:dateString];
  }
  
  self.publisher = [entryXML firstChildWithName:@"publisher"].value;
  self.summary = [[entryXML firstChildWithName:@"summary"].value stringByDecodingHTMLEntities];
  
  if (![self parseTitleFromXML:entryXML]) return nil;
  if (![self parseUpdatedDateFromXML:entryXML]) return nil;
  [self parseSeriesFromXML:entryXML];
  
  return self;
}

- (void)parseAuthorsFromXML:(TPPXML *const)entryXML {
  NSMutableArray *authorStrings = [NSMutableArray array];
  NSMutableArray<TPPOPDSLink *> *authorLinks = [NSMutableArray array];
  
  TPPXML *durationXML = [[entryXML childrenWithName:@"duration"] firstObject];
  if (durationXML) {
    self.duration = durationXML.value;
  }
  
  for (TPPXML *authorXML in [entryXML childrenWithName:@"author"]) {
    TPPXML *nameXML = [authorXML firstChildWithName:@"name"];
    if (!nameXML) {
      TPPLOG(@"'author' element missing required 'name' element. Ignoring malformed 'author' element.");
      continue;
    }
    [authorStrings addObject:nameXML.value];
    
    TPPXML *authorLinkXML = [authorXML firstChildWithName:@"link"];
    TPPOPDSLink *link = [[TPPOPDSLink alloc] initWithXML:authorLinkXML];
    if (!link) {
      TPPLOG(@"Ignoring malformed 'link' element for author.");
    } else if ([link.rel isEqualToString:@"contributor"]) {
      [authorLinks addObject:link];
    }
  }
  
  self.authorStrings = authorStrings;
  self.authorLinks = [authorLinks copy];
}

- (void)parseContributorsFromXML:(TPPXML *const)entryXML {
  NSMutableDictionary<NSString *, NSMutableArray<NSString *>*> *contributors = [NSMutableDictionary dictionary];
  
  for (TPPXML *contributorNode in [entryXML childrenWithName:@"contributor"]) {
    NSString *contributorRole = contributorNode.attributes[@"opf:role"];
    NSString *contributorName = [[contributorNode firstChildWithName:@"name"].value stringByDecodingHTMLEntities];
    if (contributorName) {
      if (!contributors[contributorRole]) {
        contributors[contributorRole] = [NSMutableArray array];
      }
      [contributors[contributorRole] addObject:contributorName];
    }
  }
  
  if (contributors.count > 0) {
    self.contributors = contributors;
  }
}

- (void)parseCategoriesFromXML:(TPPXML *const)entryXML {
  NSMutableArray<TPPOPDSCategory *> *categories = [NSMutableArray array];
  
  for (TPPXML *categoryXML in [entryXML childrenWithName:@"category"]) {
    NSString *term = categoryXML.attributes[@"term"];
    if (!term) {
      TPPLOG(@"Category missing required 'term'.");
      continue;
    }
    NSString *schemeString = categoryXML.attributes[@"scheme"];
    NSURL *scheme = schemeString ? [NSURL URLWithString:schemeString] : nil;
    TPPOPDSCategory *category = [TPPOPDSCategory categoryWithTerm:term label:categoryXML.attributes[@"label"] scheme:scheme];
    [categories addObject:category];
  }
  
  self.categories = [categories copy];
}

- (BOOL)parseIdentifierFromXML:(TPPXML *const)entryXML {
  self.identifier = [entryXML firstChildWithName:@"id"].value;
  if (!self.identifier) {
    TPPLOG(@"Missing required 'id' element.");
    return NO;
  }
  return YES;
}

- (void)parseLinksFromXML:(TPPXML *const)entryXML {
  NSMutableArray *mutableLinks = [NSMutableArray array];
  NSMutableArray<TPPOPDSAcquisition *> *mutableAcquisitions = [NSMutableArray array];
  
  for (TPPXML *linkXML in [entryXML childrenWithName:@"link"]) {
    if ([linkXML.attributes[@"rel"] containsString:TPPOPDSRelationAcquisition]) {
      TPPOPDSAcquisition *acquisition = [TPPOPDSAcquisition acquisitionWithLinkXML:linkXML];
      if (acquisition) {
        [mutableAcquisitions addObject:acquisition];
        continue;
      }
    } else if ([linkXML.attributes[@"rel"] containsString:TPPOPDSRelationPreview]) {
      TPPOPDSAcquisition *acquisition = [TPPOPDSAcquisition acquisitionWithLinkXML:linkXML];
      if (acquisition) {
        NSString *mimeType = acquisition.type;
        BOOL isEpubPreview = [mimeType isEqualToString:@"application/epub+zip"];
        BOOL isPalaceMarketplace = [self.providerName isEqualToString:@"Palace Marketplace"];
        
        if (isPalaceMarketplace) {
          if (isEpubPreview) {
            if (!self.previewLink) {
              self.previewLink = acquisition;
            }
          }
        } else {
          if (!self.previewLink) {
            self.previewLink = acquisition;
          }
        }
      }
    }
    
    TPPOPDSLink *link = [[TPPOPDSLink alloc] initWithXML:linkXML];
    if (!link) {
      TPPLOG(@"Ignoring malformed 'link' element.");
      continue;
    }
    
    if ([link.rel isEqualToString:@"http://www.w3.org/ns/oa#annotationService"]) {
      self.annotations = link;
    } else if ([link.rel isEqualToString:@"alternate"]) {
      self.alternate = link;
      self.analytics = [NSURL URLWithString:[link.href.absoluteString stringByReplacingOccurrencesOfString:@"/works/" withString:@"/analytics/"]];
    } else if ([link.rel isEqualToString:@"related"]) {
      self.relatedWorks = link;
    } else if ([link.rel isEqualToString:TPPOPDSRelationTimeTrackingLink]) {
      self.timeTrackingLink = link;
    } else {
      [mutableLinks addObject:link];
    }
  }
  
  self.acquisitions = [mutableAcquisitions copy];
  self.links = [mutableLinks copy];
}

- (BOOL)parseTitleFromXML:(TPPXML *const)entryXML {
  self.title = [entryXML firstChildWithName:@"title"].value;
  if (!self.title) {
    TPPLOG(@"Missing required 'title' element.");
    return NO;
  }
  return YES;
}

- (BOOL)parseUpdatedDateFromXML:(TPPXML *const)entryXML {
  NSString *updatedString = [entryXML firstChildWithName:@"updated"].value;
  if (!updatedString) {
    TPPLOG(@"Missing required 'updated' element.");
    return NO;
  }
  
  self.updated = [NSDate dateWithRFC3339String:updatedString];
  if (!self.updated) {
    TPPLOG(@"Element 'updated' does not contain an RFC 3339 date.");
    return NO;
  }
  return YES;
}

- (void)parseSeriesFromXML:(TPPXML *const)entryXML {
  TPPXML *seriesXML = [entryXML firstChildWithName:@"Series"];
  TPPXML *linkXML = [seriesXML firstChildWithName:@"link"];
  if (linkXML) {
    self.seriesLink = [[TPPOPDSLink alloc] initWithXML:linkXML];
    if (!self.seriesLink) {
      TPPLOG(@"Ignoring malformed 'link' element for schema:Series.");
    }
  }
}

- (TPPOPDSEntryGroupAttributes *)groupAttributes
{
  for(TPPOPDSLink *const link in self.links) {
    if([link.rel isEqualToString:TPPOPDSRelationGroup]) {
      NSString *const title = link.attributes[@"title"];
      if(!title) {
        TPPLOG(@"Ignoring group link without required 'title' attribute.");
        continue;
      }
      return [[TPPOPDSEntryGroupAttributes alloc]
              initWithHref:[NSURL URLWithString:link.attributes[@"href"]]
              title:title];
    }
  }
  
  return nil;
}

@end

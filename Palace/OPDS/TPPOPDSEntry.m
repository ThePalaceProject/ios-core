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
  if(!self) return nil;

  self.alternativeHeadline = [entryXML firstChildWithName:@"alternativeHeadline"].value;
  
  {
    NSMutableArray *const authorStrings = [NSMutableArray array];
    NSMutableArray<TPPOPDSLink *> const *authorLinks = [NSMutableArray array];
    
    if ([[entryXML childrenWithName:@"duration"] count] > 0) {
      TPPXML *durationXML = [[entryXML childrenWithName:@"duration"] firstObject];
      self.duration = durationXML.value;
    }
    
    for(TPPXML *const authorXML in [entryXML childrenWithName:@"author"]) {
      TPPXML *const nameXML = [authorXML firstChildWithName:@"name"];
      if(!nameXML) {
        TPPLOG(@"'author' element missing required 'name' element. Ignoring malformed 'author' element.");
        continue;
      }
      [authorStrings addObject:nameXML.value];
      
      TPPXML *const authorLinkXML = [authorXML firstChildWithName:@"link"];
      TPPOPDSLink *const link = [[TPPOPDSLink alloc] initWithXML:authorLinkXML];
      if(!link) {
        TPPLOG(@"Ignoring malformed 'link' element for author.");
      } else if ([link.rel isEqualToString:@"contributor"]) {
        [authorLinks addObject:link];
      }
    }

    self.authorStrings = authorStrings;
    self.authorLinks = [authorLinks copy];
  }
  
  // Contributors and their roles
  {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *>*> *contributors  = [NSMutableDictionary dictionary];
    for(TPPXML *contributorNode in [entryXML childrenWithName:@"contributor"]) {
      NSString *contributorRole = contributorNode.attributes[@"opf:role"];
      NSString *contributorName = [[contributorNode firstChildWithName:@"name"].value stringByDecodingHTMLEntities];
      if (contributorName) {
        if (!contributors[contributorRole]) {
          contributors[contributorRole] = [NSMutableArray array];
        }
        [contributors[contributorRole] addObject:contributorName];
      }
    }
    if ([contributors count] > 0) {
      self.contributors = contributors;
    }
  }
  
  {
    NSMutableArray<TPPOPDSCategory *> const *categories = [NSMutableArray array];
    
    for(TPPXML *const categoryXML in [entryXML childrenWithName:@"category"]) {
      NSString *const term = categoryXML.attributes[@"term"];
      if(!term) {
        TPPLOG(@"Category missing required 'term'.");
        continue;
      }
      NSString *const schemeString = categoryXML.attributes[@"scheme"];
      NSURL *const scheme = schemeString ? [NSURL URLWithString:schemeString] : nil;
      [categories addObject:[TPPOPDSCategory
                             categoryWithTerm:term
                             label:categoryXML.attributes[@"label"]
                             scheme:scheme]];
    }
    
    self.categories = [categories copy];
  }
  
  if(!((self.identifier = [entryXML firstChildWithName:@"id"].value))) {
    TPPLOG(@"Missing required 'id' element.");
    return nil;
  }
  
  {
    NSMutableArray *const mutableLinks = [NSMutableArray array];
    NSMutableArray<TPPOPDSAcquisition *> *const mutableAcquisitions = [NSMutableArray array];
    
    for (TPPXML *const linkXML in [entryXML childrenWithName:@"link"]) {
      
      // Try parsing the link as an acquisition first to avoid creating an NYPLOPDSLink
      // for no reason.
      if ([[linkXML attributes][@"rel"] containsString:TPPOPDSRelationAcquisition]) {
        TPPOPDSAcquisition *const acquisition = [TPPOPDSAcquisition acquisitionWithLinkXML:linkXML];
        if (acquisition) {
          [mutableAcquisitions addObject:acquisition];
          continue;
        }
      } else if ([[linkXML attributes][@"rel"] containsString: TPPOPDSRelationPreview]) {
        // Try parsing the link as a preview
        TPPOPDSAcquisition *const acquisition = [TPPOPDSAcquisition acquisitionWithLinkXML:linkXML];
        if (acquisition) {
          self.previewLink = acquisition;
        }
      }
      
      // It may sometimes bet the case that `!acquisition` if the acquisition used a
      // non-standard relation. As such, we do not log an error here and let things
      // continue so the link can be added to `self.links`.
      
      TPPOPDSLink *const link = [[TPPOPDSLink alloc] initWithXML:linkXML];
      if(!link) {
        TPPLOG(@"Ignoring malformed 'link' element.");
        continue;
      }
            
      if ([link.rel isEqualToString:@"http://www.w3.org/ns/oa#annotationService"]){
        self.annotations = link;
      } else if ([link.rel isEqualToString:@"alternate"]){
        self.alternate = link;
        self.analytics = [NSURL URLWithString:[link.href.absoluteString stringByReplacingOccurrencesOfString:@"/works/" withString:@"/analytics/"]];
      } else if ([link.rel isEqualToString:@"related"]){
        self.relatedWorks = link;
      } else if ([link.rel isEqualToString:TPPOPDSRelationTimeTrackingLink]) {
        // The app should track and report audiobook playback time if this link is present
        self.timeTrackingLink = link;
      }  else {
        [mutableLinks addObject:link];
      }
    }
    
    self.acquisitions = [mutableAcquisitions copy];
    self.links = [mutableLinks copy];
  }
  
  self.providerName = [entryXML firstChildWithName:@"distribution"].attributes[@"bibframe:ProviderName"];
  
  {
    NSString *const dateString = [entryXML firstChildWithName:@"issued"].value;
    if(dateString) {
      self.published = [NSDate dateWithISO8601DateString:dateString];
    }
  }
  
  self.publisher = [entryXML firstChildWithName:@"publisher"].value;
  
  self.summary = [entryXML firstChildWithName:@"summary"].value;
  
  if(!((self.title = [entryXML firstChildWithName:@"title"].value))) {
    TPPLOG(@"Missing required 'title' element.");
    return nil;
  }
  
  {
    NSString *const updatedString = [entryXML firstChildWithName:@"updated"].value;
    if(!updatedString) {
      TPPLOG(@"Missing required 'updated' element.");
      return nil;
    }
    
    self.updated = [NSDate dateWithRFC3339String:updatedString];
    if(!self.updated) {
      TPPLOG(@"Element 'updated' does not contain an RFC 3339 date.");
      return nil;
    }
  }

  {
    TPPXML *const seriesXML = [entryXML firstChildWithName:@"Series"];
    TPPXML *const linkXML = [seriesXML firstChildWithName:@"link"];
    if (linkXML) {
      self.seriesLink = [[TPPOPDSLink alloc] initWithXML:linkXML];
      if (!self.seriesLink) {
        TPPLOG(@"Ignoring malformed 'link' element for schema:Series.");
      }
    }
  }
  
  return self;
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

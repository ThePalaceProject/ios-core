#import "NSDate+NYPLDateAdditions.h"
#import "TPPNull.h"
#import "TPPOPDS.h"
#import "TPPConfiguration.h"
#import "Palace-Swift.h"

#import "TPPBook.h"

@interface TPPBook ()

@property (nonatomic) NSArray<TPPOPDSAcquisition *> *acquisitions;
@property (nonatomic) NSArray<TPPBookAuthor *> *bookAuthors;
@property (nonatomic) NSArray *categoryStrings;
@property (nonatomic) NSString *distributor;
@property (nonatomic) NSString *identifier;
@property (nonatomic) NSURL *imageURL;
@property (nonatomic) NSURL *imageThumbnailURL;
@property (nonatomic) NSDate *published;
@property (nonatomic) NSString *publisher;
@property (nonatomic) NSString *subtitle;
@property (nonatomic) NSString *summary;
@property (nonatomic) NSString *title;
@property (nonatomic) NSDate *updated;
@property (nonatomic) NSURL *annotationsURL;
@property (nonatomic) NSURL *analyticsURL;
@property (nonatomic) NSURL *alternateURL;
@property (nonatomic) NSURL *relatedWorksURL;
@property (nonatomic) NSURL *seriesURL;
@property (nonatomic) NSURL *revokeURL;
@property (nonatomic) NSURL *reportURL;
@property (nonatomic) NSDictionary *contributors;

- (nonnull instancetype)initWithAcquisitions:(nonnull NSArray<TPPOPDSAcquisition *> *)acquisitions
                                 bookAuthors:(nullable NSArray<TPPBookAuthor *> *)authors
                             categoryStrings:(nullable NSArray *)categoryStrings
                                 distributor:(nullable NSString *)distributor
                                  identifier:(nonnull NSString *)identifier
                                    imageURL:(nullable NSURL *)imageURL
                           imageThumbnailURL:(nullable NSURL *)imageThumbnailURL
                                   published:(nullable NSDate *)published
                                   publisher:(nullable NSString *)publisher
                                    subtitle:(nullable NSString *)subtitle
                                     summary:(nullable NSString *)summary
                                       title:(nonnull NSString *)title
                                     updated:(nonnull NSDate *)updated
                              annotationsURL:(nullable NSURL *) annotationsURL
                                analyticsURL:(nullable NSURL *)analyticsURL
                                alternateURL:(nullable NSURL *)alternateURL
                             relatedWorksURL:(nullable NSURL *)relatedWorksURL
                                   seriesURL:(nullable NSURL *)seriesURL
                                   revokeURL:(nullable NSURL *)revokeURL
                                   reportURL:(nullable NSURL *)reportURL
                                contributors:(nullable NSDictionary *)contributors
NS_DESIGNATED_INITIALIZER;

@end

// NOTE: Be cautious of these values!
// Do NOT reuse them when declaring new keys.
static NSString *const DeprecatedAcquisitionKey = @"acquisition";
static NSString *const DeprecatedAvailableCopiesKey = @"available-copies";
static NSString *const DeprecatedAvailableUntilKey = @"available-until";
static NSString *const DeprecatedAvailabilityStatusKey = @"availability-status";
static NSString *const DeprecatedHoldsPositionKey = @"holds-position";
static NSString *const DeprecatedTotalCopiesKey = @"total-copies";

static NSString *const AcquisitionsKey = @"acquisitions";
static NSString *const AlternateURLKey = @"alternate";
static NSString *const AnalyticsURLKey = @"analytics";
static NSString *const AnnotationsURLKey = @"annotations";
static NSString *const AuthorLinksKey = @"author-links";
static NSString *const AuthorsKey = @"authors";
static NSString *const CategoriesKey = @"categories";
static NSString *const DistributorKey = @"distributor";
static NSString *const IdentifierKey = @"id";
static NSString *const ImageThumbnailURLKey = @"image-thumbnail";
static NSString *const ImageURLKey = @"image";
static NSString *const PublishedKey = @"published";
static NSString *const PublisherKey = @"publisher";
static NSString *const RelatedURLKey = @"related-works-url";
static NSString *const ReportURLKey = @"report-url";
static NSString *const RevokeURLKey = @"revoke-url";
static NSString *const SeriesLinkKey = @"series-link";
static NSString *const SubtitleKey = @"subtitle";
static NSString *const SummaryKey = @"summary";
static NSString *const TitleKey = @"title";
static NSString *const UpdatedKey = @"updated";

@implementation TPPBook

+ (NSArray<NSString *> *)categoryStringsFromCategories:(NSArray<TPPOPDSCategory *> *const)categories
{
  NSMutableArray<NSString *> *const categoryStrings = [NSMutableArray array];
  
  for(TPPOPDSCategory *const category in categories) {
    if(!category.scheme
       || [category.scheme isEqual:[NSURL URLWithString:@"http://librarysimplified.org/terms/genres/Simplified/"]])
    {
      [categoryStrings addObject:(category.label ? category.label : category.term)];
    }
  }
  
  return [categoryStrings copy];
}

+ (instancetype)bookWithEntry:(TPPOPDSEntry *const)entry
{
  if(!entry) {
    TPPLOG(@"Failed to create book from nil entry.");
    return nil;
  }
  
  NSURL *revoke, *image, *imageThumbnail, *report = nil;

  NSMutableArray<TPPBookAuthor *> *authors = [[NSMutableArray alloc] init];
  for (int i = 0; i < (int)entry.authorStrings.count; i++) {
    if ((int)entry.authorLinks.count > i) {
      [authors addObject:[[TPPBookAuthor alloc] initWithAuthorName:entry.authorStrings[i]
                                                   relatedBooksURL:entry.authorLinks[i].href]];
    } else {
      [authors addObject:[[TPPBookAuthor alloc] initWithAuthorName:entry.authorStrings[i]
                                                   relatedBooksURL:nil]];
    }
  }

  for(TPPOPDSLink *const link in entry.links) {
    if([link.rel isEqualToString:TPPOPDSRelationAcquisitionRevoke]) {
      revoke = link.href;
      continue;
    }
    if([link.rel isEqualToString:TPPOPDSRelationImage]) {
      image = link.href;
      continue;
    }
    if([link.rel isEqualToString:TPPOPDSRelationImageThumbnail]) {
      imageThumbnail = link.href;
      continue;
    }
    if([link.rel isEqualToString:TPPOPDSRelationAcquisitionIssues]) {
      report = link.href;
      continue;
    }
  }
  
  return [[self alloc]
          initWithAcquisitions:entry.acquisitions
          bookAuthors:authors
          categoryStrings:[[self class] categoryStringsFromCategories:entry.categories]
          distributor:entry.providerName
          identifier:entry.identifier
          imageURL:image
          imageThumbnailURL:imageThumbnail
          published:entry.published
          publisher:entry.publisher
          subtitle:entry.alternativeHeadline
          summary:entry.summary
          title:entry.title
          updated:entry.updated
          annotationsURL:entry.annotations.href
          analyticsURL:entry.analytics
          alternateURL:entry.alternate.href
          relatedWorksURL:entry.relatedWorks.href
          seriesURL:entry.seriesLink.href
          revokeURL:revoke
          reportURL:report
          contributors:entry.contributors
  ];
}

- (instancetype)bookWithMetadataFromBook:(TPPBook *)book
{
  return [[TPPBook alloc]
          initWithAcquisitions:self.acquisitions
          bookAuthors:book.bookAuthors
          categoryStrings:book.categoryStrings
          distributor:book.distributor
          identifier:self.identifier
          imageURL:book.imageURL
          imageThumbnailURL:book.imageThumbnailURL
          published:book.published
          publisher:book.publisher
          subtitle:book.subtitle
          summary:book.summary
          title:book.title
          updated:book.updated
          annotationsURL:book.annotationsURL
          analyticsURL:book.analyticsURL
          alternateURL:book.alternateURL
          relatedWorksURL:book.relatedWorksURL
          seriesURL:book.seriesURL
          revokeURL:self.revokeURL
          reportURL:self.reportURL
          contributors:book.contributors
  ];
}

- (instancetype)initWithAcquisitions:(NSArray<TPPOPDSAcquisition *> *)acquisitions
                         bookAuthors:(NSArray<TPPBookAuthor *> *)authors
                     categoryStrings:(NSArray *)categoryStrings
                         distributor:(NSString *)distributor
                          identifier:(NSString *)identifier
                            imageURL:(NSURL *)imageURL
                   imageThumbnailURL:(NSURL *)imageThumbnailURL
                           published:(NSDate *)published
                           publisher:(NSString *)publisher
                            subtitle:(NSString *)subtitle
                             summary:(NSString *)summary
                               title:(NSString *)title
                             updated:(NSDate *)updated
                      annotationsURL:(NSURL *)annotationsURL
                        analyticsURL:(NSURL *)analyticsURL
                        alternateURL:(NSURL *)alternateURL
                     relatedWorksURL:(NSURL *)relatedWorksURL
                           seriesURL:(NSURL *)seriesURL
                           revokeURL:(NSURL *)revokeURL
                           reportURL:(NSURL *)reportURL
                        contributors:(NSDictionary *)contributors
{
  self = [super init];
  if(!self) return nil;
  
  if(!(acquisitions && identifier && title && updated)) {
    @throw NSInvalidArgumentException;
  }
  
  self.acquisitions = acquisitions;
  self.alternateURL = alternateURL;
  self.annotationsURL = annotationsURL;
  self.analyticsURL = analyticsURL;
  self.bookAuthors = authors;
  self.categoryStrings = categoryStrings;
  self.distributor = distributor;
  self.identifier = identifier;
  self.imageURL = imageURL;
  self.imageThumbnailURL = imageThumbnailURL;
  self.published = published;
  self.publisher = publisher;
  self.relatedWorksURL = relatedWorksURL;
  self.seriesURL = seriesURL;
  self.subtitle = subtitle;
  self.summary = summary;
  self.title = title;
  self.updated = updated;
  self.revokeURL = revokeURL;
  self.reportURL = reportURL;
  self.contributors = contributors;
  
  return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary
{
  self = [super init];
  if(!self) return nil;

  // This is not present in older versions of serialized books.
  NSArray *const acquisitionsArray = dictionary[AcquisitionsKey];
  if (acquisitionsArray) {
    assert([acquisitionsArray isKindOfClass:[NSArray class]]);

    NSMutableArray<TPPOPDSAcquisition *> *const mutableAcqusitions =
      [NSMutableArray arrayWithCapacity:acquisitionsArray.count];

    for (NSDictionary *const acquisitionDictionary in acquisitionsArray) {
      assert([acquisitionDictionary isKindOfClass:[NSDictionary class]]);

      TPPOPDSAcquisition *const acquisition = [TPPOPDSAcquisition acquisitionWithDictionary:acquisitionDictionary];
      assert(acquisition);

      [mutableAcqusitions addObject:acquisition];
    }

    self.acquisitions = [mutableAcqusitions copy];
  }

  // This is not present in older versions of serialized books.
  NSString *const revokeString = TPPNullToNil(dictionary[RevokeURLKey]);
  self.revokeURL = revokeString ? [NSURL URLWithString:revokeString] : nil;

  // This is not present in older versions of serialized books.
  NSString *const reportString = TPPNullToNil(dictionary[ReportURLKey]);
  self.reportURL = reportString ? [NSURL URLWithString:reportString] : nil;

  // If present, migrate old acquistion data to the new format.
  // This handles data originally serialized from an `NYPLBookAcquisition`.
  if (dictionary[DeprecatedAcquisitionKey]) {
    // Old-format acqusitions previously held all of these. As such, if we have an old-format
    // acquisition, none of these should have been successfully set above.
    assert(!self.acquisitions);
    assert(!self.revokeURL);
    assert(!self.reportURL);

    NSString *const revokeString = TPPNullToNil(dictionary[DeprecatedAcquisitionKey][@"revoke"]);
    self.revokeURL = revokeString ? [NSURL URLWithString:revokeString] : nil;

    NSString *const reportString = TPPNullToNil(dictionary[DeprecatedAcquisitionKey][@"report"]);
    self.reportURL = reportString ? [NSURL URLWithString:reportString] : nil;

    NSString *const availabilityStatus = TPPNullToNil(dictionary[DeprecatedAvailabilityStatusKey]);

    NSString *const holdsPositionString = TPPNullToNil(dictionary[DeprecatedHoldsPositionKey]);
    NSInteger const holdsPosition = holdsPositionString ? [holdsPositionString integerValue] : NSNotFound;

    NSString *const availableCopiesString = TPPNullToNil(dictionary[DeprecatedAvailableCopiesKey]);
    NSInteger const availableCopies = availableCopiesString ? [availableCopiesString integerValue] : NSNotFound;

    NSString *const totalCopiesString = TPPNullToNil(dictionary[DeprecatedTotalCopiesKey]);
    NSInteger const totalCopies = totalCopiesString ? [totalCopiesString integerValue] : NSNotFound;

    NSString *const untilString = TPPNullToNil(dictionary[DeprecatedAvailableUntilKey]);
    NSDate *const until = untilString ? [NSDate dateWithRFC3339String:untilString] : nil;

    // This information is not available so we default to the until date.
    NSDate *const since = until;

    // Default to unlimited availability if we cannot deduce anything more specific.
    id<TPPOPDSAcquisitionAvailability> availability = [[TPPOPDSAcquisitionAvailabilityUnlimited alloc] init];

    if ([availabilityStatus isEqual:@"available"]) {
      if (availableCopies == NSNotFound) {
        // Use the default unlimited availability.
      } else {
        availability = [[TPPOPDSAcquisitionAvailabilityLimited alloc]
                        initWithCopiesAvailable:availableCopies
                        copiesTotal:totalCopies
                        since:since
                        until:until];
      }
    } else if ([availabilityStatus isEqual:@"unavailable"]) {
      // Unfortunately, no record of copies already on hold is present. As such,
      // we default to `totalCopies` (which assumes one hold for every copy
      // available, i.e. demand doubling supply).
      availability = [[TPPOPDSAcquisitionAvailabilityUnavailable alloc]
                      initWithCopiesHeld:totalCopies
                      copiesTotal:totalCopies];
    } else if ([availabilityStatus isEqual:@"reserved"]) {
      availability = [[TPPOPDSAcquisitionAvailabilityReserved alloc]
                      initWithHoldPosition:holdsPosition
                      copiesTotal:totalCopies
                      since:since
                      until:until];
    } else if ([availabilityStatus isEqual:@"ready"]) {
      availability = [[TPPOPDSAcquisitionAvailabilityReady alloc] initWithSince:since until:until];
    }

    NSMutableArray<TPPOPDSAcquisition *> *const mutableAcquisitions = [NSMutableArray array];

    NSString *const applicationEPUBZIP = ContentTypeEpubZip;

    NSString *const genericString = TPPNullToNil(dictionary[DeprecatedAcquisitionKey][@"generic"]);
    NSURL *const genericURL = genericString ? [NSURL URLWithString:genericString] : nil;
    if (genericURL) {
      [mutableAcquisitions addObject:
       [TPPOPDSAcquisition
        acquisitionWithRelation:TPPOPDSAcquisitionRelationGeneric
        type:applicationEPUBZIP
        hrefURL:genericURL
        indirectAcquisitions:@[]
        availability:availability]];
    }

    NSString *const borrowString = TPPNullToNil(dictionary[DeprecatedAcquisitionKey][@"borrow"]);
    NSURL *const borrowURL = borrowString ? [NSURL URLWithString:borrowString] : nil;
    if (borrowURL) {
      [mutableAcquisitions addObject:
       [TPPOPDSAcquisition
        acquisitionWithRelation:TPPOPDSAcquisitionRelationBorrow
        type:applicationEPUBZIP
        hrefURL:borrowURL
        indirectAcquisitions:@[]
        availability:availability]];
    }

    NSString *const openAccessString = TPPNullToNil(dictionary[DeprecatedAcquisitionKey][@"open-access"]);
    NSURL *const openAccessURL = openAccessString ? [NSURL URLWithString:openAccessString] : nil;
    if (openAccessURL) {
      [mutableAcquisitions addObject:
       [TPPOPDSAcquisition
        acquisitionWithRelation:TPPOPDSAcquisitionRelationOpenAccess
        type:applicationEPUBZIP
        hrefURL:openAccessURL
        indirectAcquisitions:@[]
        availability:availability]];
    }

    NSString *const sampleString = TPPNullToNil(dictionary[DeprecatedAcquisitionKey][@"sample"]);
    NSURL *const sampleURL = sampleString ? [NSURL URLWithString:sampleString] : nil;
    if (sampleURL) {
      [mutableAcquisitions addObject:
       [TPPOPDSAcquisition
        acquisitionWithRelation:TPPOPDSAcquisitionRelationSample
        type:applicationEPUBZIP
        hrefURL:sampleURL
        indirectAcquisitions:@[]
        availability:availability]];
    }

    self.acquisitions = [mutableAcquisitions copy];
  }
  
  NSString *const alternate = TPPNullToNil(dictionary[AlternateURLKey]);
  self.alternateURL = alternate ? [NSURL URLWithString:alternate] : nil;
  
  NSString *const analytics = TPPNullToNil(dictionary[AnalyticsURLKey]);
  self.analyticsURL = analytics ? [NSURL URLWithString:analytics] : nil;
  
  NSString *const annotations = TPPNullToNil(dictionary[AnnotationsURLKey]);
  self.annotationsURL = annotations ? [NSURL URLWithString:annotations] : nil;

  NSMutableArray<TPPBookAuthor *> *authors = [[NSMutableArray alloc] init];
  NSArray *authorStrings = dictionary[AuthorsKey];
  NSArray *authorLinks = dictionary[AuthorLinksKey];

  if (authorStrings && authorLinks) {
    for (int i = 0; i < (int)authorStrings.count; i++) {
      if ((int)authorLinks.count > i) {
        NSURL *url = [NSURL URLWithString:authorLinks[i]];
        [authors addObject:[[TPPBookAuthor alloc] initWithAuthorName:authorStrings[i]
                                                      relatedBooksURL:url]];
      } else {
        [authors addObject:[[TPPBookAuthor alloc] initWithAuthorName:authorStrings[i]
                                                      relatedBooksURL:nil]];
      }
    }
  } else if (authorStrings) {
    for (int i = 0; i < (int)authorStrings.count; i++) {
      [authors addObject:[[TPPBookAuthor alloc] initWithAuthorName:authorStrings[i]
                                                    relatedBooksURL:nil]];
    }
  } else {
    self.bookAuthors = nil;
  }
  self.bookAuthors = authors;

  self.categoryStrings = dictionary[CategoriesKey];
  if(!self.categoryStrings) return nil;
  
  self.distributor = TPPNullToNil(dictionary[DistributorKey]);
  
  self.identifier = dictionary[IdentifierKey];
  if(!self.identifier) return nil;
  
  NSString *const image = TPPNullToNil(dictionary[ImageURLKey]);
  self.imageURL = image ? [NSURL URLWithString:image] : nil;
  
  NSString *const imageThumbnail = TPPNullToNil(dictionary[ImageThumbnailURLKey]);
  self.imageThumbnailURL = imageThumbnail ? [NSURL URLWithString:imageThumbnail] : nil;
  
  NSString *const dateString = TPPNullToNil(dictionary[PublishedKey]);
  self.published = dateString ? [NSDate dateWithRFC3339String:dateString] : nil;
  
  self.publisher = TPPNullToNil(dictionary[PublisherKey]);
  
  NSString *const relatedWorksString = TPPNullToNil(dictionary[RelatedURLKey]);
  self.relatedWorksURL = relatedWorksString ? [NSURL URLWithString:relatedWorksString] : nil;
  
  NSString *const seriesString = TPPNullToNil(dictionary[SeriesLinkKey]);
  self.seriesURL = seriesString ? [NSURL URLWithString:seriesString] : nil;
  
  self.subtitle = TPPNullToNil(dictionary[SubtitleKey]);
  
  self.summary = TPPNullToNil(dictionary[SummaryKey]);
  
  self.title = dictionary[TitleKey];
  if(!self.title) return nil;
  
  self.updated = [NSDate dateWithRFC3339String:dictionary[UpdatedKey]];
  if(!self.updated) return nil;
  
  return self;
}

- (NSDictionary *)dictionaryRepresentation
{
  NSMutableArray *const mutableAcquisitionDictionaryArray = [NSMutableArray arrayWithCapacity:self.acquisitions.count];

  for (TPPOPDSAcquisition *const acquisition in self.acquisitions) {
    [mutableAcquisitionDictionaryArray addObject:[acquisition dictionaryRepresentation]];
  }

  return @{AcquisitionsKey:[mutableAcquisitionDictionaryArray copy],
           AlternateURLKey: TPPNullFromNil([self.alternateURL absoluteString]),
           AnnotationsURLKey: TPPNullFromNil([self.annotationsURL absoluteString]),
           AnalyticsURLKey: TPPNullFromNil([self.analyticsURL absoluteString]),
           AuthorLinksKey: [self authorLinkArray],
           AuthorsKey: [self authorNameArray],
           CategoriesKey: self.categoryStrings,
           DistributorKey: TPPNullFromNil(self.distributor),
           IdentifierKey: self.identifier,
           ImageURLKey: TPPNullFromNil([self.imageURL absoluteString]),
           ImageThumbnailURLKey: TPPNullFromNil([self.imageThumbnailURL absoluteString]),
           PublishedKey: TPPNullFromNil([self.published RFC3339String]),
           PublisherKey: TPPNullFromNil(self.publisher),
           RelatedURLKey: TPPNullFromNil([self.relatedWorksURL absoluteString]),
           ReportURLKey: TPPNullFromNil([self.reportURL absoluteString]),
           RevokeURLKey: TPPNullFromNil([self.revokeURL absoluteString]),
           SeriesLinkKey: TPPNullFromNil([self.seriesURL absoluteString]),
           SubtitleKey: TPPNullFromNil(self.subtitle),
           SummaryKey: TPPNullFromNil(self.summary),
           TitleKey: self.title,
           UpdatedKey: [self.updated RFC3339String]
          };
}

- (NSArray *)authorNameArray {
  NSMutableArray *array = [[NSMutableArray alloc] init];
  for (TPPBookAuthor *auth in self.bookAuthors) {
    if (auth.name) {
      [array addObject:auth.name];
    }
  }
  return array;
}

- (NSArray *)authorLinkArray {
  NSMutableArray *array = [[NSMutableArray alloc] init];
  for (TPPBookAuthor *auth in self.bookAuthors) {
    if (auth.relatedBooksURL.absoluteString) {
      [array addObject:auth.relatedBooksURL.absoluteString];
    }
  }
  return array;
}

- (NSString *)authors
{
  NSMutableArray *authorsArray = [[NSMutableArray alloc] init];
  for (TPPBookAuthor *author in self.bookAuthors) {
    [authorsArray addObject:author.name];
  }
  return [authorsArray componentsJoinedByString:@"; "];
}

- (NSString *)categories
{
  return [self.categoryStrings componentsJoinedByString:@"; "];
}

- (NSString *)narrators {
  return [self.contributors[@"nrt"] componentsJoinedByString:@"; "];
}

- (TPPOPDSAcquisition *)defaultAcquisition
{
  if (self.acquisitions.count == 0) {
    TPPLOG(@"ERROR: No acquisitions found when computing a default. This is an OPDS violation.");
    return nil;
  }

  for (TPPOPDSAcquisition *const acquisition in self.acquisitions) {
    NSArray *const paths = [TPPOPDSAcquisitionPath
                            supportedAcquisitionPathsForAllowedTypes:[TPPOPDSAcquisitionPath supportedTypes]
                            allowedRelations:NYPLOPDSAcquisitionRelationSetAll
                            acquisitions:@[acquisition]];

    if (paths.count >= 1) {
      return acquisition;
    }
  }

  return nil;
}

- (TPPOPDSAcquisition *)defaultAcquisitionIfBorrow
{
  TPPOPDSAcquisition *const acquisition = [self defaultAcquisition];

  return acquisition.relation == TPPOPDSAcquisitionRelationBorrow ? acquisition : nil;
}

- (TPPOPDSAcquisition *)defaultAcquisitionIfOpenAccess
{
  TPPOPDSAcquisition *const acquisition = [self defaultAcquisition];

  return acquisition.relation == TPPOPDSAcquisitionRelationOpenAccess ? acquisition : nil;
}

- (TPPBookContentType)defaultBookContentType
{
  TPPOPDSAcquisition *acquisition = [self defaultAcquisition];
  if (!acquisition) {
    // Avoid crashing by attempting to put nil in an array below
    return TPPBookContentTypeUnsupported;
  }
  
  NSArray<TPPOPDSAcquisitionPath *> *const paths =
  [TPPOPDSAcquisitionPath
   supportedAcquisitionPathsForAllowedTypes:[TPPOPDSAcquisitionPath supportedTypes]
   allowedRelations:NYPLOPDSAcquisitionRelationSetAll
   acquisitions:@[acquisition]];

  TPPBookContentType defaultType = TPPBookContentTypeUnsupported;
  for (TPPOPDSAcquisitionPath *const path in paths) {
    NSString *finalTypeString = path.types.lastObject;
    TPPBookContentType const contentType = TPPBookContentTypeFromMIMEType(finalTypeString);
    
    // Prefer EPUB, because we have the best support for them
    if (contentType == TPPBookContentTypeEPUB) {
      defaultType = contentType;
      break;
    }
    
    // Assign the first supported type, to fall back on if EPUB isn't an option
    if (defaultType == TPPBookContentTypeUnsupported) {
      defaultType = contentType;
    }
  }
  
  return defaultType;
}

@end

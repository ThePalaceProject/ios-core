#import "TPPOPDSAcquisition.h"

#import "TPPOPDSAcquisitionAvailability.h"
#import "TPPOPDSIndirectAcquisition.h"
#import "TPPXML.h"
#import "Palace-Swift.h"

static NSString *const borrowRelationString = @"http://opds-spec.org/acquisition/borrow";
static NSString *const buyRelationString = @"http://opds-spec.org/acquisition/buy";
static NSString *const genericRelationString = @"http://opds-spec.org/acquisition";
static NSString *const openAccessRelationString = @"http://opds-spec.org/acquisition/open-access";
static NSString *const sampleRelationString = @"http://opds-spec.org/acquisition/sample";
static NSString *const subscribeRelationString = @"http://opds-spec.org/acquisition/subscribe";
static NSString *const previewRelationString = @"preview";

static NSString *const availabilityKey = @"availability";
static NSString *const hrefURLKey = @"href";
static NSString *const indirectAcquisitionsKey = @"indirectAcqusitions";
static NSString *const relationKey = @"rel";
static NSString *const typeKey = @"type";

static NSString *const indirectAcquisitionName = @"indirectAcquisition";

static NSString *const relAttribute = @"rel";
static NSString *const typeAttribute = @"type";
static NSString *const hrefAttribute = @"href";

static NSUInteger const numberOfRelations = 6;

TPPOPDSAcquisitionRelationSet const NYPLOPDSAcquisitionRelationSetAll = (1 << (numberOfRelations)) - 1;

TPPOPDSAcquisitionRelationSet const TPPOPDSAcquisitionRelationSetDefaultAcquisition =
  NYPLOPDSAcquisitionRelationSetAll ^ TPPOPDSAcquisitionRelationSetSample;

TPPOPDSAcquisitionRelationSet
NYPLOPDSAcquisitionRelationSetWithRelation(TPPOPDSAcquisitionRelation relation)
{
  switch (relation) {
    case TPPOPDSAcquisitionRelationBuy:
      return TPPOPDSAcquisitionRelationSetBuy;
    case TPPOPDSAcquisitionRelationBorrow:
      return TPPOPDSAcquisitionRelationSetBorrow;
    case TPPOPDSAcquisitionRelationSample:
      return TPPOPDSAcquisitionRelationSetSample;
    case TPPOPDSAcquisitionRelationPreview:
      return TPPOPDSAcquisitionRelationSetPreview;
    case TPPOPDSAcquisitionRelationGeneric:
      return TPPOPDSAcquisitionRelationSetGeneric;
    case TPPOPDSAcquisitionRelationSubscribe:
      return TPPOPDSAcquisitionRelationSetSubscribe;
    case TPPOPDSAcquisitionRelationOpenAccess:
      return TPPOPDSAcquisitionRelationSetOpenAccess;
  }
}

BOOL
NYPLOPDSAcquisitionRelationSetContainsRelation(TPPOPDSAcquisitionRelationSet relationSet,
                                               TPPOPDSAcquisitionRelation relation)
{
  return NYPLOPDSAcquisitionRelationSetWithRelation(relation) & relationSet;
}

BOOL
NYPLOPDSAcquisitionRelationWithString(NSString *const _Nonnull string,
                                      TPPOPDSAcquisitionRelation *const _Nonnull relationPointer)
{
  static NSDictionary<NSString *, NSNumber *> *lazyStringToRelationObjectDict = nil;

  if (lazyStringToRelationObjectDict == nil) {
    lazyStringToRelationObjectDict = @{
      genericRelationString: @(TPPOPDSAcquisitionRelationGeneric),
      openAccessRelationString: @(TPPOPDSAcquisitionRelationOpenAccess),
      borrowRelationString: @(TPPOPDSAcquisitionRelationBorrow),
      buyRelationString: @(TPPOPDSAcquisitionRelationBuy),
      sampleRelationString: @(TPPOPDSAcquisitionRelationSample),
      previewRelationString: @(TPPOPDSAcquisitionRelationPreview),
      subscribeRelationString: @(TPPOPDSAcquisitionRelationSubscribe)
    };
  }

  NSNumber *const relationObject = lazyStringToRelationObjectDict[string];
  if (!relationObject) {
    return NO;
  }

  *relationPointer = relationObject.integerValue;

  return YES;
}

NSString *_Nonnull
NYPLOPDSAcquisitionRelationString(TPPOPDSAcquisitionRelation const relation)
{
  switch (relation) {
    case TPPOPDSAcquisitionRelationGeneric:
      return genericRelationString;
    case TPPOPDSAcquisitionRelationOpenAccess:
      return openAccessRelationString;
    case TPPOPDSAcquisitionRelationBorrow:
      return borrowRelationString;
    case TPPOPDSAcquisitionRelationBuy:
      return buyRelationString;
    case TPPOPDSAcquisitionRelationSample:
      return sampleRelationString;
    case TPPOPDSAcquisitionRelationPreview:
      return previewRelationString;
    case TPPOPDSAcquisitionRelationSubscribe:
      return subscribeRelationString;
  }
}

@interface TPPOPDSAcquisition ()

@property TPPOPDSAcquisitionRelation relation;
@property (nonatomic, copy, nonnull) NSString *type;
@property (nonatomic, nonnull) NSURL *hrefURL;
@property (nonatomic, nonnull) NSArray<TPPOPDSIndirectAcquisition *> *indirectAcquisitions;
@property (nonatomic, nonnull) id<TPPOPDSAcquisitionAvailability> availability;

@end

@implementation TPPOPDSAcquisition

+ (_Nonnull instancetype)
acquisitionWithRelation:(TPPOPDSAcquisitionRelation const)relation
type:(NSString *const _Nonnull)type
hrefURL:(NSURL *const _Nonnull)hrefURL
indirectAcquisitions:(NSArray<TPPOPDSIndirectAcquisition *> *const _Nonnull)indirectAcqusitions
availability:(id<TPPOPDSAcquisitionAvailability> const _Nonnull)availability
{
  return [[self alloc] initWithRelation:relation
                                   type:type
                                hrefURL:hrefURL
                   indirectAcquisitions:indirectAcqusitions
                           availability:availability];
}

+ (_Nullable instancetype)acquisitionWithLinkXML:(TPPXML *const _Nonnull)linkXML
{
  NSString *const relationString = [linkXML attributes][relAttribute];
  if (!relationString) {
    return nil;
  }

  TPPOPDSAcquisitionRelation relation;
  if (!NYPLOPDSAcquisitionRelationWithString(relationString, &relation)) {
    return nil;
  }

  NSString *const type = [linkXML attributes][typeAttribute];
  if (!type) {
    return nil;
  }

  NSString *const hrefString = [linkXML attributes][hrefAttribute];
  if (!hrefString) {
    return nil;
  }

  NSURL *const hrefURL = [NSURL URLWithString:hrefString];
  if (!hrefURL) {
    return nil;
  }

  NSMutableArray<TPPOPDSIndirectAcquisition *> *const mutableIndirectAcquisitions = [NSMutableArray array];
  for (TPPXML *const indirectAcquisitionXML in [linkXML childrenWithName:indirectAcquisitionName]) {
    TPPOPDSIndirectAcquisition *const indirectAcquisition =
      [TPPOPDSIndirectAcquisition indirectAcquisitionWithXML:indirectAcquisitionXML];

    if (indirectAcquisition) {
      [mutableIndirectAcquisitions addObject:indirectAcquisition];
    } else {
      TPPLOG(@"Ignoring invalid indirect acquisition.");
    }
  }

  return [self acquisitionWithRelation:relation
                                  type:type
                               hrefURL:hrefURL
                  indirectAcquisitions:[mutableIndirectAcquisitions copy]
                          availability:NYPLOPDSAcquisitionAvailabilityWithLinkXML(linkXML)];
}

- (_Nonnull instancetype)initWithRelation:(TPPOPDSAcquisitionRelation const)relation
                                     type:(NSString *const _Nonnull)type
                                  hrefURL:(NSURL *const _Nonnull)hrefURL
                     indirectAcquisitions:(NSArray<TPPOPDSIndirectAcquisition *> *const _Nonnull)indirectAcqusitions
                             availability:(id<TPPOPDSAcquisitionAvailability> const _Nonnull)availability
{
  self = [super init];

  self.relation = relation;
  self.type = type;
  self.hrefURL = hrefURL;
  self.indirectAcquisitions = indirectAcqusitions;
  self.availability = availability;

  return self;
}

+ (_Nullable instancetype)acquisitionWithDictionary:(NSDictionary *const _Nonnull)dictionary
{
  NSString *const relationString = dictionary[relationKey];
  if (![relationString isKindOfClass:[NSString class]]) {
    return nil;
  }

  TPPOPDSAcquisitionRelation relation;
  if (!NYPLOPDSAcquisitionRelationWithString(relationString, &relation)) {
    return nil;
  }

  NSString *const type = dictionary[typeKey];
  if (![type isKindOfClass:[NSString class]]) {
    return nil;
  }

  NSString *const hrefURLString = dictionary[hrefURLKey];
  if (![hrefURLString isKindOfClass:[NSString class]]) {
    return nil;
  }

  NSURL *const hrefURL = [NSURL URLWithString:hrefURLString];
  if (!hrefURL) {
    return nil;
  }

  NSDictionary *const indirectAcquisitionDictionaries = dictionary[indirectAcquisitionsKey];
  if (![indirectAcquisitionDictionaries isKindOfClass:[NSArray class]]) {
    return nil;
  }

  NSMutableArray *const mutableIndirectAcquisitions =
    [NSMutableArray arrayWithCapacity:indirectAcquisitionDictionaries.count];

  for (NSDictionary *const indirectAcquisitionDictionary in indirectAcquisitionDictionaries) {
    if (![indirectAcquisitionDictionary isKindOfClass:[NSDictionary class]]) {
      return nil;
    }

    TPPOPDSIndirectAcquisition *const indirectAcquisition =
      [TPPOPDSIndirectAcquisition indirectAcquisitionWithDictionary:indirectAcquisitionDictionary];
    if (!indirectAcquisition) {
      return nil;
    }

    [mutableIndirectAcquisitions addObject:indirectAcquisition];
  }

  NSDictionary *const availabilityDictionary = dictionary[availabilityKey];
  if (![availabilityDictionary isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  id<TPPOPDSAcquisitionAvailability> const availability =
    NYPLOPDSAcquisitionAvailabilityWithDictionary(availabilityDictionary);

  if (!availability) {
    return nil;
  }

  return [TPPOPDSAcquisition
          acquisitionWithRelation:relation
          type:type
          hrefURL:hrefURL
          indirectAcquisitions:[mutableIndirectAcquisitions copy]
          availability:availability];
}

- (NSDictionary *_Nonnull)dictionaryRepresentation
{
  NSMutableArray *const mutableIndirectAcquistionDictionaries =
    [NSMutableArray arrayWithCapacity:self.indirectAcquisitions.count];

  for (TPPOPDSIndirectAcquisition *const indirectAcqusition in self.indirectAcquisitions) {
    [mutableIndirectAcquistionDictionaries addObject:[indirectAcqusition dictionaryRepresentation]];
  }

  return @{
    relationKey: NYPLOPDSAcquisitionRelationString(self.relation),
    typeKey: self.type,
    hrefURLKey: self.hrefURL.absoluteString,
    indirectAcquisitionsKey: [mutableIndirectAcquistionDictionaries copy],
    availabilityKey: NYPLOPDSAcquisitionAvailabilityDictionaryRepresentation(self.availability)
  };
}

@end

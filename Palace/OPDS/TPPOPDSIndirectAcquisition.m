#import "TPPOPDSIndirectAcquisition.h"

#import "TPPXML.h"
#import "Palace-Swift.h"

#pragma mark Dictionary Keys

static NSString *const NYPLOPDSIndirectAcquisitionTypeKey = @"type";

static NSString *const NYPLOPDSIndirectAcquisitionIndirectAcqusitionsKey = @"indirectAcquisitions";

#pragma mark -

@interface TPPOPDSIndirectAcquisition ()

@property (nonatomic, copy, nonnull) NSString *type;
@property (nonatomic, nonnull) NSArray<TPPOPDSIndirectAcquisition *> *indirectAcquisitions;

@end

@implementation TPPOPDSIndirectAcquisition

+ (instancetype _Nonnull)
indirectAcquisitionWithType:(NSString *const _Nonnull)type
indirectAcquisitions:(NSArray<TPPOPDSIndirectAcquisition *> *const _Nonnull)indirectAcquisitions
{
  return [[self alloc] initWithType:type indirectAcquisitions:indirectAcquisitions];
}

+ (instancetype _Nullable)indirectAcquisitionWithXML:(TPPXML *const _Nonnull)xml
{
  NSString *const type = [xml attributes][@"type"];
  if (!type) {
    return nil;
  }

  NSMutableArray<TPPOPDSIndirectAcquisition *> *const mutableIndirectAcquisitions = [NSMutableArray array];
  for (TPPXML *const indirectAcquisitionXML in [xml childrenWithName:@"indirectAcquisition"]) {
    TPPOPDSIndirectAcquisition *const indirectAcquisition =
      [TPPOPDSIndirectAcquisition indirectAcquisitionWithXML:indirectAcquisitionXML];

    if (indirectAcquisition) {
      [mutableIndirectAcquisitions addObject:indirectAcquisition];
    } else {
      TPPLOG(@"Ignoring invalid indirect acquisition.");
    }
  }

  return [self indirectAcquisitionWithType:type
                      indirectAcquisitions:[mutableIndirectAcquisitions copy]];
}

- (instancetype _Nonnull)initWithType:(NSString *const _Nonnull)type
                 indirectAcquisitions:(NSArray<TPPOPDSIndirectAcquisition *> *const _Nonnull)indirectAcquisitions
{
  self = [super init];

  self.type = type;
  self.indirectAcquisitions = indirectAcquisitions;

  return self;
}

+ (_Nullable instancetype)indirectAcquisitionWithDictionary:(NSDictionary *const _Nonnull)dictionary
{
  NSString *const type = dictionary[NYPLOPDSIndirectAcquisitionTypeKey];
  if (![type isKindOfClass:[NSString class]]) {
    return nil;
  }

  NSDictionary *const indirectAcquisitionDictionaries = dictionary[NYPLOPDSIndirectAcquisitionIndirectAcqusitionsKey];
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

  return [self indirectAcquisitionWithType:type
                      indirectAcquisitions:[mutableIndirectAcquisitions copy]];
}

- (NSDictionary *_Nonnull)dictionaryRepresentation
{
  NSMutableArray *const mutableIndirectionAcqusitionDictionaries =
    [NSMutableArray arrayWithCapacity:self.indirectAcquisitions.count];

  for (TPPOPDSIndirectAcquisition *const indirectAcqusition in self.indirectAcquisitions) {
    [mutableIndirectionAcqusitionDictionaries addObject:[indirectAcqusition dictionaryRepresentation]];
  }

  return @{
    NYPLOPDSIndirectAcquisitionTypeKey: self.type,
    NYPLOPDSIndirectAcquisitionIndirectAcqusitionsKey: [mutableIndirectionAcqusitionDictionaries copy]
  };
}

@end

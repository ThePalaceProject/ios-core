#import "NSDate+NYPLDateAdditions.h"
#import "TPPNull.h"
#import "TPPXML.h"

#import "TPPOPDSAcquisitionAvailability.h"

static NSString *const caseKey = @"case";
static NSString *const copiesAvailableKey = @"copiesAvailable";
static NSString *const copiesHeldKey = @"copiesHeld";
static NSString *const copiesTotalKey = @"copiesTotal";
static NSString *const holdsPositionKey = @"holdsPosition";
static NSString *const reservedSinceKey = @"reservedSince";
static NSString *const reservedUntilKey = @"reservedUntil";
static NSString *const sinceKey = @"since";
static NSString *const untilKey = @"until";

static NSString *const limitedCase = @"limited";
static NSString *const readyCase = @"ready";
static NSString *const reservedCase = @"reserved";
static NSString *const unavailableCase = @"unavailable";
static NSString *const unlimitedCase = @"unlimited";

static NSString *const availabilityName = @"availability";
static NSString *const copiesName = @"copies";
static NSString *const holdsName = @"holds";

static NSString *const availableAttribute = @"available";
static NSString *const positionAttribute = @"position";
static NSString *const sinceAttribute = @"since";
static NSString *const statusAttribute = @"status";
static NSString *const totalAttribute = @"total";
static NSString *const untilAttribute = @"until";

TPPOPDSAcquisitionAvailabilityCopies const TPPOPDSAcquisitionAvailabilityCopiesUnknown = NSUIntegerMax;

@interface TPPOPDSAcquisitionAvailabilityUnavailable ()

@property (nonatomic) NSUInteger copiesHeld;
@property (nonatomic) NSUInteger copiesTotal;

@end

@interface TPPOPDSAcquisitionAvailabilityLimited ()

@property (nonatomic) TPPOPDSAcquisitionAvailabilityCopies copiesAvailable;
@property (nonatomic) TPPOPDSAcquisitionAvailabilityCopies copiesTotal;
@property (nonatomic, nullable) NSDate *since;
@property (nonatomic, nullable) NSDate *until;


@end

@interface TPPOPDSAcquisitionAvailabilityUnlimited ()

@end

@interface TPPOPDSAcquisitionAvailabilityReserved ()

@property (nonatomic) NSUInteger holdPosition;
@property (nonatomic) TPPOPDSAcquisitionAvailabilityCopies copiesTotal;
@property (nonatomic, nullable) NSDate *since;
@property (nonatomic, nullable) NSDate *until;

@end

@interface TPPOPDSAcquisitionAvailabilityReady ()
@property (nonatomic, nullable) NSDate *since;
@property (nonatomic, nullable) NSDate *until;
@end

id<TPPOPDSAcquisitionAvailability> _Nonnull
NYPLOPDSAcquisitionAvailabilityWithLinkXML(TPPXML *const _Nonnull linkXML)
{
  TPPOPDSAcquisitionAvailabilityCopies copiesHeld = TPPOPDSAcquisitionAvailabilityCopiesUnknown;
  TPPOPDSAcquisitionAvailabilityCopies copiesAvailable = TPPOPDSAcquisitionAvailabilityCopiesUnknown;
  TPPOPDSAcquisitionAvailabilityCopies copiesTotal = TPPOPDSAcquisitionAvailabilityCopiesUnknown;
  NSUInteger holdPosition = 0;

  NSString *const statusString = [linkXML firstChildWithName:availabilityName].attributes[statusAttribute];

  NSString *const holdsPositionString = [linkXML firstChildWithName:holdsName].attributes[positionAttribute];
  if (holdsPositionString) {
    // Guard against underflow from negatives.
    holdPosition = MAX(0, [holdsPositionString integerValue]);
  }

  NSString *const holdsTotalString = [linkXML firstChildWithName:holdsName].attributes[totalAttribute];
  if (holdsTotalString) {
    // Guard against underflow from negatives.
    copiesHeld = MAX(0, [holdsTotalString integerValue]);
  }

  NSString *const copiesAvailableString = [linkXML firstChildWithName:copiesName].attributes[availableAttribute];
  if (copiesAvailableString) {
    // Guard against underflow from negatives.
    copiesAvailable = MAX(0, [copiesAvailableString integerValue]);
  }

  NSString *const copiesTotalString = [linkXML firstChildWithName:copiesName].attributes[totalAttribute];
  if (copiesTotalString) {
    // Guard against underflow from negatives.
    copiesTotal = MAX(0, [copiesTotalString integerValue]);
  }

  NSString *const sinceString = [linkXML firstChildWithName:availabilityName].attributes[sinceAttribute];
  NSDate *const since = sinceString ? [NSDate dateWithRFC3339String:sinceString] : nil;
  
  NSString *const untilString = [linkXML firstChildWithName:availabilityName].attributes[untilAttribute];
  NSDate *const until = untilString ? [NSDate dateWithRFC3339String:untilString] : nil;

  if ([statusString isEqual:@"unavailable"]) {
    return [[TPPOPDSAcquisitionAvailabilityUnavailable alloc]
            initWithCopiesHeld:MIN(copiesHeld, copiesTotal)
            copiesTotal:MAX(copiesHeld, copiesTotal)];
  }

  if ([statusString isEqual:@"available"]) {
    if (copiesAvailable == TPPOPDSAcquisitionAvailabilityCopiesUnknown
        && copiesTotal == TPPOPDSAcquisitionAvailabilityCopiesUnknown)
    {
      return [[TPPOPDSAcquisitionAvailabilityUnlimited alloc] init];
    }

    return [[TPPOPDSAcquisitionAvailabilityLimited alloc]
            initWithCopiesAvailable:MIN(copiesAvailable, copiesTotal)
            copiesTotal:MAX(copiesAvailable, copiesTotal)
            since:since
            until:until];
  }

  if ([statusString isEqual:@"reserved"]) {
    return [[TPPOPDSAcquisitionAvailabilityReserved alloc]
            initWithHoldPosition:holdPosition
            copiesTotal:copiesTotal
            since:since
            until:until];
  }

  if ([statusString isEqualToString:@"ready"]) {
    return [[TPPOPDSAcquisitionAvailabilityReady alloc] initWithSince:since until:until];
  }

  return [[TPPOPDSAcquisitionAvailabilityUnlimited alloc] init];
}

id<TPPOPDSAcquisitionAvailability> _Nonnull
NYPLOPDSAcquisitionAvailabilityWithDictionary(NSDictionary *_Nonnull dictionary)
{
  NSString *const caseString = dictionary[caseKey];
  if (!caseString) {
    return nil;
  }

  NSString *const sinceString = TPPNullToNil(dictionary[sinceKey]);
  NSDate *const since = sinceString ? [NSDate dateWithRFC3339String:sinceString] : nil;

  NSString *const untilString = TPPNullToNil(dictionary[untilKey]);
  NSDate *const until = untilString ? [NSDate dateWithRFC3339String:untilString] : nil;

  if ([caseString isEqual:unavailableCase]) {
    NSNumber *const copiesHeldNumber = dictionary[copiesHeldKey];
    if (![copiesHeldNumber isKindOfClass:[NSNumber class]]) {
      return nil;
    }

    NSNumber *const copiesTotalNumber = dictionary[copiesTotalKey];
    if (![copiesTotalNumber isKindOfClass:[NSNumber class]]) {
      return nil;
    }

    return [[TPPOPDSAcquisitionAvailabilityUnavailable alloc]
            initWithCopiesHeld:MAX(0, MIN([copiesHeldNumber integerValue], [copiesTotalNumber integerValue]))
            copiesTotal:MAX(0, MAX([copiesHeldNumber integerValue], [copiesTotalNumber integerValue]))];
  } else if ([caseString isEqual:limitedCase]) {
    NSNumber *const copiesAvailableNumber = dictionary[copiesAvailableKey];
    if (![copiesAvailableNumber isKindOfClass:[NSNumber class]]) {
      return nil;
    }

    NSNumber *const copiesTotalNumber = dictionary[copiesTotalKey];
    if (![copiesTotalNumber isKindOfClass:[NSNumber class]]) {
      return nil;
    }

    return [[TPPOPDSAcquisitionAvailabilityLimited alloc]
            initWithCopiesAvailable:MAX(0, MIN([copiesAvailableNumber integerValue], [copiesTotalNumber integerValue]))
            copiesTotal:MAX(0, MAX([copiesAvailableNumber integerValue], [copiesTotalNumber integerValue]))
            since:since
            until:until];
  } else if ([caseString isEqual:unlimitedCase]) {
    return [[TPPOPDSAcquisitionAvailabilityUnlimited alloc] init];
  } else if ([caseString isEqual:reservedCase]) {
    NSNumber *const holdPositionNumber = dictionary[holdsPositionKey];
    if (![holdPositionNumber isKindOfClass:[NSNumber class]]) {
      return nil;
    }

    NSNumber *const copiesTotalNumber = dictionary[copiesTotalKey];
    if (![copiesTotalNumber isKindOfClass:[NSNumber class]]) {
      return nil;
    }

    return [[TPPOPDSAcquisitionAvailabilityReserved alloc]
            initWithHoldPosition:MAX(0, [holdPositionNumber integerValue])
            copiesTotal:MAX(0, [copiesTotalNumber integerValue])
            since:since
            until:until];
  } else if ([caseString isEqual:readyCase]) {
    return [[TPPOPDSAcquisitionAvailabilityReady alloc] initWithSince:since until:until];
  } else {
    return nil;
  }
}

NSDictionary *_Nonnull
NYPLOPDSAcquisitionAvailabilityDictionaryRepresentation(id<TPPOPDSAcquisitionAvailability> const _Nonnull availability)
{
  __block NSDictionary *result;

  [availability
   matchUnavailable:^(TPPOPDSAcquisitionAvailabilityUnavailable *const _Nonnull unavailable) {
     result = @{
       caseKey: unavailableCase,
       copiesHeldKey: @(unavailable.copiesHeld),
       copiesTotalKey: @(unavailable.copiesTotal)
     };
   } limited:^(TPPOPDSAcquisitionAvailabilityLimited *const _Nonnull limited) {
     result = @{
       caseKey: limitedCase,
       copiesAvailableKey: @(limited.copiesAvailable),
       copiesTotalKey: @(limited.copiesTotal),
       sinceKey: TPPNullFromNil([limited.since RFC3339String]),
       untilKey: TPPNullFromNil([limited.until RFC3339String])
     };
   } unlimited:^(__unused TPPOPDSAcquisitionAvailabilityUnlimited *const _Nonnull unlimited) {
     result = @{
       caseKey: unlimitedCase
     };
   } reserved:^(TPPOPDSAcquisitionAvailabilityReserved * _Nonnull reserved) {
     result = @{
       caseKey: reservedCase,
       holdsPositionKey: @(reserved.holdPosition),
       copiesTotalKey: @(reserved.copiesTotal),
       sinceKey: TPPNullFromNil([reserved.since RFC3339String]),
       untilKey: TPPNullFromNil([reserved.until RFC3339String])
     };
   } ready:^(__unused TPPOPDSAcquisitionAvailabilityReady * _Nonnull ready) {
     result = @{
       caseKey: readyCase
     };
   }];

  return result;
}

@implementation TPPOPDSAcquisitionAvailabilityUnavailable

- (instancetype _Nonnull)initWithCopiesHeld:(TPPOPDSAcquisitionAvailabilityCopies const)copiesHeld
                                copiesTotal:(TPPOPDSAcquisitionAvailabilityCopies const)copiesTotal
{
  self = [super init];

  self.copiesHeld = copiesHeld;
  self.copiesTotal = copiesTotal;

  return self;
}

- (NSDate *_Nullable)since
{
  return nil;
}

- (NSDate *_Nullable)until
{
  return nil;
}

- (void)
matchUnavailable:(void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityUnavailable *_Nonnull unavailable))unavailable
limited:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited))limited
unlimited:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited))unlimited
reserved:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved))reserved
ready:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready))ready
{
  if (unavailable) {
    unavailable(self);
  }
}

@end

@implementation TPPOPDSAcquisitionAvailabilityLimited

- (instancetype _Nonnull)initWithCopiesAvailable:(TPPOPDSAcquisitionAvailabilityCopies)copiesAvailable
                                     copiesTotal:(TPPOPDSAcquisitionAvailabilityCopies)copiesTotal
                                           since:(NSDate *const _Nullable)since
                                           until:(NSDate *const _Nullable)until
{
  self = [super init];

  self.copiesAvailable = copiesAvailable;
  self.copiesTotal = copiesTotal;
  self.since = since;
  self.until = until;

  return self;
}

- (void)
matchUnavailable:(__unused void (^ _Nullable const)
                  (TPPOPDSAcquisitionAvailabilityUnavailable *_Nonnull unavailable))unavailable
limited:(void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited))limited
unlimited:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited))unlimited
reserved:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved))reserved
ready:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready))ready
{
  if (limited) {
    limited(self);
  }
}

@end

@implementation TPPOPDSAcquisitionAvailabilityUnlimited

- (NSDate *_Nullable)since
{
  return nil;
}

- (NSDate *_Nullable)until
{
  return nil;
}

- (void)
matchUnavailable:(__unused void (^ _Nullable const)
                  (TPPOPDSAcquisitionAvailabilityUnavailable *_Nonnull unavailable))unavailable
limited:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited))limited
unlimited:(void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited))unlimited
reserved:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved))reserved
ready:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready))ready
{
  if (unlimited) {
    unlimited(self);
  }
}

@end

@implementation TPPOPDSAcquisitionAvailabilityReserved

- (instancetype _Nonnull)initWithHoldPosition:(NSUInteger const)holdPosition
                                  copiesTotal:(TPPOPDSAcquisitionAvailabilityCopies const)copiesTotal
                                        since:(NSDate *const _Nullable)since
                                        until:(NSDate *const _Nullable)until
{
  self = [super init];

  self.holdPosition = holdPosition;
  self.copiesTotal = copiesTotal;
  self.since = since;
  self.until = until;

  return self;
}

- (void)
matchUnavailable:(__unused void (^ _Nullable const)
                  (TPPOPDSAcquisitionAvailabilityUnavailable *_Nonnull unavailable))unavailable
limited:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited))limited
unlimited:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited))unlimited
reserved:(void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved))reserved
ready:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready))ready
{
  if (reserved) {
    reserved(self);
  }
}

@end

@implementation TPPOPDSAcquisitionAvailabilityReady

- (instancetype _Nonnull)initWithSince:(NSDate *const _Nullable)since
                                 until:(NSDate *const _Nullable)until
{
  self = [super init];

  self.since = since;
  self.until = until;

  return self;
}

- (void)
matchUnavailable:(__unused void (^ _Nullable const)
                  (TPPOPDSAcquisitionAvailabilityUnavailable *_Nonnull unavailable))unavailable
limited:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited))limited
unlimited:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited))unlimited
reserved:(__unused void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved))reserved
ready:(void (^ _Nullable const)(TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready))ready
{
  if (ready) {
    ready(self);
  }
}

@end

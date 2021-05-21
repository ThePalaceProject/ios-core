@import Foundation;

@class TPPXML;

typedef NSUInteger TPPOPDSAcquisitionAvailabilityCopies;

extern TPPOPDSAcquisitionAvailabilityCopies const TPPOPDSAcquisitionAvailabilityCopiesUnknown;

@class TPPOPDSAcquisitionAvailabilityUnavailable;
@class TPPOPDSAcquisitionAvailabilityLimited;
@class TPPOPDSAcquisitionAvailabilityUnlimited;
@class TPPOPDSAcquisitionAvailabilityReserved;
@class TPPOPDSAcquisitionAvailabilityReady;

@protocol TPPOPDSAcquisitionAvailability

/// When this availability state began.
/// See https://git.io/JmCQT for full semantics.
@property (nonatomic, readonly, nullable) NSDate *since;

/// When this availability state will end.
/// See https://git.io/JmCQT for full semantics.
@property (nonatomic, readonly, nullable) NSDate *until;

- (void)
matchUnavailable:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityUnavailable *_Nonnull unavailable))unavailable
limited:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited))limited
unlimited:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited))unlimited
reserved:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved))reserved
ready:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready))ready;

@end

/// @param linkXML XML from an OPDS entry where @c linkXML.name == @c @"link".
/// @return A value of one of the three availability information types. If the
/// input is not valid, @c NYPLOPDSAcquisitionAvailabilityUnlimited is returned.
id<TPPOPDSAcquisitionAvailability> _Nonnull
NYPLOPDSAcquisitionAvailabilityWithLinkXML(TPPXML *_Nonnull linkXML);

/// @param dictionary Serialized availability information created with
/// @c NYPLOPDSAcquisitionAvailabilityDictionaryRepresentation.
/// @return Availability information or @c nil if the input is not sensible.
id<TPPOPDSAcquisitionAvailability> _Nullable
NYPLOPDSAcquisitionAvailabilityWithDictionary(NSDictionary *_Nonnull dictionary);

/// @param availability The availability information to serialize.
/// @return The serialized result for use with
/// @c NYPLOPDSAcquisitionAvailabilityWithDictionary.
NSDictionary *_Nonnull
NYPLOPDSAcquisitionAvailabilityDictionaryRepresentation(id<TPPOPDSAcquisitionAvailability> _Nonnull availability);

@interface TPPOPDSAcquisitionAvailabilityUnavailable : NSObject <TPPOPDSAcquisitionAvailability>

@property (nonatomic, readonly) TPPOPDSAcquisitionAvailabilityCopies copiesHeld;
@property (nonatomic, readonly) TPPOPDSAcquisitionAvailabilityCopies copiesTotal;

+ (instancetype _Null_unspecified)new NS_UNAVAILABLE;
- (instancetype _Null_unspecified)init NS_UNAVAILABLE;

- (instancetype _Nonnull)initWithCopiesHeld:(TPPOPDSAcquisitionAvailabilityCopies)copiesHeld
                                copiesTotal:(TPPOPDSAcquisitionAvailabilityCopies)copiesTotal
  NS_DESIGNATED_INITIALIZER;

@end

@interface TPPOPDSAcquisitionAvailabilityLimited : NSObject <TPPOPDSAcquisitionAvailability>

@property (nonatomic, readonly) TPPOPDSAcquisitionAvailabilityCopies copiesAvailable;
@property (nonatomic, readonly) TPPOPDSAcquisitionAvailabilityCopies copiesTotal;

+ (instancetype _Null_unspecified)new NS_UNAVAILABLE;
- (instancetype _Null_unspecified)init NS_UNAVAILABLE;

- (instancetype _Nonnull)initWithCopiesAvailable:(TPPOPDSAcquisitionAvailabilityCopies)copiesAvailable
                                     copiesTotal:(TPPOPDSAcquisitionAvailabilityCopies)copiesTotal
                                           since:(NSDate *_Nullable)since
                                           until:(NSDate *_Nullable)until
  NS_DESIGNATED_INITIALIZER;

@end

@interface TPPOPDSAcquisitionAvailabilityUnlimited : NSObject <TPPOPDSAcquisitionAvailability>

@end

@interface TPPOPDSAcquisitionAvailabilityReserved : NSObject <TPPOPDSAcquisitionAvailability>

/// If equal to @c 1, the user is next in line. This value is never @c 0.
@property (nonatomic, readonly) NSUInteger holdPosition;
@property (nonatomic, readonly) TPPOPDSAcquisitionAvailabilityCopies copiesTotal;

+ (instancetype _Null_unspecified)new NS_UNAVAILABLE;
- (instancetype _Null_unspecified)init NS_UNAVAILABLE;

- (instancetype _Nonnull)initWithHoldPosition:(NSUInteger)holdPosition
                                  copiesTotal:(TPPOPDSAcquisitionAvailabilityCopies)copiesTotal
                                        since:(NSDate *_Nullable)since
                                        until:(NSDate *_Nullable)until
  NS_DESIGNATED_INITIALIZER;

@end

@interface TPPOPDSAcquisitionAvailabilityReady : NSObject <TPPOPDSAcquisitionAvailability>

+ (instancetype _Null_unspecified)new NS_UNAVAILABLE;
- (instancetype _Null_unspecified)init NS_UNAVAILABLE;

- (instancetype _Nonnull)initWithSince:(NSDate *_Nullable)since
                                 until:(NSDate *_Nullable)until
  NS_DESIGNATED_INITIALIZER;

@end

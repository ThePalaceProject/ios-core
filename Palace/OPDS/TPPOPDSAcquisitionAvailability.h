// TPPOPDSAcquisitionAvailability.h — Protocol and typedef definitions only;
// class and function implementations are in TPPOPDSAcquisitionAvailability.swift

#import <Foundation/Foundation.h>

@class TPPXML;

typedef NSUInteger TPPOPDSAcquisitionAvailabilityCopies;

// Forward-declare the concrete classes so ObjC code can reference them in block params
@class TPPOPDSAcquisitionAvailabilityUnavailable;
@class TPPOPDSAcquisitionAvailabilityLimited;
@class TPPOPDSAcquisitionAvailabilityUnlimited;
@class TPPOPDSAcquisitionAvailabilityReserved;
@class TPPOPDSAcquisitionAvailabilityReady;

@protocol TPPOPDSAcquisitionAvailability

/// When this availability state began.
@property (nonatomic, readonly, nullable) NSDate *since;

/// When this availability state will end.
@property (nonatomic, readonly, nullable) NSDate *until;

- (void)
matchUnavailable:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityUnavailable *_Nonnull unavailable))unavailable
limited:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited))limited
unlimited:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited))unlimited
reserved:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved))reserved
ready:(void (^ _Nullable)(TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready))ready;

@end

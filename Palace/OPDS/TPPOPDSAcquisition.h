// TPPOPDSAcquisition.h — Enum and options definitions only;
// class and function implementations are in TPPOPDSAcquisition.swift

#import <Foundation/Foundation.h>

/// One of the six acquisition relations given in the OPDS specification.
typedef NS_ENUM(NSInteger, TPPOPDSAcquisitionRelation) {
  TPPOPDSAcquisitionRelationGeneric,
  TPPOPDSAcquisitionRelationOpenAccess,
  TPPOPDSAcquisitionRelationBorrow,
  TPPOPDSAcquisitionRelationBuy,
  TPPOPDSAcquisitionRelationSample,
  TPPOPDSAcquisitionRelationPreview,
  TPPOPDSAcquisitionRelationSubscribe
};

/// Represents zero or more relations given in the OPDS specification.
typedef NS_OPTIONS(NSUInteger, TPPOPDSAcquisitionRelationSet) {
  TPPOPDSAcquisitionRelationSetGeneric    = 1 << 0,
  TPPOPDSAcquisitionRelationSetOpenAccess = 1 << 1,
  TPPOPDSAcquisitionRelationSetBorrow     = 1 << 2,
  TPPOPDSAcquisitionRelationSetBuy        = 1 << 3,
  TPPOPDSAcquisitionRelationSetSample     = 1 << 4,
  TPPOPDSAcquisitionRelationSetPreview    = 1 << 5,
  TPPOPDSAcquisitionRelationSetSubscribe  = 1 << 6
};

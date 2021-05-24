//
//  TPPBookButtonsState.h
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/18/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

@import Foundation;

typedef NS_ENUM(NSInteger, TPPBookButtonsState) {
  TPPBookButtonsStateCanBorrow,
  TPPBookButtonsStateCanHold,
  TPPBookButtonsStateHolding,
  TPPBookButtonsStateHoldingFOQ, //Front Of Queue: a book that was Reserved and now it's Ready for borrow
  TPPBookButtonsStateDownloadNeeded,
  TPPBookButtonsStateDownloadSuccessful,
  TPPBookButtonsStateUsed,
  TPPBookButtonsStateDownloadInProgress,
  TPPBookButtonsStateDownloadFailed,
  TPPBookButtonsStateUnsupported
};

@protocol TPPOPDSAcquisitionAvailability;

/// @param availability A non-nil @c NYPLOPDSAcquisitionAvailability.
/// @return A @c Borrow, @c Keep, @c Hold, @c Holding, or @c HoldingFOQ state.
TPPBookButtonsState
TPPBookButtonsViewStateWithAvailability(id<TPPOPDSAcquisitionAvailability> availability);

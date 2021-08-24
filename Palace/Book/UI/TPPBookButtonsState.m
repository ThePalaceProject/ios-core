//
//  TPPBookButtonsState.m
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/18/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

#import "TPPBookButtonsState.h"
#import "TPPOPDSAcquisitionAvailability.h"
#import "Palace-Swift.h"

TPPBookButtonsState
TPPBookButtonsViewStateWithAvailability(id<TPPOPDSAcquisitionAvailability> const availability)
{
  __block TPPBookButtonsState state = TPPBookButtonsStateUnsupported;

  if (!availability) {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                              summary:@"Unable to determine BookButtonsViewState because no Availability was provided"
                             metadata:nil];
  }

  [availability
   matchUnavailable:^(__unused TPPOPDSAcquisitionAvailabilityUnavailable *_Nonnull unavailable) {
    state = TPPBookButtonsStateCanHold;
  }
   limited:^(__unused TPPOPDSAcquisitionAvailabilityLimited *_Nonnull limited) {
    state = TPPBookButtonsStateCanBorrow;
  }
   unlimited:^(__unused TPPOPDSAcquisitionAvailabilityUnlimited *_Nonnull unlimited) {
    state = TPPBookButtonsStateCanBorrow;
  }
   reserved:^(__unused TPPOPDSAcquisitionAvailabilityReserved *_Nonnull reserved) {
    state = TPPBookButtonsStateHolding;
  }
   ready:^(__unused TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready) {
    state = TPPBookButtonsStateHoldingFOQ;
  }];

  return state;
}

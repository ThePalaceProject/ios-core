//
//  TPPBookButtonsView.m
//  The Palace Project
//
//  Created by Ben Anderman on 8/27/15.
//  Copyright (c) 2015 NYPL Labs. All rights reserved.
//

@import PureLayout;

#import "TPPBook.h"
#import "TPPBookRegistry.h"
#import "TPPBookButtonsView.h"
#import "TPPConfiguration.h"
#import "TPPRootTabBarController.h"
#import "TPPOPDS.h"
#import "Palace-Swift.h"

@interface TPPBookButtonsView ()

@property (nonatomic) UIActivityIndicatorView *activityIndicator;
@property (nonatomic) TPPRoundedButton *deleteButton;
@property (nonatomic) TPPRoundedButton *downloadButton;
@property (nonatomic) TPPRoundedButton *readButton;
@property (nonatomic) TPPRoundedButton *cancelButton;
@property (nonatomic) NSArray *visibleButtons;
@property (nonatomic) NSMutableArray *constraints;
@property (nonatomic) id observer;

@end

@implementation TPPBookButtonsView

- (instancetype)init
{
  self = [super init];
  if(!self) {
    return self;
  }
  
  self.constraints = [[NSMutableArray alloc] init];
  
  self.deleteButton = [[TPPRoundedButton alloc] initWithType:TPPRoundedButtonTypeNormal isFromDetailView:NO];
  self.deleteButton.titleLabel.minimumScaleFactor = 0.8f;
  [self.deleteButton addTarget:self action:@selector(didSelectReturn) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:self.deleteButton];

  self.downloadButton = [[TPPRoundedButton alloc] initWithType:TPPRoundedButtonTypeNormal isFromDetailView:NO];
  self.downloadButton.titleLabel.minimumScaleFactor = 0.8f;
  [self.downloadButton addTarget:self action:@selector(didSelectDownload) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:self.downloadButton];

  self.readButton = [[TPPRoundedButton alloc] initWithType:TPPRoundedButtonTypeNormal isFromDetailView:NO];
  self.readButton.titleLabel.minimumScaleFactor = 0.8f;
  [self.readButton addTarget:self action:@selector(didSelectRead) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:self.readButton];
  
  self.cancelButton = [[TPPRoundedButton alloc] initWithType:TPPRoundedButtonTypeNormal isFromDetailView:NO];
  self.cancelButton.titleLabel.minimumScaleFactor = 0.8f;
  [self.cancelButton addTarget:self action:@selector(didSelectCancel) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:self.cancelButton];
  
  self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
  self.activityIndicator.color = [TPPConfiguration mainColor];
  self.activityIndicator.hidesWhenStopped = YES;
  [self addSubview:self.activityIndicator];
  
  self.observer = [[NSNotificationCenter defaultCenter]
                   addObserverForName:NSNotification.TPPBookProcessingDidChange
   object:nil
   queue:[NSOperationQueue mainQueue]
   usingBlock:^(NSNotification *note) {
     if ([note.userInfo[TPPNotificationKeys.bookProcessingBookIDKey] isEqualToString:self.book.identifier]) {
       BOOL isProcessing = [note.userInfo[TPPNotificationKeys.bookProcessingValueKey] boolValue];
       [self updateProcessingState:isProcessing];
     }
   }];
  
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self.observer];
}

- (void)configureForBookDetailsContext
{
  [self.deleteButton setFromDetailView:YES];
  [self.downloadButton setFromDetailView:YES];
  [self.readButton setFromDetailView:YES];
  [self.cancelButton setFromDetailView:YES];
}

- (void)updateButtonFrames
{
  [NSLayoutConstraint deactivateConstraints:self.constraints];

  if (self.visibleButtons.count == 0) {
    return;
  }
  
  [self.constraints removeAllObjects];
  int count = 0;
  TPPRoundedButton *lastButton = nil;
  for (TPPRoundedButton *button in self.visibleButtons) {
    [self.constraints addObject:[button autoPinEdgeToSuperviewEdge:ALEdgeTop]];
    [self.constraints addObject:[button autoPinEdgeToSuperviewEdge:ALEdgeBottom]];
    if (!lastButton) {
      [self.constraints addObject:[button autoPinEdgeToSuperviewEdge:ALEdgeLeading]];
    } else {
      [self.constraints addObject:[button autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:lastButton withOffset:6.0]];
    }
    if (count == (int)self.visibleButtons.count - 1) {
      [self.constraints addObject:[button autoPinEdgeToSuperviewEdge:ALEdgeTrailing]];
    }
    lastButton = button;
    count++;
  }
}

- (void)updateProcessingState:(BOOL)isCurrentlyProcessing
{
  if (isCurrentlyProcessing) {
    [self.activityIndicator startAnimating];
  } else {
    [self.activityIndicator stopAnimating];
  }
  for(TPPRoundedButton *button in @[self.downloadButton, self.deleteButton, self.readButton, self.cancelButton]) {
    button.enabled = !isCurrentlyProcessing;
  }
}

- (void)updateButtons
{
  NSArray *visibleButtonInfo = nil;
  static NSString *const ButtonKey = @"button";
  static NSString *const TitleKey = @"title";
  static NSString *const HintKey = @"accessibilityHint";
  static NSString *const AddIndicatorKey = @"addIndicator";
  [self updateProcessingState:NO];

  NSString *fulfillmentId = [[TPPBookRegistry sharedRegistry] fulfillmentIdForIdentifier:self.book.identifier];
  
  switch(self.state) {
    case TPPBookButtonsStateCanBorrow:
      visibleButtonInfo = @[@{ButtonKey: self.downloadButton,
                              TitleKey: NSLocalizedString(@"Borrow", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Borrows %@", nil), self.book.title]}];
      break;
    case TPPBookButtonsStateCanHold:
      visibleButtonInfo = @[@{ButtonKey: self.downloadButton,
                              TitleKey: NSLocalizedString(@"Reserve", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Holds %@", nil), self.book.title]}];
      break;
    case TPPBookButtonsStateHolding:
      visibleButtonInfo = @[@{ButtonKey: self.deleteButton,
                              TitleKey: NSLocalizedString(@"Remove", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Cancels hold for %@", nil), self.book.title],
                              AddIndicatorKey: @(YES)}];
      break;
    case TPPBookButtonsStateHoldingFOQ:
      visibleButtonInfo = @[@{ButtonKey: self.downloadButton,
                              TitleKey: NSLocalizedString(@"Borrow", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Borrows %@", nil), self.book.title],
                              AddIndicatorKey: @(YES)},
                            @{ButtonKey: self.deleteButton,
                              TitleKey: NSLocalizedString(@"Remove", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Cancels hold for %@", nil), self.book.title]}];
      break;
    case TPPBookButtonsStateDownloadNeeded:
    {
      visibleButtonInfo = @[@{ButtonKey: self.downloadButton,
                              TitleKey: NSLocalizedString(@"Download", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Downloads %@", nil), self.book.title],
                              AddIndicatorKey: @(YES)}];
        
      if (self.showReturnButtonIfApplicable)
      {
        NSString *title = (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth) ? NSLocalizedString(@"Delete", nil) : NSLocalizedString(@"Return", nil);
        NSString *hint = (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth) ? [NSString stringWithFormat:NSLocalizedString(@"Deletes %@", nil), self.book.title] : [NSString stringWithFormat:NSLocalizedString(@"Returns %@", nil), self.book.title];

        visibleButtonInfo = @[@{ButtonKey: self.downloadButton,
                                TitleKey: NSLocalizedString(@"Download", nil),
                                HintKey: [NSString stringWithFormat:NSLocalizedString(@"Downloads %@", nil), self.book.title],
                                AddIndicatorKey: @(YES)},
                              @{ButtonKey: self.deleteButton,
                                TitleKey: title,
                                HintKey: hint}];
      }
      break;
    }
    case TPPBookButtonsStateDownloadSuccessful:
      // Fallthrough
    case TPPBookButtonsStateUsed:
    {
      NSDictionary *buttonInfo;
      switch (self.book.defaultBookContentType) {
        case TPPBookContentTypeAudiobook:
          buttonInfo = @{ButtonKey: self.readButton,
                         TitleKey: NSLocalizedString(@"Listen", nil),
                         HintKey: [NSString stringWithFormat:NSLocalizedString(@"Opens audiobook %@ for listening", nil), self.book.title],
                         AddIndicatorKey: @(YES)};
          break;
        case TPPBookContentTypePDF:
        case TPPBookContentTypeEPUB:
          buttonInfo = @{ButtonKey: self.readButton,
                         TitleKey: NSLocalizedString(@"Read", nil),
                         HintKey: [NSString stringWithFormat:NSLocalizedString(@"Opens %@ for reading", nil), self.book.title],
                         AddIndicatorKey: @(YES)};
          break;
        case TPPBookContentTypeUnsupported:
          @throw NSInternalInconsistencyException;
          break;
      }

      visibleButtonInfo = @[buttonInfo];
        
      if (self.showReturnButtonIfApplicable)
      {
        NSString *title = (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth) ? NSLocalizedString(@"Delete", nil) : NSLocalizedString(@"Return", nil);
        NSString *hint = (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth) ? [NSString stringWithFormat:NSLocalizedString(@"Deletes %@", nil), self.book.title] : [NSString stringWithFormat:NSLocalizedString(@"Returns %@", nil), self.book.title];

        visibleButtonInfo = @[buttonInfo,
                              @{ButtonKey: self.deleteButton,
                                TitleKey: title,
                                HintKey: hint}];
      }
      break;
    }
    case TPPBookButtonsStateDownloadInProgress:
    {
      if (self.showReturnButtonIfApplicable)
      {
        visibleButtonInfo = @[@{ButtonKey: self.cancelButton,
                                TitleKey: NSLocalizedString(@"Cancel", nil),
                                HintKey: [NSString stringWithFormat:NSLocalizedString(@"Cancels the download for the current book: %@", nil), self.book.title],
                                AddIndicatorKey: @(NO)}];
      }
      break;
    }
    case TPPBookButtonsStateDownloadFailed:
    {
      if (self.showReturnButtonIfApplicable)
      {
        visibleButtonInfo = @[@{ButtonKey: self.downloadButton,
                                TitleKey: NSLocalizedString(@"Retry", nil),
                                HintKey: [NSString stringWithFormat:NSLocalizedString(@"Retry the failed download for this book: %@", nil), self.book.title],
                                AddIndicatorKey: @(NO)},
                              @{ButtonKey: self.cancelButton,
                                TitleKey: NSLocalizedString(@"Cancel", nil),
                                HintKey: [NSString stringWithFormat:NSLocalizedString(@"Cancels the failed download for this book: %@", nil), self.book.title],
                                AddIndicatorKey: @(NO)}];
      }
      break;
    }
    case TPPBookButtonsStateUnsupported:
      // The app should never show books it cannot support, but if it mistakenly does,
      // no actions will be available.
      visibleButtonInfo = @[];
      break;
  }

  NSMutableArray *visibleButtons = [NSMutableArray array];
  
  BOOL fulfillmentIdRequired = NO;
  TPPBookState state = [[TPPBookRegistry sharedRegistry] stateForIdentifier:self.book.identifier];
  BOOL hasRevokeLink = (self.book.revokeURL && (state == TPPBookStateDownloadSuccessful || state == TPPBookStateUsed));

  #if defined(FEATURE_DRM_CONNECTOR)
  
  // It's required unless the book is being held and has a revoke link
  fulfillmentIdRequired = !(self.state == TPPBookButtonsStateHolding && self.book.revokeURL);
  
  #endif
  
  for (NSDictionary *buttonInfo in visibleButtonInfo) {
    TPPRoundedButton *button = buttonInfo[ButtonKey];
    if(button == self.deleteButton && (!fulfillmentId && fulfillmentIdRequired) && !hasRevokeLink) {
      if(!self.book.defaultAcquisitionIfOpenAccess && TPPUserAccount.sharedAccount.authDefinition.needsAuth) {
        continue;
      }
    }
    
    button.hidden = NO;
    
    // Disable the animation for changing the title. This helps avoid visual issues with
    // reloading data in collection views.
    [UIView setAnimationsEnabled:NO];
    
    [button setTitle:buttonInfo[TitleKey] forState:UIControlStateNormal];
    [button setAccessibilityHint:buttonInfo[HintKey]];

    // We need to lay things out here else animations will be back on before it happens.
    [button layoutIfNeeded];
    
    // Re-enable animations as per usual.
    [UIView setAnimationsEnabled:YES];

    // Provide End-Date for checked out loans
    [button setType:TPPRoundedButtonTypeNormal];
    if ([buttonInfo[AddIndicatorKey] isEqualToValue:@(YES)]) {
      [self.book.defaultAcquisition.availability
       matchUnavailable:nil
       limited:^(TPPOPDSAcquisitionAvailabilityLimited *const _Nonnull limited) {
        if ([limited.until timeIntervalSinceNow] > 0) {
          [button setType:TPPRoundedButtonTypeClock];
          [button setEndDate:limited.until];
        }
      }
       unlimited:nil
       reserved:nil
       ready:^(TPPOPDSAcquisitionAvailabilityReady *const _Nonnull limited) {
        if ([limited.until timeIntervalSinceNow] > 0) {
          [button setType:TPPRoundedButtonTypeClock];
          [button setEndDate:limited.until];
        }
      }];
    }
    
    [visibleButtons addObject:button];
  }
  for (TPPRoundedButton *button in @[self.downloadButton, self.deleteButton, self.readButton, self.cancelButton]) {
    if (![visibleButtons containsObject:button]) {
      button.hidden = YES;
    }
  }
  self.visibleButtons = visibleButtons;
  [self updateButtonFrames];
}

- (void)setBook:(TPPBook *)book
{
  _book = book;
  [self updateButtons];

  BOOL isCurrentlyProcessing = [[TPPBookRegistry sharedRegistry]
                                processingForIdentifier:self.book.identifier];
  [self updateProcessingState:isCurrentlyProcessing];
}

- (void)setState:(TPPBookButtonsState const)state
{
  _state = state;
  [self updateButtons];
}

#pragma mark - Button actions

- (void)didSelectReturn
{
  self.activityIndicator.center = self.deleteButton.center;
  
  NSString *title = nil;
  NSString *message = nil;
  NSString *confirmButtonTitle = nil;
  
  switch([[TPPBookRegistry sharedRegistry] stateForIdentifier:self.book.identifier]) {
    case TPPBookStateUsed:
    case TPPBookStateSAMLStarted:
    case TPPBookStateDownloading:
    case TPPBookStateUnregistered:
    case TPPBookStateDownloadFailed:
    case TPPBookStateDownloadNeeded:
    case TPPBookStateDownloadSuccessful:
      title = ((self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth)
               ? NSLocalizedString(@"MyBooksDownloadCenterConfirmDeleteTitle", nil)
               : NSLocalizedString(@"MyBooksDownloadCenterConfirmReturnTitle", nil));
      message = ((self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth)
                 ? NSLocalizedString(@"MyBooksDownloadCenterConfirmDeleteTitleMessageFormat", nil)
                 : NSLocalizedString(@"MyBooksDownloadCenterConfirmReturnTitleMessageFormat", nil));
      confirmButtonTitle = ((self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth)
                            ? NSLocalizedString(@"MyBooksDownloadCenterConfirmDeleteTitle", nil)
                            : NSLocalizedString(@"MyBooksDownloadCenterConfirmReturnTitle", nil));
      break;
    case TPPBookStateHolding:
      title = NSLocalizedString(@"BookButtonsViewRemoveHoldTitle", nil);
      message = [NSString stringWithFormat:
                 NSLocalizedString(@"BookButtonsViewRemoveHoldMessage", nil),
                 self.book.title];
      confirmButtonTitle = NSLocalizedString(@"BookButtonsViewRemoveHoldConfirm", nil);
      break;
    case TPPBookStateUnsupported:
      @throw NSInternalInconsistencyException;
  }
  
  UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title
                                                                           message:[NSString stringWithFormat:
                                                                                    message, self.book.title]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
  
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
  
  [alertController addAction:[UIAlertAction actionWithTitle:confirmButtonTitle
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__attribute__((unused))UIAlertAction * _Nonnull action) {
                                                      [self.delegate didSelectReturnForBook:self.book];
                                                    }]];
  
  [[TPPRootTabBarController sharedController] safelyPresentViewController:alertController animated:YES completion:nil];
}

- (void)didSelectRead
{
  self.activityIndicator.center = self.readButton.center;
  [self updateProcessingState:YES];
  [self.delegate didSelectReadForBook:self.book];
  [[TPPRootTabBarController sharedController] dismissViewControllerAnimated:YES completion:nil];

}

- (void)didSelectDownload
{
  if (self.state == TPPBookButtonsStateCanHold) {
    [TPPUserNotifications requestAuthorization];
  }
  self.activityIndicator.center = self.downloadButton.center;
  [self.delegate didSelectDownloadForBook:self.book];
}

- (void)didSelectCancel
{
  switch([[TPPBookRegistry sharedRegistry] stateForIdentifier:self.book.identifier]) {
    case TPPBookStateSAMLStarted:
    case TPPBookStateDownloading: {
      [self.downloadingDelegate didSelectCancelForBookDetailDownloadingView:self];
      break;
    }
    case TPPBookStateDownloadFailed: {
      [self.downloadingDelegate didSelectCancelForBookDetailDownloadFailedView:self];
      break;
    }
    default:
      break;
  }
  
}

@end

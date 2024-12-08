//
//  TPPBookButtonsView.m
//  The Palace Project
//
//  Created by Ben Anderman on 8/27/15.
//  Copyright (c) 2015 NYPL Labs. All rights reserved.
//

@import PureLayout;
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
@property (nonatomic) TPPRoundedButton *sampleButton;
@property (nonatomic) NSArray *visibleButtons;
@property (nonatomic) NSMutableArray *constraints;
@property (nonatomic) NSMutableArray *observers;
@property (nonatomic) BOOL samplesEnabled;
@property (nonatomic) BOOL isProcessing;

@end


@implementation TPPBookButtonsView

- (instancetype)init
{
  return [self initWithSamplesEnabled: NO];
}

- (instancetype)initWithSamplesEnabled:(BOOL)samplesEnabled
{
  self = [super init];
  if(!self) {
    return self;
  }
  
  self.constraints = [[NSMutableArray alloc] init];
  self.samplesEnabled = samplesEnabled;
  
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
  
  self.sampleButton = [[TPPRoundedButton alloc] initWithType:TPPRoundedButtonTypeNormal isFromDetailView:NO];
  self.sampleButton.titleLabel.minimumScaleFactor = 0.8f;
  [self.sampleButton addTarget:self action:@selector(didSelectSample) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:self.sampleButton];
  
  self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  self.activityIndicator.color = [TPPConfiguration mainColor];
  self.activityIndicator.hidesWhenStopped = YES;
  [self addSubview:self.activityIndicator];
  
  [self.observers addObject:[[NSNotificationCenter defaultCenter]
                             addObserverForName:NSNotification.TPPBookProcessingDidChange
                             object:nil
                             queue:[NSOperationQueue mainQueue]
                             usingBlock:^(NSNotification *note) {
    if ([note.userInfo[TPPNotificationKeys.bookProcessingBookIDKey] isEqualToString:self.book.identifier]) {
      BOOL isProcessing = [note.userInfo[TPPNotificationKeys.bookProcessingValueKey] boolValue];
      [self updateProcessingState:isProcessing];
    }
  }]];
    
  [self.observers addObject:[[NSNotificationCenter defaultCenter]
                             addObserverForName:NSNotification.TPPReachabilityChanged
                             object:nil
                             queue:[NSOperationQueue mainQueue]
                             usingBlock:^(NSNotification * _Nonnull note) {
    [self updateButtons];
  }]];
  
  return self;
}

- (void)dealloc
{
  for(id const observer in self.observers) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
  }
  [self.observers removeAllObjects];
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
  self.isProcessing = isCurrentlyProcessing;
  
  if (isCurrentlyProcessing) {
    [self.activityIndicator startAnimating];
  } else {
    [self.activityIndicator stopAnimating];
  }
  for(TPPRoundedButton *button in @[self.downloadButton, self.deleteButton, self.readButton, self.cancelButton, self.sampleButton]) {
    button.enabled = !isCurrentlyProcessing;
  }
}

- (void)updateButtons
{
  NSMutableArray *visibleButtonInfo = nil;
  static NSString *const ButtonKey = @"button";
  static NSString *const TitleKey = @"title";
  static NSString *const HintKey = @"accessibilityHint";
  static NSString *const AddIndicatorKey = @"addIndicator";
  [self updateProcessingState:NO];

  NSString *fulfillmentId = [[TPPBookRegistry shared] fulfillmentIdForIdentifier:self.book.identifier];
  
  switch(self.state) {
    case TPPBookButtonsStateCanBorrow:
      visibleButtonInfo = [[NSMutableArray alloc] initWithArray: @[@{ButtonKey: self.downloadButton,
                              TitleKey: NSLocalizedString(@"Get", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Gets %@", nil), self.book.title]}]];

      if ([self.book hasAudiobookSample] && self.samplesEnabled) {
        [visibleButtonInfo addObject:@{ButtonKey: self.sampleButton,
                                        TitleKey: NSLocalizedString(@"Play Sample", nil),
                                         HintKey: [NSString stringWithFormat:NSLocalizedString(@"View sample for %@", nil), self.book.title]}];
      } else if ([self.book hasSample] && self.samplesEnabled) {
        [visibleButtonInfo addObject:@{ButtonKey: self.sampleButton,
                                        TitleKey: NSLocalizedString(@"View Sample", nil),
                                         HintKey: [NSString stringWithFormat:NSLocalizedString(@"View sample for %@", nil), self.book.title]}];
      }

      break;
    case TPPBookButtonsStateCanHold:
      visibleButtonInfo = [[NSMutableArray alloc] initWithArray: @[@{ButtonKey: self.downloadButton,
                              TitleKey: NSLocalizedString(@"Reserve", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Holds %@", nil), self.book.title]}]];

      if ([self.book hasSample] && self.samplesEnabled) {
        [visibleButtonInfo addObject:@{ButtonKey: self.sampleButton,
                                              TitleKey: NSLocalizedString(@"Sample", nil),
                                       HintKey: [NSString stringWithFormat:NSLocalizedString(@"View sample for %@", nil), self.book.title]}];
      }

      break;
    case TPPBookButtonsStateHolding:
      visibleButtonInfo = [[NSMutableArray alloc] initWithArray:@[@{ButtonKey: self.deleteButton,
                              TitleKey: NSLocalizedString(@"Remove", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Cancels hold for %@", nil), self.book.title],
                              AddIndicatorKey: @(YES)}]];

      if ([self.book hasSample] && self.samplesEnabled) {
        [visibleButtonInfo addObject:@{ButtonKey: self.sampleButton,
                                              TitleKey: NSLocalizedString(@"Sample", nil),
                                       HintKey: [NSString stringWithFormat:NSLocalizedString(@"View sample for %@", nil), self.book.title]}];
      }

      break;
    case TPPBookButtonsStateHoldingFOQ:
      visibleButtonInfo = [[NSMutableArray alloc] initWithArray:@[@{ButtonKey: self.downloadButton,
                              TitleKey: NSLocalizedString(@"Get", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Gets %@", nil), self.book.title],
                              AddIndicatorKey: @(YES)},
                            @{ButtonKey: self.deleteButton,
                              TitleKey: NSLocalizedString(@"Remove", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Cancels hold for %@", nil), self.book.title]}]];
      break;
    case TPPBookButtonsStateDownloadNeeded:
    {
      visibleButtonInfo = [[NSMutableArray alloc] initWithArray:@[@{ButtonKey: self.downloadButton,
                              TitleKey: NSLocalizedString(@"Download", nil),
                              HintKey: [NSString stringWithFormat:NSLocalizedString(@"Downloads %@", nil), self.book.title],
                              AddIndicatorKey: @(YES)}]];
        
      if (self.showReturnButtonIfApplicable)
      {
        NSString *title = (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth) ? NSLocalizedString(@"Delete", nil) : NSLocalizedString(@"Return", nil);
        NSString *hint = (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth) ? [NSString stringWithFormat:NSLocalizedString(@"Deletes %@", nil), self.book.title] : [NSString stringWithFormat:NSLocalizedString(@"Returns %@", nil), self.book.title];

        visibleButtonInfo = [[NSMutableArray alloc] initWithArray:@[@{ButtonKey: self.downloadButton,
                                TitleKey: NSLocalizedString(@"Download", nil),
                                HintKey: [NSString stringWithFormat:NSLocalizedString(@"Downloads %@", nil), self.book.title],
                                AddIndicatorKey: @(YES)},
                              @{ButtonKey: self.deleteButton,
                                TitleKey: title,
                                HintKey: hint}]];
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
        case TPPBookContentTypePdf:
        case TPPBookContentTypeEpub:
          buttonInfo = @{ButtonKey: self.readButton,
                         TitleKey: NSLocalizedString(@"Read", nil),
                         HintKey: [NSString stringWithFormat:NSLocalizedString(@"Opens %@ for reading", nil), self.book.title],
                         AddIndicatorKey: @(YES)};
          break;
        case TPPBookContentTypeUnsupported:
          buttonInfo = @{};
          break;
      }

      visibleButtonInfo = [[NSMutableArray alloc] initWithArray: @[buttonInfo]];
        
      if (self.showReturnButtonIfApplicable)
      {
        NSString *title = (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth) ? NSLocalizedString(@"Delete", nil) : NSLocalizedString(@"Return", nil);
        NSString *hint = (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth) ? [NSString stringWithFormat:NSLocalizedString(@"Deletes %@", nil), self.book.title] : [NSString stringWithFormat:NSLocalizedString(@"Returns %@", nil), self.book.title];

        visibleButtonInfo = [[NSMutableArray alloc] initWithArray:@[buttonInfo,
                              @{ButtonKey: self.deleteButton,
                                TitleKey: title,
                                HintKey: hint}]];
      }
      break;
    }
    case TPPBookButtonsStateDownloadInProgress:
    {
      if (self.showReturnButtonIfApplicable)
      {
        visibleButtonInfo = [[NSMutableArray alloc] initWithArray:@[@{ButtonKey: self.cancelButton,
                                TitleKey: NSLocalizedString(@"Cancel", nil),
                                HintKey: [NSString stringWithFormat:NSLocalizedString(@"Cancels the download for the current book: %@", nil), self.book.title],
                                AddIndicatorKey: @(NO)}]];
      }
      break;
    }
    case TPPBookButtonsStateDownloadFailed:
    {
      if (self.showReturnButtonIfApplicable)
      {
        visibleButtonInfo = [[NSMutableArray alloc] initWithArray:@[@{ButtonKey: self.downloadButton,
                                TitleKey: NSLocalizedString(@"Retry", nil),
                                HintKey: [NSString stringWithFormat:NSLocalizedString(@"Retry the failed download for this book: %@", nil), self.book.title],
                                AddIndicatorKey: @(NO)},
                              @{ButtonKey: self.cancelButton,
                                TitleKey: NSLocalizedString(@"Cancel", nil),
                                HintKey: [NSString stringWithFormat:NSLocalizedString(@"Cancels the failed download for this book: %@", nil), self.book.title],
                                AddIndicatorKey: @(NO)}]];
      }
      break;
    }
    case TPPBookButtonsStateUnsupported:
      // The app should never show books it cannot support, but if it mistakenly does,
      // no actions will be available.
      visibleButtonInfo = [NSMutableArray new];
      break;
  }

  NSMutableArray *visibleButtons = [NSMutableArray array];
  
  BOOL fulfillmentIdRequired = NO;

  #if defined(FEATURE_DRM_CONNECTOR)
  
  // It's required unless the book is being held and has a revoke link
  fulfillmentIdRequired = !(self.state == TPPBookButtonsStateHolding && self.book.revokeURL);
  
  #endif
  
  for (NSDictionary *buttonInfo in visibleButtonInfo) {
    TPPRoundedButton *button = buttonInfo[ButtonKey];
    if (!button) {
      continue;
    }
    
    if(button == self.deleteButton && (!fulfillmentId && fulfillmentIdRequired) && !self.book.revokeURL ) {
      if(!self.book.defaultAcquisitionIfOpenAccess && TPPUserAccount.sharedAccount.authDefinition.needsAuth) {
        continue;
      }
    }
    
    button.hidden = NO;
    
    if (button != self.readButton) {
      if (button == self.deleteButton && self.showReturnButtonIfApplicable && (self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth)) {
        // "Delete" button remains active in offline mode
      } else {
        button.enabled = [Reachability.shared isConnectedToNetwork];
      }
    }
    
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
  for (TPPRoundedButton *button in @[self.downloadButton, self.deleteButton, self.readButton, self.cancelButton, self.sampleButton]) {
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

  BOOL isCurrentlyProcessing = [[TPPBookRegistry shared]
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
  
  switch([[TPPBookRegistry shared] stateFor:self.book.identifier]) {
    case TPPBookStateUsed:
    case TPPBookStateSAMLStarted:
    case TPPBookStateDownloading:
    case TPPBookStateUnregistered:
    case TPPBookStateDownloadFailed:
    case TPPBookStateDownloadNeeded:
    case TPPBookStateDownloadSuccessful:
      title = ((self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth)
               ? NSLocalizedString(@"Delete", nil)
               : NSLocalizedString(@"Return", nil));
      message = ((self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth)
                 ? NSLocalizedString(@"Are you sure you want to delete \"%@\"?", nil)
                 : NSLocalizedString(@"Are you sure you want to return \"%@\"?", nil));
      confirmButtonTitle = ((self.book.defaultAcquisitionIfOpenAccess || !TPPUserAccount.sharedAccount.authDefinition.needsAuth)
                            ? NSLocalizedString(@"Delete", nil)
                            : NSLocalizedString(@"Return", nil));
      break;
    case TPPBookStateHolding:
      title = NSLocalizedString(@"Remove Reservation", nil);
      message = [NSString stringWithFormat:
                 NSLocalizedString(@"Are you sure you want to remove \"%@\" from your reservations? You will no longer be in line for this book.", nil),
                 self.book.title];
      confirmButtonTitle = NSLocalizedString(@"Remove", nil);
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
                                                      [self.delegate didSelectReturnForBook:self.book completion:nil];
                                                    }]];
  
  [[TPPRootTabBarController sharedController] safelyPresentViewController:alertController animated:YES completion:nil];
}

- (void)didSelectRead
{
  self.activityIndicator.center = self.readButton.center;
  [self.downloadingDelegate didCloseDetailView];

  [self updateProcessingState:YES];
  [self.delegate didSelectReadForBook:self.book completion:^{
    [self updateProcessingState:NO];
  }];
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
  switch([[TPPBookRegistry shared] stateFor:self.book.identifier]) {
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

- (void)didSelectSample
{
  if (!self.isProcessing) {
    self.activityIndicator.center = self.sampleButton.center;
    [self updateProcessingState:YES];
    [self.sampleDelegate didSelectPlaySample:self.book completion:^{
      [self updateProcessingState:NO];
    }];
  }
}

@end

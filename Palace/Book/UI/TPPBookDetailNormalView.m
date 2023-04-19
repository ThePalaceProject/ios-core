@import PureLayout;

#import "NSDate+NYPLDateAdditions.h"
#import "TPPConfiguration.h"
#import "TPPOPDS.h"
#import "UIView+TPPViewAdditions.h"
#import "UIFont+TPPSystemFontOverride.h"
#import "TPPBookDetailNormalView.h"

@interface TPPBookDetailNormalView ()

typedef NS_ENUM (NSInteger, NYPLProblemReportButtonState) {
  NYPLProblemReportButtonStateNormal,
  NYPLProblemReportButtonStateSent
};

@property (nonatomic) UILabel *messageLabel;

@end

@implementation TPPBookDetailNormalView

#pragma mark UIView

- (instancetype)init
{
  self = [super init];
  if(!self) return nil;
  
  self.messageLabel = [[UILabel alloc] init];
  self.messageLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
  self.messageLabel.textColor = [TPPConfiguration backgroundColor];
  self.messageLabel.numberOfLines = 0;
  self.messageLabel.textAlignment = NSTextAlignmentCenter;
  [self addSubview:self.messageLabel];
  [self.messageLabel autoCenterInSuperview];
  [self.messageLabel autoPinEdgeToSuperviewEdge:ALEdgeLeading withInset:12 relation:NSLayoutRelationGreaterThanOrEqual];
  [self.messageLabel autoPinEdgeToSuperviewEdge:ALEdgeTrailing withInset:12 relation:NSLayoutRelationGreaterThanOrEqual];
  [self.messageLabel autoPinEdgeToSuperviewMargin:ALEdgeTop relation:NSLayoutRelationGreaterThanOrEqual];
  [self.messageLabel autoPinEdgeToSuperviewMargin:ALEdgeBottom relation:NSLayoutRelationGreaterThanOrEqual];
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(didChangePreferredContentSize)
                                               name:UIContentSizeCategoryDidChangeNotification
                                             object:nil];
  
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)drawRect:(__unused CGRect)rect
{
  //Inner drop-shadow
  CGRect bounds = [self bounds];
  CGContextRef context = UIGraphicsGetCurrentContext();

  CGMutablePathRef visiblePath = CGPathCreateMutable();
  CGPathMoveToPoint(visiblePath, NULL, bounds.origin.x, bounds.origin.y);
  CGPathAddLineToPoint(visiblePath, NULL, bounds.origin.x + bounds.size.width, bounds.origin.y);
  CGPathAddLineToPoint(visiblePath, NULL, bounds.origin.x + bounds.size.width, bounds.origin.y + bounds.size.height);
  CGPathAddLineToPoint(visiblePath, NULL, bounds.origin.x, bounds.origin.y + bounds.size.height);
  CGPathAddLineToPoint(visiblePath, NULL, bounds.origin.x, bounds.origin.y);
  CGPathCloseSubpath(visiblePath);
  
  UIColor *aColor = [TPPConfiguration mainColor];
  [aColor setFill];
  CGContextAddPath(context, visiblePath);
  CGContextFillPath(context);
  
  CGMutablePathRef path = CGPathCreateMutable();
  CGPathAddRect(path, NULL, CGRectInset(bounds, -42, -42));
  CGPathAddPath(path, NULL, visiblePath);
  CGPathCloseSubpath(path);
  CGContextAddPath(context, visiblePath);
  CGContextClip(context);
  
  aColor = [UIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.5f];
  CGContextSaveGState(context);
  CGContextSetShadowWithColor(context, CGSizeMake(0.0f, 0.0f), 5.0f, [aColor CGColor]);
  [aColor setFill];
  CGContextSaveGState(context);
  CGContextAddPath(context, path);
  CGContextEOFillPath(context);
  CGPathRelease(path);
  CGPathRelease(visiblePath);
}

- (void)didChangePreferredContentSize
{
  self.messageLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleCaption1 multiplier:1.2];
}

#pragma mark -

- (void)setState:(TPPBookButtonsState const)state
{
  _state = state;
  
  NSString *newMessageString = @"";
  switch(state) {
    case TPPBookButtonsStateCanBorrow:
      newMessageString = NSLocalizedString(@"This book is available to borrow.", nil);
      break;
    case TPPBookButtonsStateCanHold:
      newMessageString = NSLocalizedString(@"All licenses of this book are currently checked out.", nil);
      break;
    case TPPBookButtonsStateDownloadNeeded:
      newMessageString = NSLocalizedString(@"Your book has not yet been downloaded.", nil);
      break;
    case TPPBookButtonsStateDownloadSuccessful:
      newMessageString = [self messageStringForNYPLBookButtonStateSuccessful];
      break;
    case TPPBookButtonsStateHolding:
      newMessageString = [self messageStringForNYPLBookButtonsStateHolding];
      break;
    case TPPBookButtonsStateHoldingFOQ:
      newMessageString = [NSString stringWithFormat:NSLocalizedString(@"This reservation will be automatically cancelled in %@.", nil),
                                [self.book.defaultAcquisition.availability.until longTimeUntilString]];
      break;
    case TPPBookButtonsStateUsed:
      newMessageString = NSLocalizedString(@"Your book is ready to read!", nil);
      break;
    case TPPBookButtonsStateDownloadInProgress:
      break;
    default:
      break;
  }
  
  if (!self.messageLabel.text) {
    self.messageLabel.text = newMessageString;
  } else if (![self.messageLabel.text isEqualToString:newMessageString]){
    CGFloat duration = 0.3f;
    [UIView animateWithDuration:duration animations:^{
      self.messageLabel.alpha = 0.0f;
    } completion:^(__unused BOOL finished) {
      self.messageLabel.alpha = 0.0f;
      self.messageLabel.text = newMessageString;
      [UIView animateWithDuration:duration animations:^{
        self.messageLabel.alpha = 1.0f;
      } completion:^(__unused BOOL finished) {
        self.messageLabel.alpha = 1.0f;
      }];
    }];
  }
}

-(NSString *)messageStringForNYPLBookButtonsStateHolding
{
  
  __block NSUInteger holdPosition = 0;
  __block TPPOPDSAcquisitionAvailabilityCopies copiesTotal = 0;

  [self.book.defaultAcquisition.availability
   matchUnavailable:nil
   limited:nil
   unlimited:nil
   reserved:^(TPPOPDSAcquisitionAvailabilityReserved *const _Nonnull reserved) {
     holdPosition = reserved.holdPosition;
     copiesTotal = reserved.copiesTotal;
   }
   ready:nil];
  
  NSString *timeUntilString = [self.book.defaultAcquisition.availability.until longTimeUntilString];

  NSString *newMessageString;
  if (timeUntilString != nil) {
    newMessageString = [NSString stringWithFormat:NSLocalizedString(@"Available for checkout in less than %@.", nil), timeUntilString];

    if (holdPosition > 0 && copiesTotal > 0) {
      NSString *positionString = [NSString stringWithFormat:NSLocalizedString(@"\n#You are %ld in line for %ld copies.", @"Describe the line that a person is waiting in for a total number of books that are available for everyone to check out, to help tell them how long they will be waiting."), (unsigned long)holdPosition, (unsigned long)copiesTotal];
      return [newMessageString stringByAppendingString:positionString];
    }

    return newMessageString;
  } else {
    return [NSString stringWithFormat:NSLocalizedString(@"You are %ld in line for %ld copies.", nil), (long)holdPosition, (long)copiesTotal];
  }
}

-(NSString *)messageStringForNYPLBookButtonStateSuccessful
{
  NSString *message = NSLocalizedString(@"Your book is ready to read!", nil);
  if (self.book.defaultAcquisition.availability.until) {
    NSString *timeUntilString = [self.book.defaultAcquisition.availability.until longTimeUntilString];
    NSString *timeEstimateMessage = [NSString stringWithFormat:NSLocalizedString(@"It will expire in %@.", @"Tell the user how much time they have left for the book they have borrowed."),timeUntilString];
    return [NSString stringWithFormat:@"%@\n%@",message,timeEstimateMessage];
  } else {
    return message;
  }
}

@end

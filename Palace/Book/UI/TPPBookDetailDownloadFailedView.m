@import PureLayout;

#import "Palace-Swift.h"

#import "TPPConfiguration.h"
#import "TPPLinearView.h"
#import "UIView+TPPViewAdditions.h"
#import "UIFont+TPPSystemFontOverride.h"
#import "TPPBookDetailDownloadFailedView.h"

@interface TPPBookDetailDownloadFailedView ()

@property (nonatomic) TPPRoundedButton *cancelButton;
@property (nonatomic) TPPLinearView *cancelTryAgainLinearView;
@property (nonatomic) UILabel *messageLabel;
@property (nonatomic) TPPRoundedButton *tryAgainButton;

@end

@implementation TPPBookDetailDownloadFailedView

- (instancetype)init
{
  self = [super init];
  if(!self) return nil;
  
  self.backgroundColor = [TPPConfiguration mainColor];
  
  self.messageLabel = [[UILabel alloc] init];
  self.messageLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
  self.messageLabel.textAlignment = NSTextAlignmentCenter;
  self.messageLabel.textColor = [TPPConfiguration backgroundColor];
  self.messageLabel.text = NSLocalizedString(@"The download could not be completed.\nScroll down to 'View Issues' to see details.", nil);
  self.messageLabel.numberOfLines = 0;
  [self addSubview:self.messageLabel];
  [self.messageLabel autoPinEdgesToSuperviewEdges];
  
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

- (void)didChangePreferredContentSize
{
  self.messageLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
}

- (void)configureFailMessageWithProblemDocument:(TPPProblemDocument *)problemDoc {
  if (problemDoc != nil) {
    self.messageLabel.text = NSLocalizedString(@"The download could not be completed.\nScroll down to 'View Issues' to see details.", nil);
  } else {
    self.messageLabel.text = NSLocalizedString(@"The download could not be completed.", nil);
  }
}

@end

#import "UIView+TPPViewAdditions.h"

#import "TPPReloadView.h"
#import "Palace-Swift.h"

@interface TPPReloadView ()

@property (nonatomic) UILabel *messageLabel;
@property (nonatomic) TPPRoundedButton *reloadButton;
@property (nonatomic) UILabel *titleLabel;

@end

static CGFloat const width = 280;

@implementation TPPReloadView

#pragma mark NSObject

- (instancetype)init
{
  self = [super initWithFrame:CGRectMake(0, 0, width, 0)];
  if(!self) return nil;
  
  self.titleLabel = [[UILabel alloc] init];
  self.titleLabel.font = [UIFont boldPalaceFontOfSize:17];
  self.titleLabel.text = NSLocalizedString(@"Connection Failed", nil);
  self.titleLabel.textColor = [UIColor grayColor];
  [self addSubview:self.titleLabel];
  
  self.messageLabel = [[UILabel alloc] init];
  self.messageLabel.numberOfLines = 3;
  self.messageLabel.textAlignment = NSTextAlignmentCenter;
  self.messageLabel.font = [UIFont palaceFontOfSize:12];
  [self setDefaultMessage];
  self.messageLabel.textColor = [UIColor grayColor];
  [self addSubview:self.messageLabel];
  
  self.reloadButton = [[TPPRoundedButton alloc] initWithType:TPPRoundedButtonTypeNormal isFromDetailView:NO];
  [self.reloadButton setTitle:NSLocalizedString(@"Try Again", nil)
                     forState:UIControlStateNormal];
  [self.reloadButton addTarget:self
                        action:@selector(didSelectReload)
              forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:self.reloadButton];
  
  [self layoutIfNeeded];
  
  self.frame = CGRectMake(0, 0, width, CGRectGetMaxY(self.reloadButton.frame));
  
  return self;
}

#pragma mark UIView

- (void)layoutSubviews
{
  [super layoutSubviews];
  CGFloat const padding = 5.0;
  
  {
    [self.titleLabel sizeToFit];
    [self.titleLabel centerInSuperview];
    CGRect frame = self.titleLabel.frame;
    frame.origin.y = 0;
    self.titleLabel.frame = frame;
  }
  
  {
    CGFloat h = [self.messageLabel sizeThatFits:
                 CGSizeMake(CGRectGetWidth(self.frame), CGFLOAT_MAX)].height;
    
    self.messageLabel.frame = CGRectMake(0,
                                         CGRectGetMaxY(self.titleLabel.frame) + padding,
                                         CGRectGetWidth(self.frame),
                                         h);
  }
  
  {
    [self.reloadButton sizeToFit];
    [self.reloadButton centerInSuperview];
    CGRect frame = self.reloadButton.frame;
    frame.origin.y = CGRectGetMaxY(self.messageLabel.frame) + padding;
    self.reloadButton.frame = frame;
  }
}

#pragma mark -

- (void)setDefaultMessage
{
  self.messageLabel.text = NSLocalizedString(@"Check Connection", nil);
  [self setNeedsLayout];
}

- (void)setMessage:(NSString *)msg
{
  self.messageLabel.text = msg;
  [self setNeedsLayout];
}

- (void)didSelectReload
{
  if(self.handler) {
    self.handler();
  }

  [self setDefaultMessage];
}

@end

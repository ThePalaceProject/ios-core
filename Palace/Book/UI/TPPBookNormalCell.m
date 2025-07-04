@import PureLayout;

#import "TPPAttributedString.h"

#import "TPPConfiguration.h"
#import "TPPBookButtonsView.h"
#import "Palace-Swift.h"

#import "TPPBookNormalCell.h"

@interface TPPBookNormalCell ()

@property (nonatomic) UILabel *authors;
@property (nonatomic) TPPBookButtonsView *buttonsView;
@property (nonatomic) UILabel *title;
@property (nonatomic) UIImageView *unreadImageView;
@property (nonatomic) UIImageView *contentBadge;
@property (nonatomic) UILabel *holdingInfoLabel;

@end

@implementation TPPBookNormalCell

#pragma mark UIView


- (void)layoutSubviews {
  [super layoutSubviews];

  CGRect content = [self contentFrame];

  CGFloat const vPad = 5.0;
  CGFloat const hPad = 20.0;
  CGFloat const spacing = 7.0;

  CGFloat coverH = CGRectGetHeight(content) - (2 * vPad);
  CGFloat coverW = coverH * (10.0 / 12.0);
  self.cover.frame = CGRectMake(hPad,
                                vPad,
                                coverW,
                                coverH);
  self.cover.contentMode = UIViewContentModeScaleAspectFit;

  CGFloat textX = CGRectGetMaxX(self.cover.frame) + spacing;
  CGFloat textW = CGRectGetWidth(content) - textX - hPad;

  CGSize titleSize = [self.title sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)];
  self.title.frame = CGRectMake(textX,
                                vPad,
                                textW,
                                titleSize.height + vPad);

  CGSize authSize = [self.authors sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)];
  self.authors.frame = CGRectMake(textX,
                                  CGRectGetMaxY(self.title.frame),
                                  textW,
                                  authSize.height);

  CGSize btnSize = [self.buttonsView sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)];
  CGFloat btnY = CGRectGetHeight(content) - vPad - btnSize.height;
  self.buttonsView.frame = CGRectMake(textX,
                                      btnY,
                                      btnSize.width,
                                      btnSize.height);

  CGRect unreadF = self.unreadImageView.frame;
  unreadF.origin.x = CGRectGetMinX(self.cover.frame)
                    - CGRectGetWidth(unreadF)
                    - spacing;
  unreadF.origin.y = vPad;
  self.unreadImageView.frame = unreadF;
}

#pragma mark -

- (void)setBook:(TPPBook *const)book
{
  _book = book;
  
  if(!self.authors) {
    self.authors = [[UILabel alloc] init];
    self.authors.font = [UIFont palaceFontOfSize:12];
    [self.contentView addSubview:self.authors];
  }
  
  if(!self.cover) {
    self.cover = [[UIImageView alloc] init];
    if (@available(iOS 11.0, *)) {
      self.cover.accessibilityIgnoresInvertColors = YES;
    }
    [self.contentView addSubview:self.cover];
  }

  if(!self.title) {
    self.title = [[UILabel alloc] init];
    self.title.numberOfLines = 2;
    self.title.font = [UIFont palaceFontOfSize:17];
    [self.contentView addSubview:self.title];
    [self.contentView setNeedsLayout];
  }

  if(!self.buttonsView) {
    self.buttonsView = [[TPPBookButtonsView alloc] init];
    self.buttonsView.delegate = self.delegate;
    self.buttonsView.showReturnButtonIfApplicable = YES;
    [self.contentView addSubview:self.buttonsView];
    self.buttonsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.buttonsView autoPinEdge:ALEdgeLeft toEdge:ALEdgeLeft ofView:self.title];
  }
  self.buttonsView.book = book;

  if (!self.holdingInfoLabel) {
     self.holdingInfoLabel = [[UILabel alloc] init];
     self.holdingInfoLabel.font = [UIFont palaceFontOfSize:12];
     self.holdingInfoLabel.textColor = [UIColor secondaryLabelColor];
     self.holdingInfoLabel.numberOfLines = 0;
     self.holdingInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
     [self.contentView addSubview:self.holdingInfoLabel];
     [self.holdingInfoLabel autoPinEdge:ALEdgeTop
                                toEdge:ALEdgeBottom
                                ofView:self.buttonsView
                            withOffset:4];
     [self.holdingInfoLabel autoPinEdge:ALEdgeLeft
                                toEdge:ALEdgeLeft
                                ofView:self.title];
     [self.holdingInfoLabel autoMatchDimension:ALDimensionWidth
                                   toDimension:ALDimensionWidth
                                   ofView:self.title];
    [self.holdingInfoLabel autoPinEdge:ALEdgeBottom
                                toEdge:ALEdgeBottom
                                ofView:self.contentView];
   }

   ReservationDetails *details = [book getReservationDetails];
   NSString *ordinal = [TPPBook ordinalStringFor:details.holdPosition];
   NSString *copies = details.copiesAvailable == 1 ? @"copy" : @"copies";
   self.holdingInfoLabel.text = [NSString stringWithFormat:
     NSLocalizedString(@"You are %@ in line. %ld %@ in use.", nil),
     ordinal,
     (long)details.copiesAvailable,
     copies
   ];
    
  if(!self.unreadImageView) {
    self.unreadImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Unread"]];
    self.unreadImageView.image = [self.unreadImageView.image
                                  imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.unreadImageView.tintColor = [TPPConfiguration accentColor];
    [self.contentView addSubview:self.unreadImageView];
  }
  
  self.authors.attributedText = TPPAttributedStringForAuthorsFromString(book.authors);
  self.cover.image = nil;
  self.title.attributedText = TPPAttributedStringForTitleFromString(book.title);
  
  if (!self.contentBadge) {
    self.contentBadge = [[TPPContentBadgeImageView alloc] initWithBadgeImage:TPPBadgeImageAudiobook];
  }
  if ([book defaultBookContentType] == TPPBookContentTypeAudiobook) {
    self.title.accessibilityLabel = [book.title stringByAppendingString:@". Audiobook."];
    [TPPContentBadgeImageView pinWithBadge:self.contentBadge toView:self.cover];
    self.contentBadge.hidden = NO;
  } else {
    self.title.accessibilityLabel = nil;
    self.contentBadge.hidden = YES;
  }
  
  // This avoids hitting the server constantly when scrolling within a category and ensures images
  // will still be there when the user scrolls back up. It also avoids creating tasks and refetching
  // images when the collection view reloads its data in response to an additional page being
  // fetched (which otherwise would cause a flickering effect and pointless bandwidth usage).
  self.cover.image = [[TPPBookRegistry shared] cachedThumbnailImageFor:book];
  
  if (!self.cover.image) {
    [[TPPBookRegistry shared]
     thumbnailImageFor:book
     handler:^(UIImage *const image) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if ([book.identifier isEqualToString:self.book.identifier]) {
          self.cover.image = image;
        }
      });
    }];
  }

  [self setNeedsLayout];
}

- (void)setDelegate:(id<TPPBookButtonsDelegate>)delegate
{
  _delegate = delegate;
  self.buttonsView.delegate = delegate;
}

- (void)setState:(TPPBookButtonsState const)state
{
  _state = state;
  self.buttonsView.state = state;
  self.unreadImageView.hidden = (state != TPPBookButtonsStateDownloadSuccessful);
  BOOL isHolding = (state == TPPBookButtonsStateHolding);
  self.holdingInfoLabel.hidden = !isHolding;

  [self setNeedsLayout];
}

@end

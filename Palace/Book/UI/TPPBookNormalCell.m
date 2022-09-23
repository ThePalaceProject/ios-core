@import PureLayout;
#import "TPPAttributedString.h"

#import "TPPBookRegistry.h"
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

@end

@implementation TPPBookNormalCell

#pragma mark UIView

- (void)layoutSubviews
{
  [super layoutSubviews];
  self.cover.frame = CGRectMake(20,
                                5,
                                (CGRectGetHeight([self contentFrame]) - 10) * (10 / 12.0),
                                CGRectGetHeight([self contentFrame]) - 10);
  self.cover.contentMode = UIViewContentModeScaleAspectFit;

  // The extra five height pixels account for a bug in |sizeThatFits:| that does not properly take
  // into account |lineHeightMultiple|.
  CGFloat const titleWidth = CGRectGetWidth([self contentFrame]) - 120;
  self.title.frame = CGRectMake(115,
                                5,
                                titleWidth,
                                [self.title sizeThatFits:
                                 CGSizeMake(titleWidth, CGFLOAT_MAX)].height + 5);
  
  [self.authors sizeToFit];
  CGRect authorFrame = self.authors.frame;
  authorFrame.origin = CGPointMake(115, CGRectGetMaxY(self.title.frame));
  authorFrame.size.width = CGRectGetWidth([self contentFrame]) - 120;
  self.authors.frame = authorFrame;
  
  [self.buttonsView sizeToFit];
  CGRect frame = self.buttonsView.frame;
  frame.origin = CGPointMake(115,
                             (CGRectGetHeight([self contentFrame]) -
                              CGRectGetHeight(frame) - 5));
  self.buttonsView.frame = frame;
  CGRect unreadImageViewFrame = self.unreadImageView.frame;
  unreadImageViewFrame.origin.x = (CGRectGetMinX(self.cover.frame) -
                                   CGRectGetWidth(unreadImageViewFrame) - 5);
  unreadImageViewFrame.origin.y = 5;
  self.unreadImageView.frame = unreadImageViewFrame;
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
    [self.buttonsView autoPinEdge:ALEdgeBottom toEdge:ALEdgeBottom ofView:self.cover];
  }
  self.buttonsView.book = book;
  
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
  self.cover.image = [[TPPBookRegistry sharedRegistry] cachedThumbnailImageForBook:book];
  
  if(!self.cover.image) {
    [[TPPBookRegistry sharedRegistry]
     thumbnailImageForBook:book
     handler:^(UIImage *const image) {
       // This check prevents old operations from overwriting cover images in the case of cells
       // being reused before those operations completed.
       if([book.identifier isEqualToString:self.book.identifier]) {
         self.cover.image = image;
       }
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
  [self setNeedsLayout];
}

@end

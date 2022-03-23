#import "TPPAttributedString.h"
#import "TPPBook.h"
#import "TPPBookCellDelegate.h"
#import "TPPBookButtonsView.h"
#import "TPPBookDetailDownloadFailedView.h"
#import "TPPBookDetailDownloadingView.h"
#import "TPPBookDetailNormalView.h"
#import "TPPBookRegistry.h"
#import "TPPCatalogGroupedFeed.h"
#import "TPPCatalogGroupedFeedViewController.h"
#import "TPPCatalogLaneCell.h"
#import "TPPCatalogUngroupedFeed.h"
#import "TPPConfiguration.h"
#import "TPPBookDetailView.h"
#import "TPPConfiguration.h"
#import "TPPRootTabBarController.h"
#import "TPPOPDSAcquisition.h"
#import "TPPOPDSFeed.h"
#import "Palace-Swift.h"
#import "UIFont+TPPSystemFontOverride.h"

#import <PureLayout/PureLayout.h>

@interface TPPBookDetailView () <TPPBookDownloadCancellationDelegate, BookDetailTableViewDelegate>

@property (nonatomic, weak) id<TPPBookDetailViewDelegate, TPPCatalogLaneCellDelegate> detailViewDelegate;

@property (nonatomic) BOOL didSetupConstraints;
@property (nonatomic) UIView *contentView;
@property (nonatomic) UIVisualEffectView *visualEffectView;

@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *subtitleLabel;
@property (nonatomic) UILabel *audiobookLabel;
@property (nonatomic) UILabel *authorsLabel;
@property (nonatomic) UIImageView *coverImageView;
@property (nonatomic) UIImageView *blurCoverImageView;
@property (nonatomic) TPPContentBadgeImageView *contentTypeBadge;
@property (nonatomic) UIButton *closeButton;

@property (nonatomic) TPPBookButtonsView *buttonsView;
@property (nonatomic) TPPBookDetailDownloadFailedView *downloadFailedView;
@property (nonatomic) TPPBookDetailDownloadingView *downloadingView;
@property (nonatomic) TPPBookDetailNormalView *normalView;

@property (nonatomic) UILabel *summarySectionLabel;
@property (nonatomic) UITextView *summaryTextView;
@property (nonatomic) NSLayoutConstraint *textHeightConstraint;
@property (nonatomic) UIButton *readMoreLabel;

@property (nonatomic) UILabel *infoSectionLabel;
@property (nonatomic) UILabel *publishedLabelKey;
@property (nonatomic) UILabel *publisherLabelKey;
@property (nonatomic) UILabel *categoriesLabelKey;
@property (nonatomic) UILabel *distributorLabelKey;
@property (nonatomic) UILabel *narratorsLabelKey;
@property (nonatomic) UILabel *publishedLabelValue;
@property (nonatomic) UILabel *publisherLabelValue;
@property (nonatomic) UILabel *categoriesLabelValue;
@property (nonatomic) UILabel *distributorLabelValue;
@property (nonatomic) UILabel *narratorsLabelValue;

@property (nonatomic) TPPBookDetailTableView *footerTableView;

@property (nonatomic) UIView *topFootnoteSeparater;
@property (nonatomic) UIView *bottomFootnoteSeparator;

@end

static CGFloat const SubtitleBaselineOffset = 10;
static CGFloat const AuthorBaselineOffset = 12;
static CGFloat const CoverImageAspectRatio = 0.8;
static CGFloat const CoverImageMaxWidth = 160.0;
static CGFloat const TitleLabelMinimumWidth = 185.0;
static CGFloat const NormalViewMinimumHeight = 38.0;
static CGFloat const VerticalPadding = 10.0;
static CGFloat const MainTextPaddingLeft = 10.0;
static NSString *DetailHTMLTemplate = nil;

@implementation TPPBookDetailView

// designated initializer
- (instancetype)initWithBook:(TPPBook *const)book
                    delegate:(id)delegate
{
  self = [super init];
  if(!self) return nil;
  
  if(!book) {
    @throw NSInvalidArgumentException;
  }
  
  self.book = book;
  self.detailViewDelegate = delegate;
  self.backgroundColor = [TPPConfiguration backgroundColor];
  self.alwaysBounceVertical = YES;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  
  self.contentView = [[UIView alloc] init];
  self.contentView.layoutMargins = UIEdgeInsetsMake(self.layoutMargins.top,
                                                    self.layoutMargins.left+12,
                                                    self.layoutMargins.bottom,
                                                    self.layoutMargins.right+12);
  
  [self createHeaderLabels];
  [self createButtonsView];
  [self createBookDescriptionViews];
  [self createFooterLabels];
  [self createDownloadViews];
  [self updateFonts];
  
  [self addSubview:self.contentView];
  [self.contentView addSubview:self.blurCoverImageView];
  [self.contentView addSubview:self.visualEffectView];
  [self.contentView addSubview:self.coverImageView];
  [self.contentView addSubview:self.contentTypeBadge];
  [self.contentView addSubview:self.titleLabel];
  [self.contentView addSubview:self.subtitleLabel];
  [self.contentView addSubview:self.audiobookLabel];
  [self.contentView addSubview:self.authorsLabel];
  [self.contentView addSubview:self.buttonsView];
  [self.contentView addSubview:self.summarySectionLabel];
  [self.contentView addSubview:self.summaryTextView];
  [self.contentView addSubview:self.readMoreLabel];
  
  [self.contentView addSubview:self.topFootnoteSeparater];
  [self.contentView addSubview:self.infoSectionLabel];
  [self.contentView addSubview:self.publishedLabelKey];
  [self.contentView addSubview:self.publisherLabelKey];
  [self.contentView addSubview:self.categoriesLabelKey];
  [self.contentView addSubview:self.distributorLabelKey];
  [self.contentView addSubview:self.narratorsLabelKey];
  [self.contentView addSubview:self.publishedLabelValue];
  [self.contentView addSubview:self.publisherLabelValue];
  [self.contentView addSubview:self.categoriesLabelValue];
  [self.contentView addSubview:self.distributorLabelValue];
  [self.contentView addSubview:self.narratorsLabelValue];
  [self.contentView addSubview:self.footerTableView];
  [self.contentView addSubview:self.bottomFootnoteSeparator];
  
  if(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
     [[TPPRootTabBarController sharedController] traitCollection].horizontalSizeClass != UIUserInterfaceSizeClassCompact) {
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:NSLocalizedString(@"Close", nil) forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[TPPConfiguration mainColor] forState:UIControlStateNormal];
    [self.closeButton setContentHorizontalAlignment:UIControlContentHorizontalAlignmentRight];
    [self.closeButton setContentEdgeInsets:UIEdgeInsetsMake(0, 2, 0, 0)];
    [self.closeButton addTarget:self action:@selector(closeButtonPressed) forControlEvents:UIControlEventTouchDown];
    [self.contentView addSubview:self.closeButton];
  }

  return self;
}

- (void)updateFonts
{
  self.titleLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleHeadline];
  self.subtitleLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleCaption2];
  self.audiobookLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleCaption2];
  self.authorsLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleCaption2];
  self.readMoreLabel.titleLabel.font = [UIFont palaceFontOfSize:14];
  self.summarySectionLabel.font = [UIFont customBoldFontForTextStyle:UIFontTextStyleCaption1];
  self.infoSectionLabel.font = [UIFont customBoldFontForTextStyle:UIFontTextStyleCaption1];
  [self.footerTableView reloadData];
}

- (void)createButtonsView
{
  self.buttonsView = [[TPPBookButtonsView alloc] init];
  [self.buttonsView configureForBookDetailsContext];
  self.buttonsView.translatesAutoresizingMaskIntoConstraints = NO;
  self.buttonsView.showReturnButtonIfApplicable = YES;
  self.buttonsView.delegate = [TPPBookCellDelegate sharedDelegate];
  self.buttonsView.downloadingDelegate = self;
  self.buttonsView.book = self.book;
}

- (void)createBookDescriptionViews
{
  self.summarySectionLabel = [[UILabel alloc] init];
  self.summarySectionLabel.text = NSLocalizedString(@"Description", nil);
  self.infoSectionLabel = [[UILabel alloc] init];
  self.infoSectionLabel.text = NSLocalizedString(@"Information", nil);
  
  self.summaryTextView = [[UITextView alloc] init];
  self.summaryTextView.backgroundColor = [UIColor clearColor];
  self.summaryTextView.scrollEnabled = NO;
  self.summaryTextView.editable = NO;
  self.summaryTextView.clipsToBounds = YES;
  self.summaryTextView.textContainer.lineFragmentPadding = 0;
  self.summaryTextView.textContainerInset = UIEdgeInsetsZero;
  self.summaryTextView.adjustsFontForContentSizeCategory = YES;

  NSString *htmlString = [[NSString stringWithFormat:DetailHTMLTemplate,
                           [UIFont systemFontOfSize: 12],
                           self.book.summary ?: @""] stringByDecodingHTMLEntities];

  NSData *htmlData = [htmlString dataUsingEncoding:NSUnicodeStringEncoding];
  NSAttributedString *attrString;
  if (htmlData) {
    NSError *error = nil;
    attrString = [[NSAttributedString alloc]
                  initWithData:htmlData
                  options:@{NSDocumentTypeDocumentAttribute:
                              NSHTMLTextDocumentType}
                  documentAttributes:nil
                  error:&error];
    if (error) {
      TPPLOG_F(@"Attributed string rendering error for %@ book description: %@",
                [self.book loggableShortString], error);
    }
  } else {
    attrString = [[NSAttributedString alloc] initWithString:@""];
  }
  self.summaryTextView.attributedText = attrString;
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    // this needs to happen asynchronously because the HTML text may overwrite
    // our color
    self.summaryTextView.textColor = UIColor.defaultLabelColor;
  }];

  self.readMoreLabel = [[UIButton alloc] init];
  self.readMoreLabel.hidden = YES;
  self.readMoreLabel.titleLabel.textAlignment = NSTextAlignmentRight;
  [self.readMoreLabel addTarget:self action:@selector(readMoreTapped:) forControlEvents:UIControlEventTouchUpInside];
  
  [self.readMoreLabel setContentHorizontalAlignment:UIControlContentHorizontalAlignmentRight];
  [self.readMoreLabel setTitle:NSLocalizedString(@"More...", nil) forState:UIControlStateNormal];
  [self.readMoreLabel setTitleColor:[TPPConfiguration mainColor] forState:UIControlStateNormal];
}

- (void)createHeaderLabels
{
  UIVisualEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
  self.visualEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];

  self.coverImageView = [[UIImageView alloc] init];
  self.coverImageView.contentMode = UIViewContentModeScaleAspectFit;
  if (@available(iOS 11.0, *)) {
    self.coverImageView.accessibilityIgnoresInvertColors = YES;
  }
  self.blurCoverImageView = [[UIImageView alloc] init];
  self.blurCoverImageView.contentMode = UIViewContentModeScaleAspectFit;
  if (@available(iOS 11.0, *)) {
    self.blurCoverImageView.accessibilityIgnoresInvertColors = YES;
  }
  self.blurCoverImageView.alpha = 0.4f;

  [[TPPBookRegistry sharedRegistry]
   coverImageForBook:self.book handler:^(UIImage *image) {
    self.coverImageView.image = image;
    self.blurCoverImageView.image = image;
  }];

  self.audiobookLabel = [[UILabel alloc] init];
  self.audiobookLabel.hidden = YES;
  self.contentTypeBadge = [[TPPContentBadgeImageView alloc] initWithBadgeImage:TPPBadgeImageAudiobook];
  self.contentTypeBadge.hidden = YES;

  if ([self.book defaultBookContentType] == TPPBookContentTypeAudiobook) {
    self.contentTypeBadge.hidden = NO;
    self.audiobookLabel.attributedText = TPPAttributedStringForTitleFromString(NSLocalizedString(@"Audiobook", nil));
    self.audiobookLabel.hidden = NO;
  }

  self.titleLabel = [[UILabel alloc] init];
  self.titleLabel.numberOfLines = 2;
  self.titleLabel.attributedText = TPPAttributedStringForTitleFromString(self.book.title);

  self.subtitleLabel = [[UILabel alloc] init];
  self.subtitleLabel.attributedText = TPPAttributedStringForTitleFromString(self.book.subtitle);
  self.subtitleLabel.numberOfLines = 3;


  self.authorsLabel = [[UILabel alloc] init];
  self.authorsLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
  self.authorsLabel.numberOfLines = 2;
  if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
      [[TPPRootTabBarController sharedController] traitCollection].horizontalSizeClass != UIUserInterfaceSizeClassCompact) {
    self.authorsLabel.text = self.book.authors;
  } else {
    self.authorsLabel.attributedText = TPPAttributedStringForAuthorsFromString(self.book.authors);
  }
}

- (void)createDownloadViews
{
  self.normalView = [[TPPBookDetailNormalView alloc] init];
  self.normalView.translatesAutoresizingMaskIntoConstraints = NO;
  self.normalView.book = self.book;
  self.normalView.hidden = YES;

  self.downloadFailedView = [[TPPBookDetailDownloadFailedView alloc] init];
  self.downloadFailedView.hidden = YES;
  
  self.downloadingView = [[TPPBookDetailDownloadingView alloc] init];
  self.downloadingView.hidden = YES;
  
  [self.contentView addSubview:self.normalView];
  [self.contentView addSubview:self.downloadFailedView];
  [self.contentView addSubview:self.downloadingView];
}

- (void)createFooterLabels
{
  NSDateFormatter *const dateFormatter = [[NSDateFormatter alloc] init];
  dateFormatter.timeStyle = NSDateFormatterNoStyle;
  dateFormatter.dateStyle = NSDateFormatterLongStyle;
  dateFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  
  NSString *const publishedKeyString =
  self.book.published
  ? [NSString stringWithFormat:@"%@: ",
     NSLocalizedString(@"Published", nil)]
  : nil;
  
  NSString *const publisherKeyString =
  self.book.publisher
  ? [NSString stringWithFormat:@"%@: ",
     NSLocalizedString(@"Publisher", nil)]
  : nil;
  
  NSString *const categoriesKeyString =
  self.book.categoryStrings.count
  ? [NSString stringWithFormat:@"%@: ",
     (self.book.categoryStrings.count == 1
      ? NSLocalizedString(@"Category", nil)
      : NSLocalizedString(@"Categories", nil))]
  : nil;
  
  NSString *const narratorsKeyString =
    self.book.narrators ? [NSString stringWithFormat:@"%@: ", NSLocalizedString(@"Narrators", nil)] : nil;
  
  NSString *const categoriesValueString = self.book.categories;
  NSString *const publishedValueString = self.book.published ? [dateFormatter stringFromDate:self.book.published] : nil;
  NSString *const publisherValueString = self.book.publisher;
  NSString *const distributorKeyString = self.book.distributor ? [NSString stringWithFormat:NSLocalizedString(@"BookDetailViewControllerDistributedByFormat", nil)] : nil;
  NSString *const narratorsValueString = self.book.narrators;
  
  if (!categoriesValueString && !publishedValueString && !publisherValueString && !self.book.distributor) {
    self.topFootnoteSeparater.hidden = YES;
    self.bottomFootnoteSeparator.hidden = YES;
  }
  
  self.categoriesLabelKey = [self createFooterLabelWithString:categoriesKeyString alignment:NSTextAlignmentRight];
  self.publisherLabelKey = [self createFooterLabelWithString:publisherKeyString alignment:NSTextAlignmentRight];
  self.publishedLabelKey = [self createFooterLabelWithString:publishedKeyString alignment:NSTextAlignmentRight];
  self.distributorLabelKey = [self createFooterLabelWithString:distributorKeyString alignment:NSTextAlignmentRight];
  self.narratorsLabelKey = [self createFooterLabelWithString:narratorsKeyString alignment:NSTextAlignmentRight];
  
  self.categoriesLabelValue = [self createFooterLabelWithString:categoriesValueString alignment:NSTextAlignmentLeft];
  self.categoriesLabelValue.numberOfLines = 2;
  self.publisherLabelValue = [self createFooterLabelWithString:publisherValueString alignment:NSTextAlignmentLeft];
  self.publisherLabelValue.numberOfLines = 2;
  self.publishedLabelValue = [self createFooterLabelWithString:publishedValueString alignment:NSTextAlignmentLeft];
  self.distributorLabelValue = [self createFooterLabelWithString:self.book.distributor alignment:NSTextAlignmentLeft];
  self.narratorsLabelValue = [self createFooterLabelWithString:narratorsValueString alignment:NSTextAlignmentLeft];
  self.narratorsLabelValue.numberOfLines = 0;
  
  self.topFootnoteSeparater = [[UIView alloc] init];
  self.topFootnoteSeparater.backgroundColor = [UIColor lightGrayColor];
  self.bottomFootnoteSeparator = [[UIView alloc] init];
  self.bottomFootnoteSeparator.backgroundColor = [UIColor lightGrayColor];
  
  self.footerTableView = [[TPPBookDetailTableView alloc] init];
  self.footerTableView.isAccessibilityElement = NO;
  self.tableViewDelegate = [[TPPBookDetailTableViewDelegate alloc] init:self.footerTableView book:self.book];
  self.tableViewDelegate.viewDelegate = self;
  self.tableViewDelegate.laneCellDelegate = self.detailViewDelegate;
  self.footerTableView.delegate = self.tableViewDelegate;
  self.footerTableView.dataSource = self.tableViewDelegate;
  [self.tableViewDelegate load];
}

- (UILabel *)createFooterLabelWithString:(NSString *)string alignment:(NSTextAlignment)alignment
{
  UILabel *label = [[UILabel alloc] init];
  label.textAlignment = alignment;
  label.text = string;
  label.font = [UIFont customFontForTextStyle:UIFontTextStyleCaption2];
  return label;
}

- (void)setupAutolayoutConstraints
{
  [self.contentView autoPinEdgeToSuperviewEdge:ALEdgeTop];
  [self.contentView autoPinEdgeToSuperviewEdge:ALEdgeBottom];
  [self.contentView autoPinEdgeToSuperviewEdge:ALEdgeLeft];
  [self.contentView autoMatchDimension:ALDimensionWidth toDimension:ALDimensionWidth ofView:self];
  
  [self.visualEffectView autoPinEdgesToSuperviewEdgesWithInsets:UIEdgeInsetsZero excludingEdge:ALEdgeBottom];
  [self.visualEffectView autoPinEdge:ALEdgeBottom toEdge:ALEdgeTop ofView:self.normalView];
  
  [self.coverImageView autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.coverImageView autoPinEdgeToSuperviewEdge:ALEdgeTop withInset:VerticalPadding];
  [self.coverImageView autoMatchDimension:ALDimensionWidth toDimension:ALDimensionHeight ofView:self.coverImageView withMultiplier:CoverImageAspectRatio];
  [self.coverImageView autoSetDimension:ALDimensionWidth toSize:CoverImageMaxWidth relation:NSLayoutRelationLessThanOrEqual];
  [self.blurCoverImageView autoPinEdge:ALEdgeLeading toEdge:ALEdgeLeading ofView:self.coverImageView];
  [self.blurCoverImageView autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.coverImageView];
  [self.blurCoverImageView autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.coverImageView];
  [self.blurCoverImageView autoPinEdge:ALEdgeBottom toEdge:ALEdgeBottom ofView:self.coverImageView];

  [TPPContentBadgeImageView pinWithBadge:self.contentTypeBadge toView:self.coverImageView];
  
  [self.titleLabel autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.coverImageView withOffset:MainTextPaddingLeft];
  [self.titleLabel autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.coverImageView];
  [self.titleLabel autoSetDimension:ALDimensionWidth toSize:TitleLabelMinimumWidth relation:NSLayoutRelationGreaterThanOrEqual];
  NSLayoutConstraint *titleLabelConstraint = [self.titleLabel autoPinEdgeToSuperviewMargin:ALEdgeTrailing];
  
  [self.subtitleLabel autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.coverImageView withOffset:MainTextPaddingLeft];
  [self.subtitleLabel autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.titleLabel];
  [self.subtitleLabel autoConstrainAttribute:ALAttributeTop toAttribute:ALAttributeBaseline ofView:self.titleLabel withOffset:SubtitleBaselineOffset];

  [self.audiobookLabel autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.coverImageView withOffset:MainTextPaddingLeft];
  [self.audiobookLabel autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.titleLabel];
  if (self.subtitleLabel.text) {
    [self.audiobookLabel autoConstrainAttribute:ALAttributeTop toAttribute:ALAttributeBaseline ofView:self.subtitleLabel withOffset:AuthorBaselineOffset];
  } else {
    [self.audiobookLabel autoConstrainAttribute:ALAttributeTop toAttribute:ALAttributeBaseline ofView:self.titleLabel withOffset:AuthorBaselineOffset];
  }

  [self.authorsLabel autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.coverImageView withOffset:MainTextPaddingLeft];
  [self.authorsLabel autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.titleLabel];
  if (self.audiobookLabel.text) {
    [self.authorsLabel autoConstrainAttribute:ALAttributeTop toAttribute:ALAttributeBaseline ofView:self.audiobookLabel withOffset:AuthorBaselineOffset];
  } else if (self.subtitleLabel.text) {
    [self.authorsLabel autoConstrainAttribute:ALAttributeTop toAttribute:ALAttributeBaseline ofView:self.subtitleLabel withOffset:AuthorBaselineOffset];
  } else {
    [self.authorsLabel autoConstrainAttribute:ALAttributeTop toAttribute:ALAttributeBaseline ofView:self.titleLabel withOffset:AuthorBaselineOffset];
  }

  [self.buttonsView autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.authorsLabel withOffset:VerticalPadding relation:NSLayoutRelationGreaterThanOrEqual];
  [NSLayoutConstraint autoSetPriority:UILayoutPriorityDefaultLow forConstraints:^{
    [self.buttonsView autoPinEdge:ALEdgeBottom toEdge:ALEdgeBottom ofView:self.coverImageView];
  }];
  [self.buttonsView autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.coverImageView withOffset:MainTextPaddingLeft];
  
  [self.normalView autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.buttonsView withOffset:VerticalPadding];
  [self.normalView autoPinEdgeToSuperviewEdge:ALEdgeRight];
  [self.normalView autoPinEdgeToSuperviewEdge:ALEdgeLeft];
  [self.normalView autoSetDimension:ALDimensionHeight toSize:NormalViewMinimumHeight relation:NSLayoutRelationGreaterThanOrEqual];
  
  [self.downloadingView autoPinEdgeToSuperviewEdge:ALEdgeRight];
  [self.downloadingView autoPinEdgeToSuperviewEdge:ALEdgeLeft];
  [self.downloadingView autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.buttonsView withOffset:VerticalPadding];
  [self.downloadingView autoConstrainAttribute:ALAttributeHeight toAttribute:ALAttributeHeight ofView:self.normalView];

  [self.downloadFailedView autoPinEdgeToSuperviewEdge:ALEdgeRight];
  [self.downloadFailedView autoPinEdgeToSuperviewEdge:ALEdgeLeft];
  [self.downloadFailedView autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.buttonsView withOffset:VerticalPadding];
  [self.downloadFailedView autoConstrainAttribute:ALAttributeHeight toAttribute:ALAttributeHeight ofView:self.normalView];
  
  [self.summarySectionLabel autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.summarySectionLabel autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.normalView withOffset:VerticalPadding + 4];
  
  [self.summaryTextView autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.summarySectionLabel withOffset:VerticalPadding];
  [self.summaryTextView autoPinEdgeToSuperviewMargin:ALEdgeTrailing];
  [self.summaryTextView autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  self.textHeightConstraint = [self.summaryTextView autoSetDimension:ALDimensionHeight toSize:SummaryTextAbbreviatedHeight relation:NSLayoutRelationLessThanOrEqual];

  [self.readMoreLabel autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.readMoreLabel autoPinEdgeToSuperviewMargin:ALEdgeTrailing];
  [self.readMoreLabel autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.summaryTextView];
  [self.readMoreLabel autoPinEdge:ALEdgeBottom toEdge:ALEdgeTop ofView:self.topFootnoteSeparater];
  
  [self.infoSectionLabel autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  
  [self.publishedLabelValue autoPinEdgeToSuperviewMargin:ALEdgeTrailing relation:NSLayoutRelationGreaterThanOrEqual];
  [self.publishedLabelValue autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.infoSectionLabel withOffset:VerticalPadding];
  [self.publishedLabelValue autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.publishedLabelKey withOffset:MainTextPaddingLeft];
  
  [self.publisherLabelValue autoPinEdgeToSuperviewMargin:ALEdgeTrailing relation:NSLayoutRelationGreaterThanOrEqual];
  [self.publisherLabelValue autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.publishedLabelValue];
  [self.publisherLabelValue autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.publisherLabelKey withOffset:MainTextPaddingLeft];
  
  [self.categoriesLabelValue autoPinEdgeToSuperviewMargin:ALEdgeTrailing relation:NSLayoutRelationGreaterThanOrEqual];
  [self.categoriesLabelValue autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.publisherLabelValue];
  [self.categoriesLabelValue autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.categoriesLabelKey withOffset:MainTextPaddingLeft];
  
  [self.distributorLabelValue autoPinEdgeToSuperviewMargin:ALEdgeTrailing relation:NSLayoutRelationGreaterThanOrEqual];
  [self.distributorLabelValue autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.categoriesLabelValue];
  [self.distributorLabelValue autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.distributorLabelKey withOffset:MainTextPaddingLeft];

  [self.narratorsLabelValue autoPinEdgeToSuperviewMargin:ALEdgeTrailing relation:NSLayoutRelationGreaterThanOrEqual];
  [self.narratorsLabelValue autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.distributorLabelValue];
  [self.narratorsLabelValue autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.narratorsLabelKey withOffset:MainTextPaddingLeft];

  [self.publishedLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.publishedLabelKey autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.publisherLabelKey];
  [self.publishedLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.publishedLabelValue];
  [self.publishedLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

  [self.publisherLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.publisherLabelKey autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.categoriesLabelKey];
  [self.publisherLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.publisherLabelValue];
  [self.publisherLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  
  [self.categoriesLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.categoriesLabelKey autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.distributorLabelKey];
  [self.categoriesLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.categoriesLabelValue];
  [self.categoriesLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

  [self.distributorLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.distributorLabelKey autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.narratorsLabelKey];
  [self.distributorLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.distributorLabelValue];
  [self.distributorLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  
  [self.narratorsLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.narratorsLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.narratorsLabelValue];
  [self.narratorsLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];


  if (self.closeButton) {
    [self.closeButton autoPinEdgeToSuperviewMargin:ALEdgeTrailing];
    [self.closeButton autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.titleLabel];
    [self.closeButton autoSetDimension:ALDimensionWidth toSize:80 relation:NSLayoutRelationLessThanOrEqual];
    [NSLayoutConstraint deactivateConstraints:@[titleLabelConstraint]];
    [self.closeButton autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.titleLabel withOffset:MainTextPaddingLeft];
    [self.closeButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  }
  
  [self.topFootnoteSeparater autoSetDimension:ALDimensionHeight toSize: 1.0f / [UIScreen mainScreen].scale];
  [self.topFootnoteSeparater autoPinEdgeToSuperviewEdge:ALEdgeRight];
  [self.topFootnoteSeparater autoPinEdgeToSuperviewMargin:ALEdgeLeft];
  [self.topFootnoteSeparater autoPinEdge:ALEdgeBottom toEdge:ALEdgeTop ofView:self.infoSectionLabel withOffset:-VerticalPadding];
  
  [self.bottomFootnoteSeparator autoSetDimension:ALDimensionHeight toSize: 1.0f / [UIScreen mainScreen].scale];
  [self.bottomFootnoteSeparator autoPinEdgeToSuperviewEdge:ALEdgeRight];
  [self.bottomFootnoteSeparator autoPinEdgeToSuperviewMargin:ALEdgeLeft];
  [self.bottomFootnoteSeparator autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.narratorsLabelValue withOffset:VerticalPadding];
  
  [self.footerTableView autoPinEdgesToSuperviewEdgesWithInsets:UIEdgeInsetsZero excludingEdge:ALEdgeTop];
  [self.footerTableView autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.narratorsLabelValue withOffset:VerticalPadding];
}

#pragma mark NSObject

+ (void)initialize
{
  DetailHTMLTemplate = [NSString
                        stringWithContentsOfURL:[[NSBundle mainBundle]
                                                 URLForResource:@"DetailSummaryTemplate"
                                                 withExtension:@"html"]
                        encoding:NSUTF8StringEncoding
                        error:NULL];
  
  assert(DetailHTMLTemplate);
}

- (void)updateConstraints
{
  if (!self.didSetupConstraints) {
    [self setupAutolayoutConstraints];
    self.didSetupConstraints = YES;
  }
  [super updateConstraints];
}

#pragma mark TPPBookDownloadCancellationDelegate

- (void)didSelectCancelForBookDetailDownloadingView:
(__attribute__((unused)) TPPBookDetailDownloadingView *)bookDetailDownloadingView
{
  [self.detailViewDelegate didSelectCancelDownloadingForBookDetailView:self];
}

- (void)didSelectCancelForBookDetailDownloadFailedView:
(__attribute__((unused)) TPPBookDetailDownloadFailedView *)NYPLBookDetailDownloadFailedView
{
  [self.detailViewDelegate didSelectCancelDownloadFailedForBookDetailView:self];
}

#pragma mark -

- (void)setState:(TPPBookState)state
{
  _state = state;
  
  switch(state) {
    case TPPBookStateUnregistered:
      self.normalView.hidden = NO;
      self.downloadFailedView.hidden = YES;
      [self hideDownloadingView:YES];
      self.buttonsView.hidden = NO;
      self.normalView.state = TPPBookButtonsViewStateWithAvailability(self.book.defaultAcquisition.availability);
      self.buttonsView.state = self.normalView.state;
      break;
    case TPPBookStateDownloadNeeded:
      self.normalView.hidden = NO;
      self.downloadFailedView.hidden = YES;
      [self hideDownloadingView:YES];
      self.buttonsView.hidden = NO;
      self.normalView.state = TPPBookButtonsStateDownloadNeeded;
      self.buttonsView.state = TPPBookButtonsStateDownloadNeeded;
      break;
    case TPPBookStateSAMLStarted:
      self.downloadingView.downloadProgress = 0;
      self.downloadingView.downloadStarted = false;
    case TPPBookStateDownloading:
      self.downloadFailedView.hidden = YES;
      [self hideDownloadingView:NO];
      self.buttonsView.hidden = NO;
      self.buttonsView.state = TPPBookButtonsStateDownloadInProgress;
      break;
    case TPPBookStateDownloadFailed:
      [self.downloadFailedView configureFailMessageWithProblemDocument:[[TPPProblemDocumentCacheManager shared] getLastCachedDoc:self.book.identifier]];
      self.downloadFailedView.hidden = NO;
      [self hideDownloadingView:YES];
      self.buttonsView.hidden = NO;
      self.buttonsView.state = TPPBookButtonsStateDownloadFailed;
      break;
    case TPPBookStateDownloadSuccessful:
      self.normalView.hidden = NO;
      self.downloadFailedView.hidden = YES;
      [self hideDownloadingView:YES];
      self.buttonsView.hidden = NO;
      self.normalView.state = TPPBookButtonsStateDownloadSuccessful;
      self.buttonsView.state = TPPBookButtonsStateDownloadSuccessful;
      break;
    case TPPBookStateHolding:
      self.normalView.hidden = NO;
      self.downloadFailedView.hidden = YES;
      [self hideDownloadingView:YES];
      self.buttonsView.hidden = NO;
      self.normalView.state = TPPBookButtonsViewStateWithAvailability(self.book.defaultAcquisition.availability);
      self.buttonsView.state = self.normalView.state;
      break;
    case TPPBookStateUsed:
      self.normalView.hidden = NO;
      self.downloadFailedView.hidden = YES;
      [self hideDownloadingView:YES];
      self.buttonsView.hidden = NO;
      self.normalView.state = TPPBookButtonsStateUsed;
      self.buttonsView.state = TPPBookButtonsStateUsed;
      break;
    case TPPBookStateUnsupported:
      self.normalView.hidden = NO;
      self.downloadFailedView.hidden = YES;
      [self hideDownloadingView:YES];
      self.buttonsView.hidden = NO;
      self.normalView.state = TPPBookButtonsStateUnsupported;
      self.buttonsView.state = TPPBookButtonsStateUnsupported;
      break;
  }
}

- (void)hideDownloadingView:(BOOL)shouldHide
{
  CGFloat duration = 0.5f;
  if (shouldHide) {
    if (!self.downloadingView.isHidden) {
      [UIView transitionWithView:self.downloadingView
                        duration:duration
                         options:UIViewAnimationOptionTransitionCrossDissolve
                      animations:^{
        self.downloadingView.hidden = YES;
      } completion:^(__unused BOOL finished) {
        self.downloadingView.hidden = YES;
      }];
    }
  } else {
    if (self.downloadingView.isHidden) {
      [UIView transitionWithView:self.downloadingView
                        duration:duration
                         options:UIViewAnimationOptionTransitionCrossDissolve
                      animations:^{
        self.downloadingView.hidden = NO;
      } completion:^(__unused BOOL finished) {
        self.downloadingView.hidden = NO;
      }];
    }
  }
}

- (void)setBook:(TPPBook *)book
{
  _book = book;
  self.normalView.book = book;
  self.buttonsView.book = book;
}

- (double)downloadProgress
{
  return self.downloadingView.downloadProgress;
}

- (void)setDownloadProgress:(double)downloadProgress
{
  self.downloadingView.downloadProgress = downloadProgress;
}

- (BOOL)downloadStarted
{
  return self.downloadingView.downloadStarted;
}

- (void)setDownloadStarted:(BOOL)downloadStarted
{
  self.downloadingView.downloadStarted = downloadStarted;
}

- (void)closeButtonPressed
{
  [self.detailViewDelegate didSelectCloseButton:self];
}

-(BOOL)accessibilityPerformEscape {
  [self.detailViewDelegate didSelectCloseButton:self];
  return YES;
}

- (void)reportProblemTapped
{
  [self.detailViewDelegate didSelectReportProblemForBook:self.book sender:self];
}

- (void)moreBooksTappedForLane:(TPPCatalogLane *)lane
{
  [self.detailViewDelegate didSelectMoreBooksForLane:lane];
}

- (void)readMoreTapped:(__unused UIButton *)sender
{
  self.textHeightConstraint.active = NO;
  [self.readMoreLabel removeFromSuperview];
  [self.topFootnoteSeparater autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.summaryTextView withOffset:VerticalPadding];
}

- (void)viewIssuesTapped {
  [self.detailViewDelegate didSelectViewIssuesForBook:self.book sender:self];
}

@end

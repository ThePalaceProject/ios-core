@import PureLayout;

#import "TPPAttributedString.h"

#import "TPPBookCellDelegate.h"
#import "TPPBookButtonsView.h"
#import "TPPBookDetailDownloadFailedView.h"
#import "TPPBookDetailDownloadingView.h"
#import "TPPBookDetailNormalView.h"
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

@interface TPPBookDetailView () <TPPBookDownloadCancellationDelegate, TPPBookButtonsSampleDelegate, BookDetailTableViewDelegate>

@property (nonatomic, weak) id<TPPBookDetailViewDelegate, TPPCatalogLaneCellDelegate> detailViewDelegate;

@property (nonatomic) BOOL didSetupConstraints;
@property (nonatomic) UIScrollView *scrollView;
@property (nonatomic) UIView *audiobookSampleToolbar;
@property (nonatomic) UIView *containerView;
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
@property (nonatomic) UILabel *bookFormatLabelKey;
@property (nonatomic) UILabel *narratorsLabelKey;
@property (nonatomic) UILabel *bookDurationLabelKey;
@property (nonatomic) UILabel *publishedLabelValue;
@property (nonatomic) UILabel *publisherLabelValue;
@property (nonatomic) UILabel *categoriesLabelValue;
@property (nonatomic) UILabel *distributorLabelValue;
@property (nonatomic) UILabel *bookFormatLabelValue;
@property (nonatomic) UILabel *narratorsLabelValue;
@property (nonatomic) UILabel *bookDurationLabelValue;

@property (nonatomic) TPPBookDetailTableView *footerTableView;

@property (nonatomic) UIView *topFootnoteSeparater;
@property (nonatomic) UIView *bottomFootnoteSeparator;

@property (nonatomic) BOOL isProcessingSample;
@property (nonatomic) BOOL isShowingSample;

@end

static CGFloat const SubtitleBaselineOffset = 10;
static CGFloat const AuthorBaselineOffset = 12;
static CGFloat const CoverImageAspectRatio = 0.8;
static CGFloat const CoverImageMaxWidth = 160.0;
static CGFloat const TabBarHeight = 80.0;
static CGFloat const SampleToolbarHeight = 80.0;
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
  self.translatesAutoresizingMaskIntoConstraints = NO;
  
  self.scrollView = [[UIScrollView alloc] init];
  self.scrollView.alwaysBounceVertical = YES;
  
  self.containerView = [[UIView alloc] init];
  self.containerView.layoutMargins = UIEdgeInsetsMake(self.layoutMargins.top,
                                                    self.layoutMargins.left+12,
                                                    self.layoutMargins.bottom,
                                                    self.layoutMargins.right+12);
  
  [self createHeaderLabels];
  [self createButtonsView];
  [self createBookDescriptionViews];
  [self createFooterLabels];
  [self createDownloadViews];
  [self updateFonts];
  
  [self addSubview:self.scrollView];
  [self.scrollView addSubview:self.containerView];
  
  [self.containerView addSubview:self.blurCoverImageView];
  [self.containerView addSubview:self.visualEffectView];
  [self.containerView addSubview:self.coverImageView];
  [self.containerView addSubview:self.contentTypeBadge];
  [self.containerView addSubview:self.titleLabel];
  [self.containerView addSubview:self.subtitleLabel];
  [self.containerView addSubview:self.audiobookLabel];
  [self.containerView addSubview:self.authorsLabel];
  [self.containerView addSubview:self.buttonsView];
  [self.containerView addSubview:self.summarySectionLabel];
  [self.containerView addSubview:self.summaryTextView];
  [self.containerView addSubview:self.readMoreLabel];
  
  [self.containerView addSubview:self.topFootnoteSeparater];
  [self.containerView addSubview:self.infoSectionLabel];
  [self.containerView addSubview:self.publishedLabelKey];
  [self.containerView addSubview:self.publisherLabelKey];
  [self.containerView addSubview:self.categoriesLabelKey];
  [self.containerView addSubview:self.distributorLabelKey];
  [self.containerView addSubview:self.bookFormatLabelKey];
  [self.containerView addSubview:self.narratorsLabelKey];

  if (self.book.isAudiobook) {
    [self.containerView addSubview:self.bookDurationLabelKey];
  }

  [self.containerView addSubview:self.publishedLabelValue];
  [self.containerView addSubview:self.publisherLabelValue];
  [self.containerView addSubview:self.categoriesLabelValue];
  [self.containerView addSubview:self.distributorLabelValue];
  [self.containerView addSubview:self.bookFormatLabelValue];
  [self.containerView addSubview:self.narratorsLabelValue];
  
  if (self.book.isAudiobook) {
    [self.containerView addSubview:self.bookDurationLabelValue];
  }
  
  [self.containerView addSubview:self.footerTableView];
  [self.containerView addSubview:self.bottomFootnoteSeparator];
  
  if(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
     [[TPPRootTabBarController sharedController] traitCollection].horizontalSizeClass != UIUserInterfaceSizeClassCompact) {
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:NSLocalizedString(@"Close", nil) forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[TPPConfiguration mainColor] forState:UIControlStateNormal];
    [self.closeButton setContentHorizontalAlignment:UIControlContentHorizontalAlignmentRight];
    [self.closeButton setContentEdgeInsets:UIEdgeInsetsMake(0, 2, 0, 0)];
    [self.closeButton addTarget:self action:@selector(closeButtonPressed) forControlEvents:UIControlEventTouchDown];
    [self.containerView addSubview:self.closeButton];
  }

  return self;
}

- (void)showAudiobookSampleToolbar
{
    self.audiobookSampleToolbar = [[AudiobookSampleToolbarWrapper createWithBook:self.book] view];
    [self addSubview: self.audiobookSampleToolbar];
    self.isShowingSample = true;
    self.didSetupConstraints = false;
    [self setupAutolayoutConstraints];
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
  self.buttonsView = [[TPPBookButtonsView alloc] initWithSamplesEnabled: YES];
  [self.buttonsView configureForBookDetailsContext];
  self.buttonsView.translatesAutoresizingMaskIntoConstraints = NO;
  self.buttonsView.showReturnButtonIfApplicable = YES;
  self.buttonsView.delegate = [TPPBookCellDelegate sharedDelegate];
  self.buttonsView.downloadingDelegate = self;
  self.buttonsView.sampleDelegate = self;
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

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
    NSData *htmlData = [htmlString dataUsingEncoding:NSUnicodeStringEncoding];
    NSAttributedString *attrString = nil;

    if (htmlData) {
      NSError *error = nil;
      attrString = [[NSAttributedString alloc]
                    initWithData:htmlData
                    options:@{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType}
                    documentAttributes:nil
                    error:&error];
      if (error) {
        TPPLOG_F(@"Attributed string rendering error for %@ book description: %@",
                 [self.book loggableShortString], error);
        attrString = [[NSAttributedString alloc] initWithString:@""];
      }
    } else {
      attrString = [[NSAttributedString alloc] initWithString:@""];
    }

    // Update UI on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
      self.summaryTextView.attributedText = attrString;
    });
  });

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
  UIVisualEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
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

  [[TPPBookRegistry shared]
   coverImageFor:self.book handler:^(UIImage *image) {
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
  self.titleLabel.numberOfLines = 0;
  self.titleLabel.attributedText = TPPAttributedStringForTitleFromString(self.book.title);

  self.subtitleLabel = [[UILabel alloc] init];
  self.subtitleLabel.attributedText = TPPAttributedStringForTitleFromString(self.book.subtitle);
  self.subtitleLabel.numberOfLines = 0;


  self.authorsLabel = [[UILabel alloc] init];
  self.authorsLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
  self.authorsLabel.numberOfLines = 0;
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
  
  [self.containerView addSubview:self.normalView];
  [self.containerView addSubview:self.downloadFailedView];
  [self.containerView addSubview:self.downloadingView];
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

  NSString *const bookFormatKeyString = NSLocalizedString(@"Book format:", nil);

  NSString *const narratorsKeyString =
    self.book.narrators ? [NSString stringWithFormat:@"%@: ", NSLocalizedString(@"Narrators", nil)] : nil;
  
  NSString *const bookDurationKeyString = [NSString stringWithFormat:@"%@:", NSLocalizedString(@"Duration", nil)];

  NSString *const categoriesValueString = self.book.categories;
  NSString *const publishedValueString = self.book.published ? [dateFormatter stringFromDate:self.book.published] : nil;
  NSString *const publisherValueString = self.book.publisher;
  NSString *const distributorKeyString = self.book.distributor ? [NSString stringWithFormat:NSLocalizedString(@"Distributed by: ", nil)] : nil;
  NSString *const bookFormatValueString = self.book.format;
  NSString *const narratorsValueString = self.book.narrators;
  
  if (!categoriesValueString && !publishedValueString && !publisherValueString && !self.book.distributor) {
    self.topFootnoteSeparater.hidden = YES;
    self.bottomFootnoteSeparator.hidden = YES;
  }
  
  self.categoriesLabelKey = [self createFooterLabelWithString:categoriesKeyString alignment:NSTextAlignmentRight];
  self.publisherLabelKey = [self createFooterLabelWithString:publisherKeyString alignment:NSTextAlignmentRight];
  self.publishedLabelKey = [self createFooterLabelWithString:publishedKeyString alignment:NSTextAlignmentRight];
  self.distributorLabelKey = [self createFooterLabelWithString:distributorKeyString alignment:NSTextAlignmentRight];
  self.bookFormatLabelKey = [self createFooterLabelWithString:bookFormatKeyString alignment:NSTextAlignmentRight];
  self.narratorsLabelKey = [self createFooterLabelWithString:narratorsKeyString alignment:NSTextAlignmentRight];
  self.bookDurationLabelKey = [self createFooterLabelWithString:bookDurationKeyString alignment:NSTextAlignmentRight];

  self.categoriesLabelValue = [self createFooterLabelWithString:categoriesValueString alignment:NSTextAlignmentLeft];
  self.categoriesLabelValue.numberOfLines = 2;
  self.publisherLabelValue = [self createFooterLabelWithString:publisherValueString alignment:NSTextAlignmentLeft];
  self.publisherLabelValue.numberOfLines = 2;
  self.publishedLabelValue = [self createFooterLabelWithString:publishedValueString alignment:NSTextAlignmentLeft];
  self.distributorLabelValue = [self createFooterLabelWithString:self.book.distributor alignment:NSTextAlignmentLeft];
  self.bookFormatLabelValue = [self createFooterLabelWithString:bookFormatValueString alignment:NSTextAlignmentLeft];
  self.narratorsLabelValue = [self createFooterLabelWithString:narratorsValueString alignment:NSTextAlignmentLeft];
  self.bookDurationLabelValue = [self createFooterLabelWithString:[self displayStringForDuration: self.book.bookDuration] alignment:NSTextAlignmentLeft];

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

- (NSString *) displayStringForDuration: (NSString *) durationInSeconds {
  double totalSeconds = [durationInSeconds doubleValue];
  int hours = (int)(totalSeconds / 3600);
  int minutes = (int)((totalSeconds - (hours * 3600)) / 60);
  
  return [NSString stringWithFormat:@"%d hours, %d minutes", hours, minutes];
}

- (void)setupAutolayoutConstraints {
  [self.scrollView autoPinEdgeToSuperviewEdge:ALEdgeTop];
  [self.scrollView autoPinEdgeToSuperviewEdge:ALEdgeBottom];
  
  if ([self.book showAudiobookToolbar] && self.isShowingSample) {
    [self.audiobookSampleToolbar autoPinEdgeToSuperviewEdge:ALEdgeLeft];
    [self.audiobookSampleToolbar autoPinEdgeToSuperviewEdge:ALEdgeRight];
    
    CGFloat bottomInset = 0;
    if ([UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPad) {
      bottomInset = TabBarHeight;
    }
    
    [self.audiobookSampleToolbar autoPinEdgeToSuperviewEdge:ALEdgeBottom withInset:bottomInset];
    [self.audiobookSampleToolbar autoSetDimension:ALDimensionHeight toSize:SampleToolbarHeight relation:NSLayoutRelationLessThanOrEqual];
    [self.audiobookSampleToolbar autoMatchDimension:ALDimensionWidth toDimension:ALDimensionWidth ofView:self];
    self.scrollView.contentInset = UIEdgeInsetsMake(0, 0, SampleToolbarHeight, 0);
  }
  
  [self.scrollView autoPinEdgeToSuperviewEdge:ALEdgeLeft];
  [self.scrollView autoPinEdgeToSuperviewEdge:ALEdgeRight];
  [self.scrollView autoMatchDimension:ALDimensionWidth toDimension:ALDimensionWidth ofView:self.containerView];
  
  [self.containerView autoPinEdgesToSuperviewEdges];
  [self.containerView autoMatchDimension:ALDimensionWidth toDimension:ALDimensionWidth ofView:self];
  
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
  
  // Ensure titleLabelConstraint is properly set up
  NSLayoutConstraint *titleLabelConstraint = [self.titleLabel autoPinEdgeToSuperviewMargin:ALEdgeTrailing];
  titleLabelConstraint.priority = UILayoutPriorityRequired;  // Ensure it has a valid priority
  
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
  
  [self.bookFormatLabelValue autoPinEdgeToSuperviewMargin:ALEdgeTrailing relation:NSLayoutRelationGreaterThanOrEqual];
  [self.bookFormatLabelValue autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.distributorLabelValue];
  [self.bookFormatLabelValue autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.bookFormatLabelKey withOffset:MainTextPaddingLeft];
  
  [self.narratorsLabelValue autoPinEdgeToSuperviewMargin:ALEdgeTrailing relation:NSLayoutRelationGreaterThanOrEqual];
  [self.narratorsLabelValue autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.bookFormatLabelValue];
  [self.narratorsLabelValue autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.narratorsLabelKey withOffset:MainTextPaddingLeft];
  
  if (self.book.hasDuration) {
    [self.bookDurationLabelValue autoPinEdgeToSuperviewMargin:ALEdgeTrailing relation:NSLayoutRelationGreaterThanOrEqual];
    [self.bookDurationLabelValue autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.narratorsLabelValue];
    [self.bookDurationLabelValue autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.bookDurationLabelKey withOffset:MainTextPaddingLeft];
  }
  
  [self.publishedLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
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
  [self.distributorLabelKey autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.bookFormatLabelKey];
  [self.distributorLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.distributorLabelValue];
  [self.distributorLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  
  [self.bookFormatLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.bookFormatLabelKey autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.narratorsLabelKey];
  [self.bookFormatLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.bookFormatLabelValue];
  [self.bookFormatLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  
  [self.narratorsLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
  [self.narratorsLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.narratorsLabelValue];
  [self.narratorsLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  
  if (self.book.hasDuration) {
    [self.bookDurationLabelKey autoPinEdgeToSuperviewMargin:ALEdgeLeading];
    [self.bookDurationLabelKey autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.bookDurationLabelValue];
    [self.bookDurationLabelKey autoPinEdge:ALEdgeTrailing toEdge:ALEdgeTrailing ofView:self.narratorsLabelKey];
    [self.bookDurationLabelKey setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  }
  
  if (self.closeButton) {
    [self.closeButton autoPinEdgeToSuperviewMargin:ALEdgeTrailing];
    [self.closeButton autoPinEdge:ALEdgeTop toEdge:ALEdgeTop ofView:self.titleLabel];
    [self.closeButton autoSetDimension:ALDimensionWidth toSize:80 relation:NSLayoutRelationLessThanOrEqual];
    [NSLayoutConstraint deactivateConstraints:@[titleLabelConstraint]];
    [self.closeButton autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.titleLabel withOffset:MainTextPaddingLeft];
    [self.closeButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  }
  
  [self.topFootnoteSeparater autoSetDimension:ALDimensionHeight toSize:1.0f / [UIScreen mainScreen].scale];
  [self.topFootnoteSeparater autoPinEdgeToSuperviewEdge:ALEdgeRight];
  [self.topFootnoteSeparater autoPinEdgeToSuperviewMargin:ALEdgeLeft];
  [self.topFootnoteSeparater autoPinEdge:ALEdgeBottom toEdge:ALEdgeTop ofView:self.infoSectionLabel withOffset:-VerticalPadding];
  
  [self.bottomFootnoteSeparator autoSetDimension:ALDimensionHeight toSize:1.0f / [UIScreen mainScreen].scale];
  [self.bottomFootnoteSeparator autoPinEdgeToSuperviewEdge:ALEdgeRight];
  [self.bottomFootnoteSeparator autoPinEdgeToSuperviewMargin:ALEdgeLeft];
  
  if (self.book.hasDuration) {
    [self.bottomFootnoteSeparator autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.bookDurationLabelKey withOffset:VerticalPadding];
  } else {
    [self.bottomFootnoteSeparator autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.narratorsLabelValue withOffset:VerticalPadding];
  }
  
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

- (void)didCloseDetailView {
  [self closeButtonPressed];
}

#pragma mark TPPBookSampleDelegate

NSString *PlaySampleNotification = @"ToggleSampleNotification";

- (void)didSelectPlaySample:(TPPBook *)book completion:(void (^ _Nullable)(void))completion {
  if (!self.isProcessingSample) {
    self.isProcessingSample = YES;
    if ([self.book defaultBookContentType] == TPPBookContentTypeAudiobook) {
      if ([self.book.sampleAcquisition.type isEqualToString: @"text/html"]) {
        [self presentWebView: self.book.sampleAcquisition.hrefURL];
      } else {
        if (!self.isShowingSample) {
          self.isShowingSample = YES;
          self.isProcessingSample = NO;
          [self showAudiobookSampleToolbar];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:PlaySampleNotification object:self];
      }
    } else {
      [EpubSampleFactory createSampleWithBook:self.book completion:^(EpubLocationSampleURL *sampleURL, NSError *error) {
        if (error) {
          TPPLOG_F(@"Attributed string rendering error for %@ book description: %@",
                   [self.book loggableShortString], error);
        } else if ([sampleURL isKindOfClass:[EpubSampleWebURL class]]) {
          [self presentWebView:sampleURL.url];
        } else {
          [TPPRootTabBarController.sharedController presentSample:self.book url:sampleURL.url];
        }
        self.isProcessingSample = NO;
      }];
    }
    
    completion();
  }
}
  
- (void)presentWebView:(NSURL *)url {
  BundledHTMLViewController *webController = [[BundledHTMLViewController alloc] initWithFileURL:url title:AccountsManager.shared.currentAccount.name];
  webController.hidesBottomBarWhenPushed = true;
  [TPPRootTabBarController.sharedController pushViewController:webController animated:YES];
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

- (void)stateChangedWithIsPlaying:(BOOL)isPlaying {}
@end

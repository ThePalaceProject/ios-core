
@class TPPBook;
@class TPPBookDetailView;
@class TPPBookDetailTableViewDelegate;
@class TPPCatalogLane;
@class TPPBookDetailTableView;
typedef NS_ENUM(NSInteger, TPPBookState);
@protocol TPPCatalogLaneCellDelegate;

@protocol TPPBookDetailViewDelegate

- (void)didSelectCancelDownloadFailedForBookDetailView:(TPPBookDetailView *)detailView;
- (void)didSelectCancelDownloadingForBookDetailView:(TPPBookDetailView *)detailView;
- (void)didSelectCloseButton:(TPPBookDetailView *)detailView;
- (void)didSelectMoreBooksForLane:(TPPCatalogLane *)lane;
- (void)didSelectReportProblemForBook:(TPPBook *)book sender:(id)sender;
- (void)didSelectViewIssuesForBook:(TPPBook *)book sender:(id)sender;

@end

static CGFloat const SummaryTextAbbreviatedHeight = 150.0;

@interface TPPBookDetailView : UIView

@property (nonatomic) TPPBook *book;
@property (nonatomic) double downloadProgress;
@property (nonatomic) BOOL downloadStarted;
@property (nonatomic) TPPBookState state;
@property (nonatomic) TPPBookDetailTableViewDelegate *tableViewDelegate;
@property (nonatomic, readonly) UIButton *readMoreLabel;
@property (nonatomic, readonly) UITextView *summaryTextView;
@property (nonatomic, readonly) TPPBookDetailTableView *footerTableView;


+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;
- (id)initWithCoder:(NSCoder *)aDecoder NS_UNAVAILABLE;
- (id)initWithFrame:(CGRect)frame NS_UNAVAILABLE;

// designated initializer
// |book| must not be nil.
- (instancetype)initWithBook:(TPPBook *const)book
                    delegate:(id)delegate;
- (void)updateFonts;

@end


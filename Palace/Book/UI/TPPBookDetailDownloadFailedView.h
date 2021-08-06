@class TPPProblemDocument;
@class TPPBookDetailDownloadFailedView;

@interface TPPBookDetailDownloadFailedView : UIView

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;

- (void)configureFailMessageWithProblemDocument:(TPPProblemDocument *)problemDoc;

@end

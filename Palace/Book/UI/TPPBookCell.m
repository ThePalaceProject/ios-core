
#import "TPPBookCellDelegate.h"
#import "TPPBookDownloadFailedCell.h"
#import "TPPBookDownloadingCell.h"
#import "TPPBookNormalCell.h"
#import "TPPConfiguration.h"
#import "TPPOPDS.h"

static NSString *const reuseIdentifierDownloading = @"Downloading";
static NSString *const reuseIdentifierDownloadFailed = @"DownloadFailed";
static NSString *const reuseIdentifierNormal = @"Normal";

NSInteger TPPBookCellColumnCountForCollectionViewWidth(CGFloat const collectionViewWidth)
{
  return collectionViewWidth / 320;
}

CGSize TPPBookCellSize(NSIndexPath *const indexPath, CGFloat const collectionViewWidth)
{
  static CGFloat const height = 110;
  
  NSInteger const cellsPerRow = collectionViewWidth / 320;
  CGFloat const averageCellWidth = collectionViewWidth / (CGFloat)cellsPerRow;
  CGFloat const baseCellWidth = floor(averageCellWidth);
  
  if(indexPath.row % cellsPerRow == 0) {
    // Add the extra points to the first cell in each row.
    return CGSizeMake(collectionViewWidth - ((cellsPerRow - 1) * baseCellWidth), height);
  } else {
    return CGSizeMake(baseCellWidth, height);
  }
}

void TPPBookCellRegisterClassesForCollectionView(UICollectionView *const collectionView)
{
  [collectionView registerClass:[TPPBookDownloadFailedCell class]
     forCellWithReuseIdentifier:reuseIdentifierDownloadFailed];
  [collectionView registerClass:[TPPBookDownloadingCell class]
     forCellWithReuseIdentifier:reuseIdentifierDownloading];
  [collectionView registerClass:[TPPBookNormalCell class]
     forCellWithReuseIdentifier:reuseIdentifierNormal];
}

TPPBookCell *TPPBookCellDequeue(UICollectionView *const collectionView,
                                  NSIndexPath *const indexPath,
                                  TPPBook *const book)
{
  TPPBookState const state = [[TPPBookRegistry shared]
                               stateFor:book.identifier];
  
  switch(state) {
    case TPPBookStateUnregistered:
    {
      TPPBookNormalCell *const cell = [collectionView
                                        dequeueReusableCellWithReuseIdentifier:reuseIdentifierNormal
                                        forIndexPath:indexPath];
      cell.book = book;
      cell.delegate = [TPPBookCellDelegate sharedDelegate];
      cell.state = TPPBookButtonsViewStateWithAvailability(book.defaultAcquisition.availability);

      return cell;
    }
    case TPPBookStateDownloadNeeded:
    {
      TPPBookNormalCell *const cell = [collectionView
                                        dequeueReusableCellWithReuseIdentifier:reuseIdentifierNormal
                                        forIndexPath:indexPath];
      cell.book = book;
      cell.delegate = [TPPBookCellDelegate sharedDelegate];
      cell.state = TPPBookButtonsStateDownloadNeeded;
      return cell;
    }
    case TPPBookStateDownloadSuccessful:
    {
      TPPBookNormalCell *const cell = [collectionView
                                        dequeueReusableCellWithReuseIdentifier:reuseIdentifierNormal
                                        forIndexPath:indexPath];
      cell.book = book;
      cell.delegate = [TPPBookCellDelegate sharedDelegate];
      cell.state = TPPBookButtonsStateDownloadSuccessful;
      return cell;
    }
    // SAML started is part of download process, in this step app does authenticate user but didn't begin file downloading yet
    // The cell should present progress bar and "Requesting" description on its side
    case TPPBookStateSAMLStarted:
    case TPPBookStateDownloading:
    {
      TPPBookDownloadingCell *const cell =
      [collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifierDownloading
                                                forIndexPath:indexPath];
      cell.book = book;
      cell.delegate = [TPPBookCellDelegate sharedDelegate];
      cell.downloadProgress = [[MyBooksDownloadCenter shared]
                               downloadProgressFor:book.identifier];
      cell.backgroundColor = [TPPConfiguration mainColor];
      return cell;
    }
    case TPPBookStateDownloadFailed:
    {
      TPPBookDownloadFailedCell *const cell =
        [collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifierDownloadFailed
                                                  forIndexPath:indexPath];
      cell.book = book;
      cell.delegate = [TPPBookCellDelegate sharedDelegate];
      return cell;
    }
    case TPPBookStateHolding:
    {
      TPPBookNormalCell *const cell = [collectionView
                                        dequeueReusableCellWithReuseIdentifier:reuseIdentifierNormal
                                        forIndexPath:indexPath];
      cell.book = book;
      cell.delegate = [TPPBookCellDelegate sharedDelegate];
      cell.state = TPPBookButtonsViewStateWithAvailability(book.defaultAcquisition.availability);

      return cell;
    }
    case TPPBookStateUsed:
    {
      TPPBookNormalCell *const cell = [collectionView
                                        dequeueReusableCellWithReuseIdentifier:reuseIdentifierNormal
                                        forIndexPath:indexPath];
      cell.book = book;
      cell.delegate = [TPPBookCellDelegate sharedDelegate];
      cell.state = TPPBookButtonsStateUsed;
      return cell;
    }
    case TPPBookStateUnsupported: {
      TPPBookNormalCell *const cell = [collectionView
                                        dequeueReusableCellWithReuseIdentifier:reuseIdentifierNormal
                                        forIndexPath:indexPath];
      cell.book = book;
      cell.delegate = [TPPBookCellDelegate sharedDelegate];
      cell.state = TPPBookButtonsStateUnsupported;
      return cell;
    }
  }
}

@interface TPPBookCell ()

@property (nonatomic) UIView *borderBottom;
@property (nonatomic) UIView *borderRight;

@end

@implementation TPPBookCell

#pragma mark UIView

- (instancetype)initWithFrame:(CGRect)frame
{
  self = [super initWithFrame:frame];
  if(!self) return nil;
  
  if(self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {

    // This is no longer set by default as of iOS 8.0.
    self.contentView.autoresizingMask = (UIViewAutoresizingFlexibleHeight |
                                         UIViewAutoresizingFlexibleWidth);
    
    {
      CGRect const frame = CGRectMake(CGRectGetMaxX(self.contentView.frame) - 1,
                                      0,
                                      1,
                                      CGRectGetHeight(self.contentView.frame));
      self.borderRight = [[UIView alloc] initWithFrame:frame];
      self.borderRight.backgroundColor = [UIColor lightGrayColor];
      self.borderRight.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin |
                                           UIViewAutoresizingFlexibleHeight);
      [self.contentView addSubview:self.borderRight];
    }
    {
      CGRect const frame = CGRectMake(0,
                                      CGRectGetMaxY(self.contentView.frame) - 1,
                                      CGRectGetWidth(self.contentView.frame),
                                      1);
      self.borderBottom = [[UIView alloc] initWithFrame:frame];
      self.borderBottom.backgroundColor = [UIColor lightGrayColor];
      self.borderBottom.autoresizingMask = (UIViewAutoresizingFlexibleTopMargin |
                                            UIViewAutoresizingFlexibleWidth);
      [self.contentView addSubview:self.borderBottom];
    }
  }
  
  return self;
}

#pragma mark -

- (CGRect)contentFrame
{
  CGRect frame = self.contentView.frame;
  
  if(self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {
    frame.size.width = CGRectGetWidth(frame) - 1;
    frame.size.height = CGRectGetHeight(frame) - 1;
    return frame;
  } else {
    return frame;
  }
}

@end

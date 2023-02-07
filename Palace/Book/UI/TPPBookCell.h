// This is an empty class acting as the shared superclass of all book cell classes. Its purpose is
// simply to encapsulate dequeueing cells from a UICollectionView so that the logic does not need to
// be repeated for every part of the application that displays book cells.

//#import "Palace-Swift.h"

@class TPPBook;
@class TPPBookCell;

// This is exposed to help classes implement collection view layout delegates.
NSInteger TPPBookCellColumnCountForCollectionViewWidth(CGFloat screenWidth);

// This is exposed to help classes implement collection view layout delegates.
CGSize TPPBookCellSize(NSIndexPath *indexPath, CGFloat screenWidth);

// This should be called once after creating the collection view.
void TPPBookCellRegisterClassesForCollectionView(UICollectionView *collectionView);

// Returns an appropriate subclass of TPPBookCell.
TPPBookCell *TPPBookCellDequeue(UICollectionView *collectionView,
                                  NSIndexPath *indexPath,
                                  TPPBook *book);

@interface TPPBookCell : UICollectionViewCell

// Returns the frame of the content view frame minus the border, if present. Use this for laying
// out subviews rather than |contentView.frame|.
- (CGRect)contentFrame;

@end

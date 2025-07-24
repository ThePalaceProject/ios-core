// ⚠️ DEPRECATED: This class is being replaced by SwiftUI SearchResultsView and integrated search
// in the Modern catalog architecture. New code should use the SwiftUI-based catalog system.
// This class will be removed in a future release.

@class TPPOpenSearchDescription;

#import "TPPBookCellCollectionViewController.h"

@interface TPPCatalogSearchViewController : TPPBookCellCollectionViewController

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;
- (id)initWithCoder:(NSCoder *)aDecoder NS_UNAVAILABLE;
- (id)initWithNibName:(NSString *)nibName bundle:(NSBundle *)nibBundle NS_UNAVAILABLE;

// designated initializer
- (instancetype)initWithOpenSearchDescription:(TPPOpenSearchDescription *)searchDescription;

@end

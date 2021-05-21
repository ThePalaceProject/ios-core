@protocol TPPCurrentLibraryAccountProvider;

@interface TPPSettingsSplitViewController : UISplitViewController

- (instancetype)initWithCurrentLibraryAccountProvider: (id<TPPCurrentLibraryAccountProvider>)currentAccountProvider;

@end

// This class does NOT provide configuration for the following files:
// credits.css

@import UIKit;

@interface TPPConfiguration : NSObject

+ (id)new NS_UNAVAILABLE;

// This can be overriden by setting |customMainFeedURL| in NYPLSettings.
+ (NSURL *)mainFeedURL;

+ (NSURL *)minimumVersionURL;

+ (UIColor *)accentColor;

+ (UIColor *)backgroundColor;

+ (UIColor *)readerBackgroundColor;

+ (UIColor *)readerBackgroundDarkColor;

+ (UIColor *)readerBackgroundSepiaColor;

+ (NSString *)systemFontFamilyName;

+ (NSString *)systemFontName;

+ (NSString *)semiBoldSystemFontName;

+ (NSString *)boldSystemFontName;

+ (UIColor *)backgroundMediaOverlayHighlightColor;

+ (UIColor *)backgroundMediaOverlayHighlightDarkColor;

+ (UIColor *)backgroundMediaOverlayHighlightSepiaColor;

+ (CGFloat)defaultTOCRowHeight;

+ (CGFloat)defaultBookmarkRowHeight;

/// Default navigation bar appearance with proper status bar background color
+ (UINavigationBarAppearance *)defaultAppearance;

/// Navigation bar appearance with a specified background color
/// @param backgroundColor Navigation bar background color
+ (UINavigationBarAppearance *)appearanceWithBackgroundColor:(UIColor *)backgroundColor;

@end

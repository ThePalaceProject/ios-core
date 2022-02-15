#import "TPPConfiguration.h"
#import "TPPAppDelegate.h"

#import "UILabel+NYPLAppearanceAdditions.h"
#import "UIButton+NYPLAppearanceAdditions.h"
#import "Palace-Swift.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#endif

@implementation TPPConfiguration

+ (NSURL *)mainFeedURL
{
  NSURL *const customURL = [TPPSettings sharedSettings].customMainFeedURL;

  if(customURL) return customURL;

  NSURL *const accountURL = [TPPSettings sharedSettings].accountMainFeedURL;
  return accountURL;
}

+ (NSURL *)minimumVersionURL
{
  return [NSURL URLWithString:@"http://www.librarysimplified.org/simplye-client/minimum-version"];
}

+ (UIColor *)accentColor
{
  return [UIColor colorWithRed:0.0/255.0 green:144/255.0 blue:196/255.0 alpha:1.0];
}

+ (UIColor *)backgroundColor
{
  if (@available(iOS 13, *)) {
    return [UIColor colorNamed: @"ColorBackground"];
  }
  return [UIColor colorWithWhite:250/255.0 alpha:1.0];
}

+ (UIColor *)readerBackgroundColor
{
  return [UIColor colorWithWhite:250/255.0 alpha:1.0];
}

// OK to leave as static color because it's reader-only
+ (UIColor *)readerBackgroundDarkColor
{
  return [UIColor colorWithWhite:5/255.0 alpha:1.0];
}

// OK to leave as static color because it's reader-only
+ (UIColor *)readerBackgroundSepiaColor
{
  return [UIColor colorWithRed:250/255.0 green:244/255.0 blue:232/255.0 alpha:1.0];
}

// OK to leave as static color because it's reader-only
+ (UIColor *)backgroundMediaOverlayHighlightColor
{
  return [UIColor yellowColor];
}

// OK to leave as static color because it's reader-only
+ (UIColor *)backgroundMediaOverlayHighlightDarkColor
{
  return [UIColor orangeColor];
}

// OK to leave as static color because it's reader-only
+ (UIColor *)backgroundMediaOverlayHighlightSepiaColor
{
  return [UIColor yellowColor];
}

+ (NSString *)systemFontFamilyName
{
  return @"OpenSans";
}

+ (NSString *)systemFontName
{
  return @"OpenSans-Regular";
}

+ (NSString *)semiBoldSystemFontName
{
  return @"OpenSans-SemiBold";
}

+ (NSString *)boldSystemFontName
{
  return @"OpenSans-Bold";
}

+ (CGFloat)defaultTOCRowHeight
{
  return 56;
}

+ (CGFloat)defaultBookmarkRowHeight
{
  return 100;
}

+ (UINavigationBarAppearance *)defaultAppearance
{
  return [TPPConfiguration appearanceWithBackgroundColor:[TPPConfiguration backgroundColor]];
}

+ (UINavigationBarAppearance *)appearanceWithBackgroundColor:(UIColor *)backgroundColor
{
  UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
  [appearance configureWithOpaqueBackground];
  [appearance setBackgroundColor: backgroundColor];
  [appearance setTitleTextAttributes:@{NSFontAttributeName: [UIFont semiBoldPalaceFontOfSize:18.0]}];
  return appearance;
}

@end

// FIXME: These values should be persisted as strings, not numbers derived
// from an enum.

typedef NS_ENUM(NSInteger, TPPReaderSettingsColorScheme) {
  TPPReaderSettingsColorSchemeBlackOnWhite = 0,
  TPPReaderSettingsColorSchemeBlackOnSepia = 1,
  TPPReaderSettingsColorSchemeWhiteOnBlack = 2
};

typedef NS_ENUM(NSInteger, TPPReaderSettingsFontFace) {
  TPPReaderSettingsFontFaceSans = 0,
  TPPReaderSettingsFontFaceSerif = 1,
  TPPReaderSettingsFontFaceOpenDyslexic = 2
};

typedef NS_ENUM(NSInteger, TPPReaderSettingsFontSize) {
  TPPReaderSettingsFontSizeSmallest = 0,
  TPPReaderSettingsFontSizeSmaller = 1,
  TPPReaderSettingsFontSizeSmall = 2,
  TPPReaderSettingsFontSizeNormal = 3,
  TPPReaderSettingsFontSizeLarge = 4,
  TPPReaderSettingsFontSizeXLarge = 5,
  TPPReaderSettingsFontSizeXXLarge = 6,
  TPPReaderSettingsFontSizeXXXLarge = 7,
  TPPReaderSettingsFontSizeLargest = 7
};

typedef NS_ENUM(NSInteger, TPPReaderSettingsMediaOverlaysEnableClick) {
  TPPReaderSettingsMediaOverlaysEnableClickTrue = 0,
  TPPReaderSettingsMediaOverlaysEnableClickFalse = 1
};

extern NSString * _Nonnull const TPPReaderSettingsColorSchemeDidChangeNotification;
extern NSString * _Nonnull const TPPReaderSettingsFontFaceDidChangeNotification;
extern NSString * _Nonnull const TPPReaderSettingsFontSizeDidChangeNotification;
extern NSString * _Nonnull const TPPReaderSettingsMediaClickOverlayAlwaysEnableDidChangeNotification;


// Returns |YES| if output was set properly, else |NO| due to already being at the smallest size.
BOOL TPPReaderSettingsDecreasedFontSize(TPPReaderSettingsFontSize input,
                                         TPPReaderSettingsFontSize * _Nullable output);

// Returns |YES| if output was set properly, else |NO| due to already being at the largest size.
BOOL TPPReaderSettingsIncreasedFontSize(TPPReaderSettingsFontSize input,
                                         TPPReaderSettingsFontSize * _Nullable output);

@interface TPPReaderSettings : NSObject

+ (nonnull TPPReaderSettings *)sharedSettings;

@property (nonatomic) TPPReaderSettingsColorScheme colorScheme;
@property (nonatomic) TPPReaderSettingsFontFace fontFace;
@property (nonatomic) TPPReaderSettingsFontSize fontSize;
@property (nonatomic) TPPReaderSettingsMediaOverlaysEnableClick mediaOverlaysEnableClick;
@property (nonnull, nonatomic, readonly) UIColor *backgroundColor;
@property (nonnull, nonatomic, readonly) UIColor *backgroundMediaOverlayHighlightColor;
@property (nonnull, nonatomic, readonly) UIColor *foregroundColor;
@property (nonnull, nonatomic, readonly) UIColor *selectedForegroundColor;
@property (nonnull, nonatomic, readonly) UIColor *tintColor;

- (void)save;

- (nonnull NSArray *)readiumStylesRepresentation;

- (nonnull NSDictionary *)readiumSettingsRepresentation;

@end

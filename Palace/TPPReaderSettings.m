#import "TPPConfiguration.h"
#import "TPPJSON.h"
#import "UIColor+TPPColorAdditions.h"

#import "TPPReaderSettings.h"

#import "Palace-Swift.h"

NSString *const TPPReaderSettingsColorSchemeDidChangeNotification =
@"NYPLReaderSettingsColorSchemeDidChange";

NSString *const TPPReaderSettingsFontFaceDidChangeNotification =
@"NYPLReaderSettingsFontFaceDidChange";

NSString *const TPPReaderSettingsFontSizeDidChangeNotification =
@"NYPLReaderSettingsFontSizeDidChange";

NSString *const TPPReaderSettingsMediaClickOverlayAlwaysEnableDidChangeNotification =
@"NYPLReaderSettingsMediaClickOverlayAlwaysEnableDidChangeNotification";

BOOL TPPReaderSettingsDecreasedFontSize(TPPReaderSettingsFontSize const input,
                                         TPPReaderSettingsFontSize *const output)
{
  switch(input) {
    case TPPReaderSettingsFontSizeSmallest:
      return NO;
    case TPPReaderSettingsFontSizeSmaller:
      *output = TPPReaderSettingsFontSizeSmallest;
      return YES;
    case TPPReaderSettingsFontSizeSmall:
      *output = TPPReaderSettingsFontSizeSmaller;
      return YES;
    case TPPReaderSettingsFontSizeNormal:
      *output = TPPReaderSettingsFontSizeSmall;
      return YES;
    case TPPReaderSettingsFontSizeLarge:
      *output = TPPReaderSettingsFontSizeNormal;
      return YES;
    case TPPReaderSettingsFontSizeXLarge:
      *output = TPPReaderSettingsFontSizeLarge;
      return YES;
    case TPPReaderSettingsFontSizeXXLarge:
      *output = TPPReaderSettingsFontSizeXLarge;
      return YES;
    case TPPReaderSettingsFontSizeXXXLarge:
      *output = TPPReaderSettingsFontSizeXXLarge;
      return YES;
  }
}

BOOL TPPReaderSettingsIncreasedFontSize(TPPReaderSettingsFontSize const input,
                                         TPPReaderSettingsFontSize *const output)
{
  switch(input) {
    case TPPReaderSettingsFontSizeSmallest:
      *output = TPPReaderSettingsFontSizeSmaller;
      return YES;
    case TPPReaderSettingsFontSizeSmaller:
      *output = TPPReaderSettingsFontSizeSmall;
      return YES;
    case TPPReaderSettingsFontSizeSmall:
      *output = TPPReaderSettingsFontSizeNormal;
      return YES;
    case TPPReaderSettingsFontSizeNormal:
      *output = TPPReaderSettingsFontSizeLarge;
      return YES;
    case TPPReaderSettingsFontSizeLarge:
      *output = TPPReaderSettingsFontSizeXLarge;
      return YES;
    case TPPReaderSettingsFontSizeXLarge:
      *output = TPPReaderSettingsFontSizeXXLarge;
      return YES;
    case TPPReaderSettingsFontSizeXXLarge:
      *output = TPPReaderSettingsFontSizeXXXLarge;
      return YES;
    case TPPReaderSettingsFontSizeXXXLarge:
      return NO;
  }
}

NSString *colorSchemeToString(TPPReaderSettingsColorScheme const colorScheme)
{
  switch(colorScheme) {
    case TPPReaderSettingsColorSchemeBlackOnSepia:
      return @"blackOnSepia";
    case TPPReaderSettingsColorSchemeBlackOnWhite:
      return @"blackOnWhite";
    case TPPReaderSettingsColorSchemeWhiteOnBlack:
      return @"whiteOnBlack";
  }
}

TPPReaderSettingsColorScheme colorSchemeFromString(NSString *const string)
{
  NSNumber *const colorSchemeNumber =
  @{@"blackOnSepia": @(TPPReaderSettingsColorSchemeBlackOnSepia),
    @"blackOnWhite": @(TPPReaderSettingsColorSchemeBlackOnWhite),
    @"whiteOnBlack": @(TPPReaderSettingsColorSchemeWhiteOnBlack)}[string];
  
  if(!colorSchemeNumber) {
    @throw NSInternalInconsistencyException;
  }
  
  return [colorSchemeNumber integerValue];
}

NSString *fontFaceToString(TPPReaderSettingsFontFace const fontFace)
{
  switch(fontFace) {
    case TPPReaderSettingsFontFaceSans:
      return @"sans";
    case TPPReaderSettingsFontFaceSerif:
      return @"serif";
    case TPPReaderSettingsFontFaceOpenDyslexic:
      return @"OpenDyslexic";
  }
}

TPPReaderSettingsFontFace fontFaceFromString(NSString *const stringKey)
{
  NSDictionary *possibleValues = @{
    @"sans": @(TPPReaderSettingsFontFaceSans),
    @"serif": @(TPPReaderSettingsFontFaceSerif),
    @"OpenDyslexic": @(TPPReaderSettingsFontFaceOpenDyslexic),
    @"OpenDyslexic3": @(TPPReaderSettingsFontFaceOpenDyslexic)
  };
  NSNumber *fontFaceNumber = possibleValues[stringKey];
  
  if(fontFaceNumber == nil) {
#if DEBUG
    @throw NSInternalInconsistencyException;
#else
    fontFaceNumber = @(TPPReaderSettingsFontFaceSans);
#endif
  }
  
  return [fontFaceNumber integerValue];
}

NSString *fontSizeToString(TPPReaderSettingsFontSize const fontSize)
{
  switch(fontSize) {
    case TPPReaderSettingsFontSizeSmallest:
      return @"smallest";
    case TPPReaderSettingsFontSizeSmaller:
      return @"smaller";
    case TPPReaderSettingsFontSizeSmall:
      return @"small";
    case TPPReaderSettingsFontSizeNormal:
      return @"normal";
    case TPPReaderSettingsFontSizeLarge:
      return @"large";
    case TPPReaderSettingsFontSizeXLarge:
      return @"xlarge";
    case TPPReaderSettingsFontSizeXXLarge:
      return @"xxlarge";
    case TPPReaderSettingsFontSizeXXXLarge:
      return @"xxxlarge";
  }
}

BOOL mediaOverlaysEnableClickToBOOL(NSString * mediaClickOverlayAlwaysEnable)
{
  if ([mediaClickOverlayAlwaysEnable isEqualToString:@"true"]) {
    return YES;
  }
  else {
    return NO;
  }
}

NSString * mediaOverlaysEnableClickToString(BOOL mediaClickOverlayAlwaysEnable)
{
  if (mediaClickOverlayAlwaysEnable) {
    return @"true";
  }
  else {
    return @"false";
  }
}

TPPReaderSettingsFontSize fontSizeFromString(NSString *const string)
{
  // Had to re-add older keys 'larger' and 'largest' to save from a
  // crash for versions before 2.0.0 (1087)
  NSNumber *const fontSizeNumber = @{@"smallest": @(TPPReaderSettingsFontSizeSmallest),
                                     @"smaller": @(TPPReaderSettingsFontSizeSmaller),
                                     @"small": @(TPPReaderSettingsFontSizeSmall),
                                     @"normal": @(TPPReaderSettingsFontSizeNormal),
                                     @"large": @(TPPReaderSettingsFontSizeLarge),
                                     @"larger": @(TPPReaderSettingsFontSizeXLarge),
                                     @"largest": @(TPPReaderSettingsFontSizeXXLarge),
                                     @"xlarge": @(TPPReaderSettingsFontSizeXLarge),
                                     @"xxlarge": @(TPPReaderSettingsFontSizeXXLarge),
                                     @"xxxlarge": @(TPPReaderSettingsFontSizeXXXLarge)}[string];
  
  if(!fontSizeNumber) {
    @throw NSInternalInconsistencyException;
  }
  
  return [fontSizeNumber integerValue];
}

static NSString *const ColorSchemeKey = @"colorScheme";
static NSString *const FontFaceKey = @"fontFace";
static NSString *const FontSizeKey = @"fontSize";
static NSString *const MediaOverlaysEnableClick = @"mediaOverlaysEnableClick";

@implementation TPPReaderSettings

+ (TPPReaderSettings *)sharedSettings
{
  static dispatch_once_t predicate;
  static TPPReaderSettings *sharedReaderSettings = nil;
  
  dispatch_once(&predicate, ^{
    sharedReaderSettings = [[self alloc] init];
    if(!sharedReaderSettings) {
      TPPLOG(@"Failed to create shared reader settings.");
    }
    
    [sharedReaderSettings load];
  });
  
  return sharedReaderSettings;
}

- (NSURL *)settingsURL
{
  NSURL *URL = [[TPPBookContentMetadataFilesHelper currentAccountDirectory]
                URLByAppendingPathComponent:@"settings.json"];
  
  return URL;
}

- (void)load
{
  @synchronized(self) {
    NSData *const savedData = [NSData dataWithContentsOfURL:[self settingsURL]];
    if(!savedData) {
      self.colorScheme = TPPReaderSettingsColorSchemeBlackOnWhite;
      self.fontFace = TPPReaderSettingsFontFaceSerif;
      self.fontSize = TPPReaderSettingsFontSizeNormal;
      
      if(UIAccessibilityIsVoiceOverRunning())
      {
         self.mediaOverlaysEnableClick = YES;
      }
      else {
         self.mediaOverlaysEnableClick = NO;
      }
      return;
    }
    
    NSDictionary *const dictionary = TPPJSONObjectFromData(savedData);
    
    if(!dictionary) {
      TPPLOG(@"Failed to interpret saved registry data as JSON.");
      return;
    }
    
    self.colorScheme = colorSchemeFromString(dictionary[ColorSchemeKey]);
    self.fontFace = fontFaceFromString(dictionary[FontFaceKey]);
    self.fontSize = fontSizeFromString(dictionary[FontSizeKey]);
    self.mediaOverlaysEnableClick = mediaOverlaysEnableClickToBOOL(dictionary[MediaOverlaysEnableClick]);
  }
}

- (NSDictionary *)dictionaryRepresentation
{
  NSDictionary *settings = @{ColorSchemeKey: colorSchemeToString(self.colorScheme),
                             FontFaceKey: fontFaceToString(self.fontFace),
                             FontSizeKey: fontSizeToString(self.fontSize),
                             MediaOverlaysEnableClick: mediaOverlaysEnableClickToString(self.mediaOverlaysEnableClick)};
  
  return settings;
}

- (void)save
{
  @synchronized(self) {
    NSOutputStream *const stream =
      [NSOutputStream outputStreamWithURL:[[self settingsURL] URLByAppendingPathExtension:@"temp"]
                                   append:NO];
    
    [stream open];
    
    // This try block is necessary to catch an (entirely undocumented) exception thrown by
    // NSJSONSerialization in the event that the provided stream isn't open for writing.
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wassign-enum"
      if(![NSJSONSerialization
           writeJSONObject:[self dictionaryRepresentation]
           toStream:stream
           options:0
           error:NULL]) {
#pragma clang diagnostic pop
        TPPLOG(@"Failed to write settings data.");
        return;
      }
    } @catch(NSException *const exception) {
      TPPLOG_F(@"Exception: %@: %@", [exception name], [exception reason]);
      return;
    } @finally {
      [stream close];
    }
    
    NSError *error = nil;
    if(![[NSFileManager defaultManager]
         replaceItemAtURL:[self settingsURL]
         withItemAtURL:[[self settingsURL] URLByAppendingPathExtension:@"temp"]
         backupItemName:nil
         options:NSFileManagerItemReplacementUsingNewMetadataOnly
         resultingItemURL:NULL
         error:&error]) {
      TPPLOG(@"Failed to rename temporary settings file.");
      return;
    }
  }
}

- (void)setColorScheme:(TPPReaderSettingsColorScheme const)colorScheme
{
  _colorScheme = colorScheme;

  __weak TPPReaderSettings const *weakSelf = self;
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [[NSNotificationCenter defaultCenter]
     postNotificationName:TPPReaderSettingsColorSchemeDidChangeNotification
     object:weakSelf];
  }];
}

- (void)setFontFace:(TPPReaderSettingsFontFace const)fontFace
{
  _fontFace = fontFace;
  
  __weak TPPReaderSettings const *weakSelf = self;
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [[NSNotificationCenter defaultCenter]
     postNotificationName:TPPReaderSettingsFontFaceDidChangeNotification
     object:weakSelf];
  }];
}

- (void)setFontSize:(TPPReaderSettingsFontSize const)fontSize
{
  _fontSize = fontSize;
  
  __weak TPPReaderSettings const *weakSelf = self;
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [[NSNotificationCenter defaultCenter]
     postNotificationName:TPPReaderSettingsFontSizeDidChangeNotification
     object:weakSelf];
  }];
}

-(void)setMediaOverlaysEnableClick:(TPPReaderSettingsMediaOverlaysEnableClick)mediaOverlaysEnableClick {
    _mediaOverlaysEnableClick = mediaOverlaysEnableClick;
    __weak TPPReaderSettings const *weakSelf = self;
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
      [[NSNotificationCenter defaultCenter]
       postNotificationName:TPPReaderSettingsMediaClickOverlayAlwaysEnableDidChangeNotification
       object:weakSelf];
    }];
}

- (UIColor *)backgroundColor
{
  switch(self.colorScheme) {
    case TPPReaderSettingsColorSchemeBlackOnSepia:
      return [TPPConfiguration readerBackgroundSepiaColor];
    case TPPReaderSettingsColorSchemeBlackOnWhite:
      return [TPPConfiguration readerBackgroundColor];
    case TPPReaderSettingsColorSchemeWhiteOnBlack:
    default:
      return [TPPConfiguration readerBackgroundDarkColor];
  }
}

- (UIColor *)backgroundMediaOverlayHighlightColor
{
  switch(self.colorScheme) {
    case TPPReaderSettingsColorSchemeBlackOnSepia:
      return [TPPConfiguration backgroundMediaOverlayHighlightSepiaColor];
    case TPPReaderSettingsColorSchemeBlackOnWhite:
      return [TPPConfiguration backgroundMediaOverlayHighlightColor];
    case TPPReaderSettingsColorSchemeWhiteOnBlack:
    default:
      return [TPPConfiguration backgroundMediaOverlayHighlightDarkColor];
  }
}

- (UIColor *)foregroundColor
{
  switch(self.colorScheme) {
    case TPPReaderSettingsColorSchemeBlackOnSepia:
    case TPPReaderSettingsColorSchemeBlackOnWhite:
      return [UIColor blackColor];
    case TPPReaderSettingsColorSchemeWhiteOnBlack:
    default:
      return [UIColor whiteColor];
  }
}

- (UIColor *)selectedForegroundColor
{
  switch(self.colorScheme) {
    case TPPReaderSettingsColorSchemeBlackOnSepia:
    case TPPReaderSettingsColorSchemeBlackOnWhite:
      return [UIColor whiteColor];
    case TPPReaderSettingsColorSchemeWhiteOnBlack:
    default:
      return [UIColor blackColor];
  }
}

- (UIColor *)tintColor
{
  switch(self.colorScheme) {
    case TPPReaderSettingsColorSchemeBlackOnSepia:
    case TPPReaderSettingsColorSchemeBlackOnWhite:
      return [UIColor darkGrayColor];
    case TPPReaderSettingsColorSchemeWhiteOnBlack:
    default:
      return [UIColor whiteColor];
  }
}

- (NSArray *)readiumStylesRepresentation
{
  NSString *fontFace;
  
  switch(self.fontFace) {
    case TPPReaderSettingsFontFaceSans:
      fontFace = @"Helvetica";
      break;
    case TPPReaderSettingsFontFaceSerif:
      fontFace = @"Georgia";
      break;
    case TPPReaderSettingsFontFaceOpenDyslexic:
      fontFace = @"OpenDyslexic3";
      break;
  }
  
  return @[@{@"selector": @"*",
             @"declarations": @{@"color": [self.foregroundColor javascriptHexString],
                                @"font-family": fontFace,
                                @"-webkit-hyphens": @"auto"}}];
}

- (NSDictionary *)readiumSettingsRepresentation
{
  CGFloat const scalingFactor = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? 1.1 : 1.5;
  
  CGFloat baseSize;
  switch(self.fontSize) {
    case TPPReaderSettingsFontSizeSmallest:
      baseSize = 70;
      break;
    case TPPReaderSettingsFontSizeSmaller:
      baseSize = 80;
      break;
    case TPPReaderSettingsFontSizeSmall:
      baseSize = 90;
      break;
    case TPPReaderSettingsFontSizeNormal:
      baseSize = 100;
      break;
    case TPPReaderSettingsFontSizeLarge:
      baseSize = 120;
      break;
    case TPPReaderSettingsFontSizeXLarge:
      baseSize = 150;
      break;
    case TPPReaderSettingsFontSizeXXLarge:
      baseSize = 200;
      break;
    case TPPReaderSettingsFontSizeXXXLarge:
      baseSize = 250;
      break;
  }

  return @{@"columnGap": @20,
           @"fontSize": @(baseSize * scalingFactor),
           @"syntheticSpread": @"auto",
           @"columnMaxWidth": @9999999,
           @"scroll": @NO,
           @"mediaOverlaysEnableClick": self.mediaOverlaysEnableClick ? @YES: @NO};
}

@end

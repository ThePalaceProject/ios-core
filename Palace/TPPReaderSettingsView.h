#import "TPPReaderSettings.h"

@class TPPReaderSettingsView;

//==============================================================================

typedef NS_ENUM(NSUInteger, NYPLReaderFontSizeChange) {
  NYPLReaderFontSizeChangeIncrease,
  NYPLReaderFontSizeChangeDecrease,
};

@protocol NYPLReaderSettingsViewDelegate

- (void)readerSettingsView:(nonnull TPPReaderSettingsView *)readerSettingsView
       didSelectBrightness:(CGFloat)brightness;

- (void)readerSettingsView:(nonnull TPPReaderSettingsView *)readerSettingsView
      didSelectColorScheme:(TPPReaderSettingsColorScheme)colorScheme;

- (TPPReaderSettingsFontSize)readerSettingsView:(nonnull TPPReaderSettingsView *)view
                               didChangeFontSize:(NYPLReaderFontSizeChange)change;

- (void)readerSettingsView:(nonnull TPPReaderSettingsView *)readerSettingsView
         didSelectFontFace:(TPPReaderSettingsFontFace)fontFace;

@end

//==============================================================================
/**
 This class observes brightness change notifications from UIScreen and reflects
 them visually. It does not, however, change the screen's brightness itself.
 Objects that use this view should implement its delegate and forward
 brightness changes to a UIScreen instance as appropriate.
 */
@interface TPPReaderSettingsView : UIView

@property (nonatomic) TPPReaderSettingsColorScheme colorScheme;
@property (nonatomic, weak, nullable) id<NYPLReaderSettingsViewDelegate> delegate;
@property (nonatomic) TPPReaderSettingsFontSize fontSize;
@property (nonatomic) TPPReaderSettingsFontFace fontFace;

+ (nonnull instancetype)new NS_UNAVAILABLE;
- (nonnull instancetype)init NS_UNAVAILABLE;
- (nonnull instancetype)initWithCoder:(nonnull NSCoder *)aDecoder NS_UNAVAILABLE;
- (nonnull instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (nonnull instancetype)initWithWidth:(CGFloat)width;

@end

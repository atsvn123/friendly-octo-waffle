// BINFlashColorBar.h
// Reconstructed from _OBJC_CLASS_$_BINFlashColorBar (0x4F88+)
//
// UIControl subclass that displays a horizontal hue gradient bar.
// User drags to select a hue value in [0.0, 1.0].
// Sends UIControlEventValueChanged when hue changes.

#import <UIKit/UIKit.h>

@interface BINFlashColorBar : UIControl

// Current hue in [0.0, 1.0] (default: 0.33)
@property (nonatomic, assign) double hue;  // -[BINFlashColorBar setHue:] (0x4F88)

@end

// BINFlashOvalView.h
// Reconstructed from _OBJC_CLASS_$_BINFlashOvalView (0x49C4+)
//
// Full-screen UIView subclass that renders a hue/color oval (color wheel).
// Displayed as a background layer behind the panel.
// User can interact with it to select a color region for the flash effect.

#import <UIKit/UIKit.h>

@interface BINFlashOvalView : UIView

// Set the displayed hue, updates the oval gradient rendering
- (void)setHue:(double)hue;

@end

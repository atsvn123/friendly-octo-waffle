// VCamFloatButton.h
// Donut-shaped (ring) float button.
// The center hole is fully transparent — background shows through for color preview.
// Only the ring zone registers touches; center hole passes touches to the app.
//
// Ring color reflects the detected background hue (auto color mode).
// Tap ring → opens menu. Drag → moves button.

#import <UIKit/UIKit.h>

@interface VCamFloatButton : UIButton

@property (nonatomic, assign) BOOL    isMoving;
@property (nonatomic, assign) CGPoint beginPosition;

// Update ring fill color to match sampled hue [0,1). -1.0 → white (no color).
- (void)setRingHue:(double)hue;

- (void)buttonClicked;

@end

// Global button — accessible from VCamColorPickerWindow.m.
extern VCamFloatButton *g_floatButton;

// Called on the main queue every ~200ms by the connect thread.
void vcamUpdateFloatButton(void);

// VCamFloatButton.h
// Reconstructed from iHsfaTkdhwkzopQfsnwBd (0x12AD60)
//
// UIButton subclass. Lives inside VCamColorPickerWindow (pass-through UIWindow
// at UIWindowLevelStatusBar + 10000). Never re-parented; window is always shown.
//
// Touch handling: custom touchesBegan/Moved/Ended for drag + edge-snap.
// Tap action: buttonClicked opens/closes menu if !isMoving.
// Ring: CAShapeLayer halo showing the current sampled hue (auto color mode).

#import <UIKit/UIKit.h>

@interface VCamFloatButton : UIButton

@property (nonatomic, assign) BOOL    isMoving;
@property (nonatomic, assign) CGPoint beginPosition;
@property (nonatomic, assign) float   offsetX;
@property (nonatomic, assign) float   offsetY;

// Show hue ring with given hue [0,1). Pass -1.0 to hide the ring.
// Called from VCamColorPickerWindow's notify handler when a sample arrives.
- (void)setRingHue:(double)hue;

- (void)buttonClicked;
- (void)buttonDoubleClicked;
- (void)buttonDrag;

@end

// Global button — also accessible from VCamColorPickerWindow.m for ring updates.
extern VCamFloatButton *g_floatButton;

// Must be called on the main queue every ~200ms by the connect thread.
void vcamUpdateFloatButton(void);

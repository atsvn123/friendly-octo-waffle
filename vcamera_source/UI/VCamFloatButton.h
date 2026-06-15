// VCamFloatButton.h
// Circular "Y" button. Drag via touchesBegan/Moved/Ended (no gesture recognizers).
// Hue ring: thin CAShapeLayer stroke circle outside the button body.

#import <UIKit/UIKit.h>

@interface VCamFloatButton : UIButton

// YES while finger is actively dragging (>1pt). Resets to NO on touchesEnded.
@property (nonatomic, assign) BOOL isMoving;

// Update ring fill color to match sampled hue [0,1). -1.0 → white (no color).
- (void)setRingHue:(double)hue;

- (void)buttonClicked;

@end

// Global button — accessible from VCamColorPickerWindow.m.
extern VCamFloatButton *g_floatButton;

// Called on the main queue every ~200ms by the connect thread.
void vcamUpdateFloatButton(void);

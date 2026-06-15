// VCamFloatButton.h
// Donut ring float button. Drag/tap via touchesBegan/Moved/Ended (no gesture recognizers).
// Ring color reflects detected background hue. Tap → opens menu. Drag → moves button.

#import <UIKit/UIKit.h>

@interface VCamFloatButton : UIButton

// YES while finger is dragging (>1pt offset). Guards buttonClicked against drag triggers.
@property (nonatomic, assign) BOOL isMoving;

// Update ring fill color to match sampled hue [0,1). -1.0 → white (no color).
- (void)setRingHue:(double)hue;

- (void)buttonClicked;

@end

// Global button — accessible from VCamColorPickerWindow.m.
extern VCamFloatButton *g_floatButton;

// Called on the main queue every ~200ms by the connect thread.
void vcamUpdateFloatButton(void);

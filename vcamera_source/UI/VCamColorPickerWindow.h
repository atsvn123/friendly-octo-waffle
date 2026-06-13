// VCamColorPickerWindow.h
// Pass-through UIWindow that hosts the float button.
// Also owns the Darwin notify infrastructure for cross-process color sampling.

#import <UIKit/UIKit.h>

@interface VCamColorPickerWindow : UIWindow
+ (instancetype)sharedWindow;
@end

// Call once in SpringBoard's constructor. Registers com.vcam.sampleresponse handler
// which updates the float button ring and saves the hue to prefs.
void vcamInstallPickerNotifyHandler(void);

// Send a sample request for the given normalized position [0,1].
// Tries IOSurface direct read first; falls back to Darwin notify → UIKit sampler.
// Updates ring and prefs directly if IOSurface succeeds.
void vcamSendPickerSampleRequest(float nx, float ny);

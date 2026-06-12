// VCamColorPickerWindow.h
// Floating draggable color-picker circle. Samples screen color under its
// center every ~0.3s; skips near-black / near-white / near-gray samples.
// Lives in a dedicated UIWindow at a high windowLevel.

#import <UIKit/UIKit.h>

@interface VCamColorPickerWindow : UIWindow
+ (instancetype)sharedWindow;
- (void)showPicker;    // visible + draggable + sampling timer on
- (void)hidePicker;    // hidden + timer off (call when auto color toggled OFF)
- (void)setDraggable:(BOOL)draggable;  // toggle drag without affecting visibility or timer
@end

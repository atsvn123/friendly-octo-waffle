// VCamManualPadWindow.h
// Small draggable floating pad with ↑↓←→ for adjusting manual flash position.
// Shows when "Thủ công" is selected in the position segmented control.

#import <UIKit/UIKit.h>

@interface VCamManualPadWindow : UIWindow
+ (instancetype)sharedWindow;
- (void)showPad;
- (void)hidePad;
@end

// VCamFloatButton.h
// Reconstructed from iHsfaTkdhwkzopQfsnwBd (0x12AD60)
//
// UIButton subclass. Added as subview of keyWindow (NOT a UIWindow itself).
// Created once on first call to vcamUpdateFloatButton(); then re-added to keyWindow
// every 200ms to keep it on top of whatever SpringBoard renders.
//
// Touch handling: custom touchesBegan/Moved/Ended for drag + edge-snap.
// Tap action: buttonClicked (UIControlEventTouchUpInside) opens menu if !isMoving.

#import <UIKit/UIKit.h>

@interface VCamFloatButton : UIButton

// IDA-confirmed instance state
@property (nonatomic, assign) BOOL    isMoving;
@property (nonatomic, assign) CGPoint beginPosition;  // touch start in self-local coords
@property (nonatomic, assign) float   offsetX;
@property (nonatomic, assign) float   offsetY;

// UIControl action targets (registered in initWithFrame:)
- (void)buttonClicked;        // TouchUpInside (64): open menu if !isMoving
- (void)buttonDoubleClicked;  // TouchDownRepeat (2): NOP
- (void)buttonDrag;           // TouchDragInside (4): NOP (drag handled by touchesMoved)

@end

// Mirrors sub_84D20 (0x84D20).
// Creates the button the first time, updates its state and re-adds to keyWindow.
// Called from main queue every 200ms by the connect thread while on homescreen.
void vcamUpdateFloatButton(void);

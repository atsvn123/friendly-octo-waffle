// BINFlashController.h
// Reconstructed from BINFlashController ObjC class (0x947C–0xB07C)
//
// The top-level coordinator for the BINFlash UI overlay.
// Owns the pass-through UIWindow, the settings panel, the color oval, the mini button,
// and the 20Hz display timer.
//
// Singleton. Created and started from the __mod_init_func constructor.

#import <UIKit/UIKit.h>
@class BINFlashPanel;
@class BINFlashOvalView;

@interface BINFlashController : NSObject

// Singleton (dispatch_once)
+ (instancetype)shared;  // 0xAD60

// Wait for UIApplicationDidFinishLaunchingNotification, then call -start.
// Called from the InitFunc_0 constructor block.
- (void)startWhenReady;  // 0xAB60

// Build the full overlay UI. Idempotent (guarded by self.window check).
- (void)start;  // 0x947C

// Show the settings panel, reload from prefs.
- (void)showPanel;  // 0xA808

// 20Hz timer callback: animate, apply flash effect via BINFlashEffectBridge.
- (void)tick;  // 0xAA30

// Properties set during -start
@property (nonatomic, strong) UIWindow       *window;       // BINFlashPassThroughWindow
@property (nonatomic, strong) BINFlashPanel  *panel;
@property (nonatomic, strong) BINFlashOvalView *ovalView;
@property (nonatomic, strong) UIButton       *miniButton;   // "BIN" green button
@property (nonatomic, strong) NSTimer        *timer;
@property (nonatomic, assign) BOOL            panelLocked;  // drag lock flag

@end

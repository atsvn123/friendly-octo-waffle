// VCamMenuViewController.h
// Vietnamese white bottom-sheet menu with LIVE, FLASH, auto-color, manual position

#import <UIKit/UIKit.h>

@interface VCamMenuViewController : UIViewController

// Called from VCamBridge when a diagnostic string arrives from mediaserverd
- (void)showDiag:(NSString *)msg;

// Called by VCamBridge.dismiss — animates card down, then invokes completion
- (void)animateDismissWithCompletion:(void(^)(void))completion;

@end

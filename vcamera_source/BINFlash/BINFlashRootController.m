// BINFlashRootController.m
#import "BINFlashRootController.h"

@implementation BINFlashRootController
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

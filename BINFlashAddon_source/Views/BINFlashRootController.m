// BINFlashRootController.m
// Minimal UIViewController for the pass-through overlay window.
// No custom behavior — just suppresses status bar.

#import "BINFlashRootController.h"

@implementation BINFlashRootController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

@end

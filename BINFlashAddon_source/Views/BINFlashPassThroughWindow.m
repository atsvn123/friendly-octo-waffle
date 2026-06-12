// BINFlashPassThroughWindow.m
// Reconstructed from _OBJC_CLASS_$_BINFlashPassThroughWindow
//
// hitTest:withEvent: returns nil for any point that doesn't land on an
// interactable subview, so those touches fall through to the camera app below.

#import "BINFlashPassThroughWindow.h"

@implementation BINFlashPassThroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Return nil (pass-through) if the hit view is ourselves or the root VC view
    // — i.e. only intercept touches that land on actual subviews (panel, button, oval)
    if (hit == self || hit == self.rootViewController.view)
        return nil;
    return hit;
}

@end

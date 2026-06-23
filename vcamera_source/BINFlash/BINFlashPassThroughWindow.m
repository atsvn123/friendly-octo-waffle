// BINFlashPassThroughWindow.m
#import "BINFlashPassThroughWindow.h"

@implementation BINFlashPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

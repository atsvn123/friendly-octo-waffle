// BINFlashOvalView.m
#import "BINFlashOvalView.h"
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIColor.h>

@interface BINFlashOvalView () { double _hue; }
@end

@implementation BINFlashOvalView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.backgroundColor = [UIColor clearColor]; self.userInteractionEnabled = YES; _hue = 0.33; }
    return self;
}
- (void)setHue:(double)hue { _hue = hue; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat radius = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 0.40;
    int segments = 360;
    CGFloat angleStep = (CGFloat)(2.0 * M_PI / segments);
    for (int i = 0; i < segments; i++) {
        CGFloat h = (CGFloat)i / segments;
        UIColor *color = [UIColor colorWithHue:h saturation:1.0 brightness:0.85 alpha:0.75];
        CGContextSetFillColorWithColor(ctx, [color CGColor]);
        CGFloat angle = i * angleStep - (CGFloat)(M_PI / 2.0);
        CGContextMoveToPoint(ctx, center.x, center.y);
        CGContextAddArc(ctx, center.x, center.y, radius, angle, angle + angleStep + 0.01, 0);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    }
    CGFloat selAngle = (CGFloat)(_hue * 2.0 * M_PI) - (CGFloat)(M_PI / 2.0);
    CGFloat markerX = center.x + cosf(selAngle) * (radius * 0.80);
    CGFloat markerY = center.y + sinf(selAngle) * (radius * 0.80);
    [[UIColor whiteColor] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(markerX - 8, markerY - 8, 16, 16));
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event { [self handleTouch:[touches anyObject]]; }
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event { [self handleTouch:[touches anyObject]]; }
- (void)handleTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat angle = atan2f(p.y - center.y, p.x - center.x) + (CGFloat)(M_PI / 2.0);
    if (angle < 0) angle += (CGFloat)(2.0 * M_PI);
    _hue = angle / (CGFloat)(2.0 * M_PI);
    [self setNeedsDisplay];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BINFlashHueChangedNotification" object:@(_hue)];
}
@end

// BINFlashColorBar.m
// Horizontal hue gradient bar — tap/drag to select hue value.
// Used in the BINFlashPanel settings panel.

#import "BINFlashColorBar.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

@implementation BINFlashColorBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 6.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    // Draw horizontal hue gradient from 0 to 1
    int steps = (int)CGRectGetWidth(rect);
    if (steps < 1) steps = 1;
    CGFloat stepW = CGRectGetWidth(rect) / steps;

    for (int i = 0; i < steps; i++) {
        CGFloat hue = (CGFloat)i / steps;
        UIColor *c = [UIColor colorWithHue:hue saturation:1.0 brightness:0.85 alpha:1.0];
        CGContextSetFillColorWithColor(ctx, [c CGColor]);
        CGContextFillRect(ctx, CGRectMake(i * stepW, 0, stepW + 1, CGRectGetHeight(rect)));
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self handleTouch:[touches anyObject]];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [self handleTouch:[touches anyObject]];
}

- (void)handleTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    CGFloat hue = p.x / CGRectGetWidth(self.bounds);
    if (hue < 0) hue = 0;
    if (hue > 1) hue = 1;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self setHue:hue];
}

- (void)setHue:(CGFloat)hue {
    objc_setAssociatedObject(self, "hue", @(hue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self setNeedsDisplay];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"BINFlashHueChangedNotification"
                      object:@((double)hue)];
}

- (CGFloat)hue {
    NSNumber *h = objc_getAssociatedObject(self, "hue");
    return h ? [h floatValue] : 0.33f;
}

@end

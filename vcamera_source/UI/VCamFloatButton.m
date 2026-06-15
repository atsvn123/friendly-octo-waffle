// VCamFloatButton.m
// Circular "Y" button — raw touch overrides for drag (no gesture recognizers).
// Hue ring: thin CAShapeLayer stroke circle outside the button, color = detected hue.

#import "VCamFloatButton.h"
#import "VCamColorPickerWindow.h"
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <QuartzCore/QuartzCore.h>

VCamFloatButton *g_floatButton = nil;

@implementation VCamFloatButton {
    CAShapeLayer *_hueRingLayer;
    CGPoint       _dragStartCenter;   // button center when touch began
    CGPoint       _touchStartInView;  // finger position (superview coords) when touch began
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;

    // ── Circle body ─────────────────────────────────────────────────────────
    self.layer.cornerRadius = frame.size.width * 0.5f;
    self.backgroundColor = [UIColor colorWithRed:0.9686f green:0.7176f
                                           blue:0.8000f alpha:0.9f];
    self.clipsToBounds  = NO;
    self.opaque         = NO;

    // Drop shadow on body
    self.layer.shadowColor   = [[UIColor blackColor] CGColor];
    self.layer.shadowOpacity = 0.30f;
    self.layer.shadowOffset  = CGSizeMake(0.0f, 2.0f);
    self.layer.shadowRadius  = 4.0f;

    // ── "Y" label (XOR: 0x03 ^ 0x5A = 'Y') ─────────────────────────────────
    uint8_t ch = 0x03 ^ 0x5A;
    [self setTitle:[NSString stringWithFormat:@"%c", ch]
          forState:UIControlStateNormal];
    [self setTitleColor:[UIColor colorWithRed:0.2941f green:0.2000f
                                        blue:0.2510f alpha:1.0f]
               forState:UIControlStateNormal];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:18.0f];

    // ── Hue ring (thin stroke circle outside the button) ────────────────────
    CGFloat cx = frame.size.width  * 0.5f;
    CGFloat cy = frame.size.height * 0.5f;
    CGFloat r  = frame.size.width  * 0.5f + 5.0f;   // 5pt gap outside button edge

    _hueRingLayer = [CAShapeLayer layer];
    _hueRingLayer.path = [UIBezierPath
        bezierPathWithArcCenter:CGPointMake(cx, cy)
                         radius:r
                     startAngle:0.0f
                       endAngle:(CGFloat)(M_PI * 2.0)
                      clockwise:YES].CGPath;
    _hueRingLayer.fillColor   = [[UIColor clearColor] CGColor];
    _hueRingLayer.strokeColor = [[UIColor colorWithWhite:1.0f alpha:0.85f] CGColor];
    _hueRingLayer.lineWidth   = 3.0f;
    _hueRingLayer.frame       = self.bounds;
    [self.layer addSublayer:_hueRingLayer];

    // UIControl target so UIButton fires buttonClicked on TouchUpInside.
    // buttonClicked guards with !isMoving so drag doesn't open the menu.
    [self addTarget:self action:@selector(buttonClicked)
   forControlEvents:UIControlEventTouchUpInside];

    return self;
}

// Full-frame hit zone — entire 50×50 pt square registers touches.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(self.bounds, point);
}

// ── Hue ring color ────────────────────────────────────────────────────────────
- (void)setRingHue:(double)hue {
    UIColor *color;
    if (hue >= 0.0 && hue <= 1.0) {
        color = [UIColor colorWithHue:(CGFloat)hue saturation:0.80f
                           brightness:1.0f alpha:0.95f];
    } else {
        color = [UIColor colorWithWhite:1.0f alpha:0.85f];
    }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.15f];
    _hueRingLayer.strokeColor = [color CGColor];
    [CATransaction commit];
}

// ── Tap ───────────────────────────────────────────────────────────────────────
- (void)buttonClicked {
    if (!self.isMoving)
        [[VCamBridge sharedInstance] presentation];
}

// ── Drag — raw UIResponder touch overrides (more reliable than gesture recs) ──
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t    = [touches anyObject];
    _dragStartCenter  = self.center;
    _touchStartInView = [t locationInView:self.superview];
    self.isMoving = NO;
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t    = [touches anyObject];
    CGPoint  curr = [t locationInView:self.superview];

    CGFloat dx = curr.x - _touchStartInView.x;
    CGFloat dy = curr.y - _touchStartInView.y;

    if (!self.isMoving && (fabsf(dx) > 1.0f || fabsf(dy) > 1.0f))
        self.isMoving = YES;

    if (self.isMoving) {
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        CGFloat halfW   = self.frame.size.width  * 0.5f;
        CGFloat halfH   = self.frame.size.height * 0.5f;

        CGPoint c;
        c.x = _dragStartCenter.x + dx;
        c.y = _dragStartCenter.y + dy;
        if (c.x < halfW)             c.x = halfW;
        if (c.x > screenW - halfW)   c.x = screenW - halfW;
        if (c.y < halfH + 20.0f)     c.y = halfH + 20.0f;
        if (c.y > screenH - halfH)   c.y = screenH - halfH;
        self.center = c;
    }

    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.isMoving = NO;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.isMoving = NO;
}

@end

// ── vcamUpdateFloatButton ─────────────────────────────────────────────────────
void vcamUpdateFloatButton(void) {
    VCamColorPickerWindow *pickerWin = [VCamColorPickerWindow sharedWindow];

    if (!g_floatButton) {
        g_floatButton = [[VCamFloatButton alloc] initWithFrame:CGRectMake(0, 0, 50, 50)];

        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        [g_floatButton setCenter:CGPointMake(screenW - 30.0f, 150.0f)];

        [pickerWin.rootViewController.view addSubview:g_floatButton];
    }

    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width > sz.height) {
        [g_floatButton setCenter:CGPointMake(40.0f, 160.0f)];
    }

    BOOL showFloat = [[VCamLiveManager sharedInstance] getFloatWindow];
    BOOL locked    = (BOOL)g_lockScreenVisible;
    BOOL hidden    = !showFloat || locked;

    [g_floatButton setHidden:hidden];
    pickerWin.hidden = hidden;
    [g_floatButton setEnabled:showFloat];
    [g_floatButton setUserInteractionEnabled:showFloat];

    if (hidden) return;

    NSDictionary *fp = BINFlashLoadPrefs();
    BOOL flashOn   = BINFlashBoolForKey(fp, kBINFlashKeyFlash,     kBINFlashDefaultFlash);
    BOOL autoColor = BINFlashBoolForKey(fp, kBINFlashKeyAutoColor, kBINFlashDefaultAutoColor);
    BOOL menuPresent = [[VCamBridge sharedInstance] isPresent];

    if (!flashOn || !autoColor) return;
    if (menuPresent) return;
    if (g_floatButton.isMoving) return;
    if (sz.width <= 0 || sz.height <= 0) return;

    CGPoint center = g_floatButton.center;
    vcamSendPickerSampleRequest((float)(center.x / sz.width),
                                (float)(center.y / sz.height));
}

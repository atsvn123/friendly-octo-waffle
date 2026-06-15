// VCamFloatButton.m
// Donut ring button — raw touch overrides for drag/tap (no gesture recognizers).

#import "VCamFloatButton.h"
#import "VCamColorPickerWindow.h"
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <QuartzCore/QuartzCore.h>

VCamFloatButton *g_floatButton = nil;

static const CGFloat kOuterR = 22.0;
static const CGFloat kInnerR = 15.0;

@implementation VCamFloatButton {
    CAShapeLayer *_donutLayer;
    CGPoint       _dragStartCenter;   // button center when touch began
    CGPoint       _touchStartInView;  // finger location (superview coords) when touch began
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;

    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.clipsToBounds = NO;

    [self _buildDonut];

    // UIControl target — buttonClicked guards with !isMoving so drag never opens menu
    [self addTarget:self action:@selector(buttonClicked)
   forControlEvents:UIControlEventTouchUpInside];

    return self;
}

- (void)_buildDonut {
    CGFloat cx = self.bounds.size.width  * 0.5;
    CGFloat cy = self.bounds.size.height * 0.5;

    CGFloat arcR      = (kOuterR + kInnerR) * 0.5;   // 18.5pt arc centre
    CGFloat ringWidth = kOuterR - kInnerR;             // 7pt ring thickness

    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(cx, cy)
                                                        radius:arcR
                                                    startAngle:0
                                                      endAngle:M_PI * 2.0
                                                     clockwise:YES];

    _donutLayer = [[CAShapeLayer alloc] init];
    _donutLayer.path        = path.CGPath;
    _donutLayer.fillColor   = [[UIColor clearColor] CGColor];
    _donutLayer.strokeColor = [[UIColor colorWithWhite:1.0 alpha:0.90] CGColor];
    _donutLayer.lineWidth   = ringWidth;

    _donutLayer.shadowColor   = [[UIColor blackColor] CGColor];
    _donutLayer.shadowOpacity = 0.40f;
    _donutLayer.shadowOffset  = CGSizeMake(0, 1);
    _donutLayer.shadowRadius  = 4.0;

    [self.layer addSublayer:_donutLayer];
    [_donutLayer release];
}

// Full-frame hit zone — centre hole still registers touches
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(self.bounds, point);
}

// ── Ring hue ──────────────────────────────────────────────────────────────────
- (void)setRingHue:(double)hue {
    UIColor *color;
    if (hue >= 0.0 && hue <= 1.0) {
        color = [UIColor colorWithHue:(CGFloat)hue saturation:0.80
                           brightness:1.0 alpha:0.95];
    } else {
        color = [UIColor colorWithWhite:1.0 alpha:0.90];
    }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.15];
    _donutLayer.strokeColor = [color CGColor];
    [CATransaction commit];
}

// ── Tap ───────────────────────────────────────────────────────────────────────
- (void)buttonClicked {
    if (!self.isMoving)
        [[VCamBridge sharedInstance] presentation];
}

// ── Drag — raw UIResponder touches (more reliable than gesture recognizers) ───
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
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
        if (c.x < halfW)            c.x = halfW;
        if (c.x > screenW - halfW)  c.x = screenW - halfW;
        if (c.y < halfH + 20.0f)    c.y = halfH + 20.0f;
        if (c.y > screenH - halfH)  c.y = screenH - halfH;
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

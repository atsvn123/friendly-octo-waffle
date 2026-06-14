// VCamFloatButton.m
// Donut ring button: 74×74 pt frame, outer radius 35pt, inner hole radius 22pt.
// Center hole (44pt diameter) is transparent — the background shows through.
// Ring fill color = sampled hue (auto color feedback). White = no color detected.

#import "VCamFloatButton.h"
#import "VCamColorPickerWindow.h"
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <QuartzCore/QuartzCore.h>

VCamFloatButton *g_floatButton = nil;

// Outer and inner radii for the donut ring (in points).
static const CGFloat kOuterR = 22.0;
static const CGFloat kInnerR = 15.0;

@implementation VCamFloatButton {
    CAShapeLayer *_donutLayer;
    CGPoint       _dragStartCenter;   // button center when pan began
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;

    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.clipsToBounds = NO;

    [self _buildDonut];

    // Use gesture recognizers instead of UIControl events — more reliable on iOS 15/16.
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handlePan:)];
    [self addGestureRecognizer:pan];
    [pan release];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleTap:)];
    [self addGestureRecognizer:tap];
    [tap release];

    return self;
}

- (void)_buildDonut {
    CGFloat cx = self.bounds.size.width  * 0.5;
    CGFloat cy = self.bounds.size.height * 0.5;
    CGPoint center = CGPointMake(cx, cy);

    // Use stroke-only circle: fillColor=clear so the center is truly transparent.
    // Ring is centered on arcR with lineWidth on each side:
    //   arcR = (kOuterR + kInnerR) / 2 = 28.5pt → lineWidth = kOuterR - kInnerR = 13pt
    CGFloat arcR      = (kOuterR + kInnerR) * 0.5;   // 28.5pt arc center
    CGFloat ringWidth = kOuterR - kInnerR;             // 13pt ring thickness

    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:center
                                                        radius:arcR
                                                    startAngle:0
                                                      endAngle:M_PI * 2.0
                                                     clockwise:YES];

    _donutLayer = [[CAShapeLayer alloc] init];
    _donutLayer.path        = path.CGPath;
    _donutLayer.fillColor   = [[UIColor clearColor] CGColor];   // center transparent
    _donutLayer.strokeColor = [[UIColor colorWithWhite:1.0 alpha:0.90] CGColor];
    _donutLayer.lineWidth   = ringWidth;

    // Shadow follows the stroke so ring is visible on any background.
    _donutLayer.shadowColor   = [[UIColor blackColor] CGColor];
    _donutLayer.shadowOpacity = 0.40f;
    _donutLayer.shadowOffset  = CGSizeMake(0, 1);
    _donutLayer.shadowRadius  = 4.0;

    [self.layer addSublayer:_donutLayer];
    [_donutLayer release];
}

// Full-bounds hit zone so every pixel in the frame registers, regardless of whether
// the pixel is transparent or part of the center hole.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(self.bounds, point);
}

// ── Ring color ────────────────────────────────────────────────────────────────
// hue [0,1) → tint ring to that color (auto color feedback).
// hue < 0   → white ring (no color / achromatic background).
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
    [[VCamBridge sharedInstance] presentation];
}

- (void)_handleTap:(UITapGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateRecognized)
        [self buttonClicked];
}

// ── Drag ──────────────────────────────────────────────────────────────────────
- (void)_handlePan:(UIPanGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        _dragStartCenter = self.center;
        self.isMoving = NO;
    }

    CGPoint t = [gr translationInView:self.superview];

    if (!self.isMoving && (fabsf(t.x) > 2.0f || fabsf(t.y) > 2.0f))
        self.isMoving = YES;

    if (self.isMoving) {
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        CGFloat half    = self.frame.size.width  * 0.5;
        CGFloat halfH   = self.frame.size.height * 0.5;

        CGPoint c;
        c.x = _dragStartCenter.x + t.x;
        c.y = _dragStartCenter.y + t.y;
        if (c.x < half)           c.x = half;
        if (c.x > screenW - half) c.x = screenW - half;
        if (c.y < halfH + 20.0)   c.y = halfH + 20.0;
        if (c.y > screenH - halfH) c.y = screenH - halfH;
        self.center = c;
    }

    if (gr.state == UIGestureRecognizerStateEnded ||
        gr.state == UIGestureRecognizerStateCancelled) {
        self.isMoving = NO;
    }
}

@end

// ── vcamUpdateFloatButton ─────────────────────────────────────────────────────
void vcamUpdateFloatButton(void) {
    VCamColorPickerWindow *pickerWin = [VCamColorPickerWindow sharedWindow];

    if (!g_floatButton) {
        g_floatButton = [[VCamFloatButton alloc] initWithFrame:CGRectMake(0, 0, 50, 50)];

        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        [g_floatButton setCenter:CGPointMake(screenW - 30.0, 150.0)];

        [pickerWin.rootViewController.view addSubview:g_floatButton];
    }

    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width > sz.height) {
        [g_floatButton setCenter:CGPointMake(40.0, 160.0)];
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

    if (!flashOn || !autoColor) {
        [g_floatButton setRingHue:-1.0];
        return;
    }

    if (menuPresent) return;

    if (sz.width <= 0 || sz.height <= 0) return;
    CGPoint center = g_floatButton.center;
    vcamSendPickerSampleRequest((float)(center.x / sz.width),
                                (float)(center.y / sz.height));
}

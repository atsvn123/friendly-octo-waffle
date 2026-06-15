// VCamFloatButton.m
// Donut ring visual with Y button drag logic
// (incremental deltas in button-local coords -- locationInView:self)

#import "VCamFloatButton.h"
#import "VCamColorPickerWindow.h"
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kArcR  = 18.5;
static const CGFloat kLineW = 7.0;

VCamFloatButton *g_floatButton = nil;

@implementation VCamFloatButton {
    CAShapeLayer *_donutLayer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque          = NO;
        self.clipsToBounds   = NO;
        [self _buildDonut];

        [self addTarget:self action:@selector(buttonClicked)
       forControlEvents:UIControlEventTouchUpInside];
        [self addTarget:self action:@selector(buttonDoubleClicked)
       forControlEvents:UIControlEventTouchDownRepeat];
        [self addTarget:self action:@selector(buttonDrag)
       forControlEvents:UIControlEventTouchDragInside];
    }
    return self;
}

- (void)_buildDonut {
    CGFloat cx = self.bounds.size.width  * 0.5;
    CGFloat cy = self.bounds.size.height * 0.5;

    _donutLayer = [[CAShapeLayer alloc] init];
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(cx, cy)
                                                        radius:kArcR
                                                    startAngle:0
                                                      endAngle:2.0 * M_PI
                                                     clockwise:YES];
    _donutLayer.path        = path.CGPath;
    _donutLayer.fillColor   = [UIColor clearColor].CGColor;
    _donutLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.90].CGColor;
    _donutLayer.lineWidth   = kLineW;
    _donutLayer.shadowColor   = [UIColor blackColor].CGColor;
    _donutLayer.shadowOpacity = 0.45f;
    _donutLayer.shadowOffset  = CGSizeMake(0, 1);
    _donutLayer.shadowRadius  = 4.0;
    [self.layer addSublayer:_donutLayer];
    [_donutLayer release];
}

// Full-bounds hit zone so taps anywhere inside the 52x52 frame register.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(self.bounds, point);
}

// -- Hue tint -----------------------------------------------------------------
// hue in [0,1) -> tint donut ring with that hue color.
// hue = -1.0   -> reset donut to neutral white.
- (void)setRingHue:(double)hue {
    UIColor *color;
    if (hue < 0.0) {
        color = [UIColor colorWithWhite:1.0 alpha:0.90];
    } else {
        color = [UIColor colorWithHue:(CGFloat)hue saturation:0.80
                           brightness:1.0 alpha:0.95];
    }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.15];
    _donutLayer.strokeColor = [color CGColor];
    [CATransaction commit];
}

// -- Touch actions ------------------------------------------------------------
- (void)buttonClicked {
    if (!self.isMoving) {
        [[VCamBridge sharedInstance] presentation];
    }
}

- (void)buttonDoubleClicked {
    (void)self.isMoving;
}

- (void)buttonDrag {
}

// -- Drag -- identical to Y button (d224837) ----------------------------------
// locationInView:self gives button-local coords. As the button moves each frame,
// the local frame shifts, so (loc - beginPosition) is a natural incremental delta
// without needing to track total travel.
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.isMoving      = NO;
    UITouch *touch     = [touches anyObject];
    self.beginPosition = [touch locationInView:self];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *touch = [touches anyObject];
    CGPoint loc    = [touch locationInView:self];

    float dx = (float)(loc.x - self.beginPosition.x);
    float dy = (float)(loc.y - self.beginPosition.y);
    self.offsetX = dx;
    self.offsetY = dy;

    if (dx > 1.0f || dx < -1.0f || dy > 1.0f || dy < -1.0f) {
        self.isMoving = YES;
    }

    CGPoint c = self.center;
    c.x += self.offsetX;
    c.y += self.offsetY;
    self.center = c;

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    c = self.center;
    if (c.x <= screenW) {
        if (c.x < 0.0) self.center = CGPointMake(0.0, c.y);
    } else {
        self.center = CGPointMake(screenW, c.y);
    }

    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    c = self.center;
    if (c.y <= screenH) {
        CGFloat minY = self.frame.size.height * 0.5 + 20.0;
        if (c.y < minY) self.center = CGPointMake(c.x, minY);
    } else {
        self.center = CGPointMake(c.x, screenH);
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
}

@end

// -- vcamUpdateFloatButton -- mirrors sub_84D20 (0x84D20) ---------------------
void vcamUpdateFloatButton(void) {
    VCamColorPickerWindow *pickerWin = [VCamColorPickerWindow sharedWindow];

    if (!g_floatButton) {
        g_floatButton = [[VCamFloatButton alloc]
                         initWithFrame:CGRectMake(0, 0, 52, 52)];

        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        [g_floatButton setCenter:CGPointMake(screenW - 30.0, 150.0)];
        g_floatButton.clipsToBounds = NO;
        [g_floatButton setAlpha:0.9f];

        [pickerWin.rootViewController.view addSubview:g_floatButton];
    }

    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width > sz.height) {
        [g_floatButton setCenter:CGPointMake(20.0, 150.0)];
    }

    BOOL showFloat = [[VCamLiveManager sharedInstance] getFloatWindow];
    BOOL locked    = (BOOL)g_lockScreenVisible;
    BOOL hidden    = !showFloat || locked;

    [g_floatButton setHidden:hidden];
    pickerWin.hidden = hidden;
    [g_floatButton setEnabled:showFloat];
    [g_floatButton setUserInteractionEnabled:showFloat];

    if (hidden) return;

    NSDictionary *fp  = BINFlashLoadPrefs();
    BOOL flashOn      = BINFlashBoolForKey(fp, kBINFlashKeyFlash,     kBINFlashDefaultFlash);
    BOOL autoColor    = BINFlashBoolForKey(fp, kBINFlashKeyAutoColor, kBINFlashDefaultAutoColor);
    BOOL menuPresent  = [[VCamBridge sharedInstance] isPresent];

    if (!flashOn || !autoColor) {
        [g_floatButton setRingHue:-1.0];
        return;
    }

    if (menuPresent) {
        return;
    }

    if (sz.width <= 0 || sz.height <= 0) return;
    CGPoint center = g_floatButton.center;
    vcamSendPickerSampleRequest((float)(center.x / sz.width),
                                (float)(center.y / sz.height));
}

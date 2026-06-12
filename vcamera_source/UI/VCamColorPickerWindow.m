// VCamColorPickerWindow.m

#import "VCamColorPickerWindow.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#include <string.h>

// ── Circle view (transparent hole, colored ring) ──────────────────────────────

@interface VCamPickerCircleView : UIView
@property (nonatomic, strong) UIColor *ringColor;
@end

@implementation VCamPickerCircleView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        _ringColor = [[UIColor colorWithHue:0.33 saturation:1.0 brightness:1.0 alpha:1.0] retain];
    }
    return self;
}

- (void)dealloc {
    [_ringColor release];
    [super dealloc];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat cx = rect.size.width  * 0.5;
    CGFloat cy = rect.size.height * 0.5;
    CGFloat r  = fmin(cx, cy) - 3.0;

    // Clear everything (makes center transparent)
    CGContextClearRect(ctx, rect);

    // White shadow ring for visibility over any background
    CGContextSetLineWidth(ctx, 6.0);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.7].CGColor);
    CGContextAddArc(ctx, cx, cy, r, 0, 2.0 * M_PI, 0);
    CGContextStrokePath(ctx);

    // Colored ring showing current hue
    CGContextSetLineWidth(ctx, 4.0);
    CGContextSetStrokeColorWithColor(ctx, _ringColor.CGColor);
    CGContextAddArc(ctx, cx, cy, r - 1.0, 0, 2.0 * M_PI, 0);
    CGContextStrokePath(ctx);

    // Crosshair
    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.9 alpha:0.9].CGColor);
    CGContextMoveToPoint(ctx, cx - 8, cy);
    CGContextAddLineToPoint(ctx, cx + 8, cy);
    CGContextMoveToPoint(ctx, cx, cy - 8);
    CGContextAddLineToPoint(ctx, cx, cy + 8);
    CGContextStrokePath(ctx);
}

@end

// ── Pass-through root view (only hits on the circle pass through) ─────────────

@interface VCamPickerRootView : UIView
@property (nonatomic, assign) UIView *circleView;  // weak
@end

@implementation VCamPickerRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;  // passes through to windows below
    return hit;
}
@end

// ── Color picker window ───────────────────────────────────────────────────────

@interface VCamColorPickerWindow () {
    VCamPickerCircleView        *_circleView;
    NSTimer                     *_sampleTimer;
    CGPoint                      _touchOffset;
    UIPanGestureRecognizer       *_panGesture;
}
@end

@implementation VCamColorPickerWindow

// Pass through all touches that don't hit the circle itself.
// Without this override, UIView's default hitTest returns self (the window) when
// no subview claims the touch — blocking every touch from reaching lower windows.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == nil || hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

+ (instancetype)sharedWindow {
    static VCamColorPickerWindow *s_window = nil;
    static dispatch_once_t s_once = 0;
    dispatch_once(&s_once, ^{
        s_window = [[VCamColorPickerWindow alloc]
                    initWithFrame:[UIScreen mainScreen].bounds];
    });
    return s_window;
}

- (instancetype)initWithFrame:(CGRect)frame {
    // iOS 13+: UIWindows without a UIWindowScene are invisible in SpringBoard.
    UIWindowScene *scene = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        if (sc.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)sc; break; }
        if (!scene) scene = (UIWindowScene *)sc;
    }
    if (scene) {
        self = [super initWithWindowScene:scene];
        if (self) self.frame = frame;
    } else {
        self = [super initWithFrame:frame];
    }
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.windowLevel = UIWindowLevelStatusBar + 8000.0;
        self.hidden = YES;

        VCamPickerRootView *root = [[VCamPickerRootView alloc] initWithFrame:frame];
        root.backgroundColor = [UIColor clearColor];

        // Start circle at screen center
        CGFloat d = 64.0;
        CGFloat cx = frame.size.width  * 0.5;
        CGFloat cy = frame.size.height * 0.45;
        _circleView = [[VCamPickerCircleView alloc] initWithFrame:
                       CGRectMake(cx - d*0.5, cy - d*0.5, d, d)];
        _circleView.userInteractionEnabled = YES;

        // Drag gesture — retained so setDraggable: can toggle it
        _panGesture = [[UIPanGestureRecognizer alloc]
                       initWithTarget:self action:@selector(handlePan:)];
        [_circleView addGestureRecognizer:_panGesture];

        root.circleView = _circleView;
        [root addSubview:_circleView];
        self.rootViewController = [[UIViewController alloc] init];
        self.rootViewController.view = root;
        [root release];
    }
    return self;
}

- (void)dealloc {
    [_circleView release];
    [_panGesture release];
    [_sampleTimer invalidate];
    [_sampleTimer release];
    [super dealloc];
}

// notify tokens — static, registered once for the lifetime of the picker
static int s_reqToken  = NOTIFY_TOKEN_INVALID;
static int s_respToken = NOTIFY_TOKEN_INVALID;

- (void)showPicker {
    self.hidden = NO;
    _panGesture.enabled = YES;

    // Register request-post token once (used only to set state before posting).
    if (s_reqToken == NOTIFY_TOKEN_INVALID) {
        notify_register_check("com.vcam.samplerequest", &s_reqToken);
    }

    // Register response listener once.
    // The frontmost app (TikTok etc.) samples its screen and posts a hue here.
    if (s_respToken == NOTIFY_TOKEN_INVALID) {
        VCamColorPickerWindow *bSelf = self;  // singleton, never deallocated
        notify_register_dispatch(
            "com.vcam.sampleresponse",
            &s_respToken,
            dispatch_get_main_queue(),
            ^(int token) {
                if (bSelf.hidden) return;  // picker was hidden, ignore stale response

                uint64_t state = 0;
                notify_get_state(token, &state);
                uint32_t hueBits = (uint32_t)(state & 0xFFFFFFFFULL);
                float hf = 0.0f;
                memcpy(&hf, &hueBits, 4);
                double h = (double)hf;
                if (h < 0.0 || h > 1.0) return;

                // Update ring to reflect sampled hue
                bSelf->_circleView.ringColor =
                    [UIColor colorWithHue:h saturation:1.0 brightness:1.0 alpha:1.0];
                [bSelf->_circleView setNeedsDisplay];

                // Persist hue for flash effect in mediaserverd
                BINFlashSavePrefs(@{ kBINFlashKeyHue: @(h) });
            });
    }

    if (!_sampleTimer) {
        _sampleTimer = [[NSTimer scheduledTimerWithTimeInterval:0.35
                                                         target:self
                                                       selector:@selector(sampleTick)
                                                       userInfo:nil
                                                        repeats:YES] retain];
    }
}

- (void)hidePicker {
    [_sampleTimer invalidate];
    [_sampleTimer release];
    _sampleTimer = nil;
    _panGesture.enabled = NO;
    self.hidden = YES;
}

- (void)setDraggable:(BOOL)draggable {
    _panGesture.enabled = draggable;
}

// ── Drag ──────────────────────────────────────────────────────────────────────
- (void)handlePan:(UIPanGestureRecognizer *)gr {
    CGPoint translation = [gr translationInView:self.rootViewController.view];
    CGPoint center = _circleView.center;
    center.x += translation.x;
    center.y += translation.y;

    CGFloat margin = 40.0;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    center.x = fmax(margin, fmin(sw - margin, center.x));
    center.y = fmax(margin, fmin(sh - margin, center.y));

    _circleView.center = center;
    [gr setTranslation:CGPointZero inView:self.rootViewController.view];
}

// ── Sample tick ───────────────────────────────────────────────────────────────
// Sends the circle's screen-space coordinates to the frontmost app via Darwin notify.
// The frontmost app (registered by vcamInstallColorSampleListener) takes a UIScreen
// snapshot from inside its own process and posts the sampled hue back.
- (void)sampleTick {
    if (s_reqToken == NOTIFY_TOKEN_INVALID) return;

    // Pack NORMALIZED (0..1) position so the mediaserverd RTMP sampler does not
    // need UIScreen. Normalized avoids coupling the sender to device screen size.
    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width <= 0.0 || sz.height <= 0.0) return;
    CGPoint pt = _circleView.center;
    float xf = (float)(pt.x / sz.width);
    float yf = (float)(pt.y / sz.height);
    uint32_t xBits = 0, yBits = 0;
    memcpy(&xBits, &xf, 4);
    memcpy(&yBits, &yf, 4);
    uint64_t packed = ((uint64_t)xBits << 32) | (uint64_t)yBits;

    notify_set_state(s_reqToken, packed);
    notify_post("com.vcam.samplerequest");
    // Response arrives asynchronously in the handler registered in showPicker.
}

@end

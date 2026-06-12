// VCamFloatButton.m
// Reconstructed from iHsfaTkdhwkzopQfsnwBd (0x12AD60) and sub_84D20 (0x84D20)
//
// IDA-confirmed behavior:
//  - UIButton subclass, 52x52, cornerRadius 26
//  - Fixed reddish color rgba(0.788, 0.282, 0.216, 0.9) — not state-dependent
//  - Title "B" from XOR-decoded base64 ("GA==" XOR 0x5A = 0x42 = 'B')
//  - Now lives in a dedicated high-level UIWindow (UIWindowLevelStatusBar + 10000)
//    so it stays above all apps without needing to re-add to keyWindow every tick.
//  - Tap: buttonClicked fires if !isMoving → [[VCamBridge sharedInstance] presentation]
//  - Drag: touchesBegan stores beginPosition; touchesMoved moves + clamps;
//          touchesEnded snaps to nearest vertical edge (anim duration=0 delay=0.5s)

#import "VCamFloatButton.h"
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"
#import <QuartzCore/QuartzCore.h>

// ── Pass-through window: touches on the button work; touches elsewhere pass through ──
@interface VCamFloatPassthroughWindow : UIWindow
@end

@implementation VCamFloatPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // If the hit is our own root view (empty background), pass through
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

// Global button and its dedicated window
static VCamFloatButton               *g_floatButton = nil;
static VCamFloatPassthroughWindow    *g_floatWindow = nil;

@implementation VCamFloatButton

// ── -initWithFrame: (0x8F878) ────────────────────────────────────────────────
// Calls super then installs the three UIControl action targets.
// Visual styling is applied by vcamUpdateFloatButton() after this returns.
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self addTarget:self action:@selector(buttonClicked)
       forControlEvents:UIControlEventTouchUpInside];       // 64
        [self addTarget:self action:@selector(buttonDoubleClicked)
       forControlEvents:UIControlEventTouchDownRepeat];     // 2
        [self addTarget:self action:@selector(buttonDrag)
       forControlEvents:UIControlEventTouchDragInside];     // 4
    }
    return self;
}

// ── -buttonClicked (0x8F908) ─────────────────────────────────────────────────
- (void)buttonClicked {
    if (!self.isMoving) {
        [[VCamBridge sharedInstance] presentation];
    }
}

// ── -buttonDoubleClicked (0x8F964) ───────────────────────────────────────────
// IDA thunk — reads isMoving, discards result (NOP).
- (void)buttonDoubleClicked {
    (void)self.isMoving;
}

// ── -buttonDrag (0x8F968) ────────────────────────────────────────────────────
// Empty — drag is handled by touchesMoved:withEvent: directly.
- (void)buttonDrag {
}

// ── -touchesBegan:withEvent: (0x8F970) ───────────────────────────────────────
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.isMoving = NO;
    UITouch *touch = [touches anyObject];
    self.beginPosition = [touch locationInView:self];
}

// ── -touchesMoved:withEvent: (0x8FA18) ───────────────────────────────────────
// Moves button by delta from initial touch. Sets isMoving once offset > 1px.
// Clamps center to screen bounds.
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];

    UITouch *touch = [touches anyObject];
    CGPoint loc = [touch locationInView:self];

    // IDA: delta truncated to float before storing
    float dx = (float)(loc.x - self.beginPosition.x);
    float dy = (float)(loc.y - self.beginPosition.y);
    self.offsetX = dx;
    self.offsetY = dy;

    if (dx > 1.0f || dx < -1.0f || dy > 1.0f || dy < -1.0f) {
        self.isMoving = YES;
    }

    // Move
    CGPoint c = self.center;
    c.x += self.offsetX;
    c.y += self.offsetY;
    self.center = c;

    // Clamp X: [0, screenW]
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    c = self.center;
    if (c.x <= screenW) {
        if (c.x < 0.0) self.center = CGPointMake(0.0, c.y);
    } else {
        self.center = CGPointMake(screenW, c.y);
    }

    // Clamp Y: [frame.height/2 + 20, screenH]
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    c = self.center;
    if (c.y <= screenH) {
        CGFloat minY = self.frame.size.height * 0.5 + 20.0;
        if (c.y < minY) self.center = CGPointMake(c.x, minY);
    } else {
        self.center = CGPointMake(c.x, screenH);
    }
}

// ── -touchesEnded:withEvent: (0x8FCF4) ───────────────────────────────────────
// Snap to nearest vertical edge. Animation: duration=0, delay=0.5s (IDA confirmed).
// Bottom-edge check: if frame.origin.y + 40 + frame.height > screenH, snap Y too.
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];

    CGFloat screenW    = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH    = [UIScreen mainScreen].bounds.size.height;
    CGFloat cx         = self.center.x;
    CGFloat currentY   = self.center.y;
    CGFloat bottomEdge = self.frame.origin.y + 40.0 + self.frame.size.height;
    CGFloat snapX      = (cx <= screenW * 0.5) ? 30.0 : (screenW - 30.0);
    BOOL    atBottom   = (bottomEdge > screenH);

    [UIView animateWithDuration:0.0
                          delay:0.5
                        options:0
                     animations:^{
        if (atBottom) {
            self.center = CGPointMake(snapX, screenH - 30.0);
        } else {
            self.center = CGPointMake(snapX, currentY);
        }
    } completion:nil];
}

@end

// ── vcamUpdateFloatButton — mirrors sub_84D20 (0x84D20) ──────────────────────
//
// Must be called on the MAIN QUEUE.
// First call: creates a dedicated high-level UIWindow + the button inside it.
// Every call: updates hidden/enabled state only — no re-adding needed.
void vcamUpdateFloatButton(void) {
    // ── Create the dedicated window on first call ──
    if (!g_floatWindow) {
        CGRect screenBounds = [UIScreen mainScreen].bounds;

        // iOS 16+: UIWindows created with initWithFrame: are not associated with a
        // UIWindowScene and UIKit silently ignores hidden=NO on them. Use
        // initWithWindowScene: so the window actually appears on screen.
        // Prefer the foreground-active scene; fall back to any scene; then
        // fall back to initWithFrame: for iOS 15 / no-scene environments.
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
            if (!scene) scene = (UIWindowScene *)s;  // best fallback so far
        }

        if (scene) {
            g_floatWindow = [[VCamFloatPassthroughWindow alloc] initWithWindowScene:scene];
        } else {
            g_floatWindow = [[VCamFloatPassthroughWindow alloc] initWithFrame:screenBounds];
        }

        g_floatWindow.backgroundColor = [UIColor clearColor];
        g_floatWindow.opaque = NO;
        g_floatWindow.windowLevel = UIWindowLevelStatusBar + 10000.0;

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        rootVC.view.userInteractionEnabled = YES;
        g_floatWindow.rootViewController = rootVC;
        [rootVC release];

        g_floatWindow.hidden = NO;
    }

    // ── Create button on first call ──
    if (!g_floatButton) {
        g_floatButton = [[VCamFloatButton alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];

        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        [g_floatButton setCenter:CGPointMake(screenW - 30.0, 150.0)];

        // Background #F7B7CC (light pink)
        UIColor *color = [UIColor colorWithRed:0.9686f green:0.7176f blue:0.8000f alpha:0.9f];
        [g_floatButton setBackgroundColor:color];
        [g_floatButton setClipsToBounds:YES];
        g_floatButton.layer.cornerRadius = 26.0;
        [g_floatButton setAlpha:0.9f];

        // Title color #4B3340 (dark mauve)
        UIColor *titleColor = [UIColor colorWithRed:0.2941f green:0.2000f blue:0.2510f alpha:1.0f];
        [g_floatButton setTitleColor:titleColor forState:UIControlStateNormal];

        // Title "Y" — XOR decode: base64("Aw==")={0x03}, 0x03^0x5A=0x59='Y'
        NSData *raw = [[NSData alloc] initWithBase64EncodedString:@"Aw==" options:0];
        NSString *title = nil;
        if (raw) {
            NSMutableData *mut = [raw mutableCopy];
            [raw release];
            uint8_t *bytes = (uint8_t *)[mut mutableBytes];
            NSUInteger len  = [mut length];
            for (NSUInteger i = 0; i < len; i++) bytes[i] ^= 0x5A;
            title = [[NSString alloc] initWithData:mut encoding:NSUTF8StringEncoding];
            [mut release];
        }
        if (!title) title = [@"" retain];
        [g_floatButton setTitle:title forState:UIControlStateNormal];
        [title release];
        g_floatButton.titleLabel.font = [UIFont systemFontOfSize:26.0];

        // Add button to the dedicated window's root view — permanent, no re-adding needed
        [g_floatWindow.rootViewController.view addSubview:g_floatButton];
    }

    // ── Every call: update position for landscape, update visibility ──
    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width > sz.height) {
        [g_floatButton setCenter:CGPointMake(20.0, 150.0)];
    }

    // Hidden while lock screen is visible
    [g_floatButton setHidden:(BOOL)g_lockScreenVisible];

    // Show/hide window based on float pref
    BOOL showFloat = [[VCamLiveManager sharedInstance] getFloatWindow];
    g_floatWindow.hidden = !showFloat || (BOOL)g_lockScreenVisible;
    [g_floatButton setEnabled:showFloat];
    [g_floatButton setUserInteractionEnabled:showFloat];
}

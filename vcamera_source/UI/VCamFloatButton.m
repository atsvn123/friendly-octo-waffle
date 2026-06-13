// VCamFloatButton.m
// Reconstructed from iHsfaTkdhwkzopQfsnwBd (0x12AD60) and sub_84D20 (0x84D20)

#import "VCamFloatButton.h"
#import "VCamColorPickerWindow.h"
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <QuartzCore/QuartzCore.h>
#include <string.h>

// Non-static so VCamColorPickerWindow.m can reference it via extern.
VCamFloatButton *g_floatButton = nil;

@implementation VCamFloatButton {
    CAShapeLayer *_ringLayer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self addTarget:self action:@selector(buttonClicked)
       forControlEvents:UIControlEventTouchUpInside];
        [self addTarget:self action:@selector(buttonDoubleClicked)
       forControlEvents:UIControlEventTouchDownRepeat];
        [self addTarget:self action:@selector(buttonDrag)
       forControlEvents:UIControlEventTouchDragInside];
    }
    return self;
}

// ── Hue ring ─────────────────────────────────────────────────────────────────
// The ring is a CAShapeLayer drawn OUTSIDE the button bounds (radius 30 vs
// button radius 26). clipsToBounds must be NO for it to show (set below).
// hue in [0,1) → show ring in that hue color.
// hue = -1.0    → hide ring (button over achromatic / auto color OFF).
- (void)setRingHue:(double)hue {
    if (!_ringLayer) {
        _ringLayer = [[CAShapeLayer alloc] init];
        _ringLayer.fillColor   = [UIColor clearColor].CGColor;
        _ringLayer.lineWidth   = 4.0;
        _ringLayer.opacity     = 0.0;

        // Circle centered at (26, 26), radius 30 — 4pt halo outside the button
        CGPoint center = CGPointMake(26.0, 26.0);
        UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:center
                                                            radius:30.0
                                                        startAngle:0
                                                          endAngle:2.0 * M_PI
                                                         clockwise:YES];
        _ringLayer.path = path.CGPath;
        [self.layer addSublayer:_ringLayer];
        [_ringLayer release];
    }

    if (hue < 0.0) {
        // Fade out
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.2];
        _ringLayer.opacity = 0.0;
        [CATransaction commit];
    } else {
        _ringLayer.strokeColor = [UIColor colorWithHue:(CGFloat)hue
                                            saturation:1.0
                                            brightness:1.0
                                                 alpha:1.0].CGColor;
        // Fade in
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.2];
        _ringLayer.opacity = 1.0;
        [CATransaction commit];
    }
}

// ── Touch actions ─────────────────────────────────────────────────────────────
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

// ── Drag ──────────────────────────────────────────────────────────────────────
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.isMoving    = NO;
    UITouch *touch   = [touches anyObject];
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

// ── vcamUpdateFloatButton — mirrors sub_84D20 (0x84D20) ──────────────────────
// Must be called on the main queue. First call creates the button and parents it
// to VCamColorPickerWindow (persistent high-level window — no disappearance).
// Every call: updates visibility + samples color if auto color is active.
void vcamUpdateFloatButton(void) {

    // ── Ensure the picker window exists ──
    VCamColorPickerWindow *pickerWin = [VCamColorPickerWindow sharedWindow];

    // ── Create button on first call ──
    if (!g_floatButton) {
        g_floatButton = [[VCamFloatButton alloc]
                         initWithFrame:CGRectMake(0, 0, 52, 52)];

        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        [g_floatButton setCenter:CGPointMake(screenW - 30.0, 150.0)];

        // Background #F7B7CC (light pink)
        [g_floatButton setBackgroundColor:
            [UIColor colorWithRed:0.9686f green:0.7176f blue:0.8000f alpha:0.9f]];

        // clipsToBounds must be NO so the ring halo can draw outside bounds
        g_floatButton.clipsToBounds   = NO;
        g_floatButton.layer.cornerRadius = 26.0;
        [g_floatButton setAlpha:0.9f];

        // Title color #4B3340 (dark mauve)
        [g_floatButton setTitleColor:
            [UIColor colorWithRed:0.2941f green:0.2000f blue:0.2510f alpha:1.0f]
                            forState:UIControlStateNormal];

        // Title "Y" — XOR decode: base64("Aw==")={0x03}, 0x03^0x5A=0x59='Y'
        NSData *raw = [[NSData alloc] initWithBase64EncodedString:@"Aw==" options:0];
        NSString *title = nil;
        if (raw) {
            NSMutableData *mut = [raw mutableCopy];
            [raw release];
            uint8_t *bytes = (uint8_t *)[mut mutableBytes];
            for (NSUInteger i = 0; i < [mut length]; i++) bytes[i] ^= 0x5A;
            title = [[NSString alloc] initWithData:mut encoding:NSUTF8StringEncoding];
            [mut release];
        }
        if (!title) title = [@"" retain];
        [g_floatButton setTitle:title forState:UIControlStateNormal];
        [title release];
        g_floatButton.titleLabel.font = [UIFont systemFontOfSize:26.0];

        // Parent to VCamColorPickerWindow's root view — permanent, never re-added
        [pickerWin.rootViewController.view addSubview:g_floatButton];
    }

    // ── Every call: landscape position, visibility ──
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

    // ── Color sampling when auto color is ON and menu is closed ──
    if (hidden) return;

    NSDictionary *fp      = BINFlashLoadPrefs();
    BOOL autoColor        = BINFlashBoolForKey(fp, kBINFlashKeyAutoColor, kBINFlashDefaultAutoColor);
    BOOL menuPresent      = [[VCamBridge sharedInstance] isPresent];

    if (!autoColor) {
        // Auto color off — hide ring in case it was showing
        [g_floatButton setRingHue:-1.0];
        return;
    }

    if (menuPresent) {
        // Menu open: keep ring visible at last color, but don't sample
        return;
    }

    // Menu closed + auto color on: sample screen color under button center
    CGPoint center = g_floatButton.center;  // in VCamColorPickerWindow coords
    if (sz.width <= 0 || sz.height <= 0) return;
    float nx = (float)(center.x / sz.width);
    float ny = (float)(center.y / sz.height);
    vcamSendPickerSampleRequest(nx, ny);
}

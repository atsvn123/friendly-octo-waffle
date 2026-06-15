// VCamFloatButton.m
// Y button — tap to open menu, drag to move.
// Drag logic: incremental deltas in button-local coords (locationInView:self).

#import "VCamFloatButton.h"
#import "VCamColorPickerWindow.h"
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../BINFlash/BINFlashPrefs.h"
#import "VCamColorDot.h"
#import <QuartzCore/QuartzCore.h>

VCamFloatButton *g_floatButton = nil;

@implementation VCamFloatButton {
    CAShapeLayer *_ringLayer;
    int           _moveLogCount;
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
        NSLog(@"[FloatBtn] init frame=(%.0f,%.0f,%.0f,%.0f)",
              frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    return self;
}

// -- Hue ring (outer halo, lazy init) ----------------------------------------
// radius 30 = 4pt outside the 26pt button radius; clipsToBounds must be NO.
// hue [0,1) -> show ring; hue = -1.0 -> hide ring.
- (void)setRingHue:(double)hue {
    if (!_ringLayer) {
        _ringLayer = [[CAShapeLayer alloc] init];
        _ringLayer.fillColor = [UIColor clearColor].CGColor;
        _ringLayer.lineWidth = 4.0;
        _ringLayer.opacity   = 0.0;
        UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:CGPointMake(26.0, 26.0)
                                                         radius:30.0
                                                     startAngle:0
                                                       endAngle:2.0 * M_PI
                                                      clockwise:YES];
        _ringLayer.path = p.CGPath;
        [self.layer addSublayer:_ringLayer];
        [_ringLayer release];
    }
    if (hue < 0.0) {
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.2];
        _ringLayer.opacity = 0.0;
        [CATransaction commit];
    } else {
        _ringLayer.strokeColor = [UIColor colorWithHue:(CGFloat)hue
                                            saturation:1.0
                                            brightness:1.0
                                                 alpha:1.0].CGColor;
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.2];
        _ringLayer.opacity = 1.0;
        [CATransaction commit];
    }
}

// -- Touch actions ------------------------------------------------------------
- (void)buttonClicked {
    NSLog(@"[FloatBtn] buttonClicked moving=%d", (int)self.isMoving);
    if (!self.isMoving) {
        [[VCamBridge sharedInstance] presentation];
    }
}

- (void)buttonDoubleClicked {
    (void)self.isMoving;
}

- (void)buttonDrag {
}

// -- Drag: incremental deltas in button-local coords --------------------------
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.isMoving    = NO;
    _moveLogCount    = 0;
    UITouch *touch   = [touches anyObject];
    self.beginPosition = [touch locationInView:self];
    CGPoint sc = [touch locationInView:nil];
    NSLog(@"[FloatBtn] touchesBegan screen=(%.1f,%.1f) local=(%.1f,%.1f) btnCenter=(%.1f,%.1f)",
          sc.x, sc.y, self.beginPosition.x, self.beginPosition.y,
          self.center.x, self.center.y);
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *touch = [touches anyObject];
    CGPoint loc    = [touch locationInView:self];

    float dx = (float)(loc.x - self.beginPosition.x);
    float dy = (float)(loc.y - self.beginPosition.y);
    self.offsetX = dx;
    self.offsetY = dy;
    if (dx > 1.0f || dx < -1.0f || dy > 1.0f || dy < -1.0f) self.isMoving = YES;

    CGPoint c = self.center;
    c.x += self.offsetX;
    c.y += self.offsetY;
    self.center = c;

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    c = self.center;
    if (c.x <= screenW) { if (c.x < 0.0) self.center = CGPointMake(0.0, c.y); }
    else                 { self.center = CGPointMake(screenW, c.y); }

    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    c = self.center;
    if (c.y <= screenH) {
        CGFloat minY = self.frame.size.height * 0.5 + 20.0;
        if (c.y < minY) self.center = CGPointMake(c.x, minY);
    } else { self.center = CGPointMake(c.x, screenH); }

}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    NSLog(@"[FloatBtn] touchesEnded center=(%.1f,%.1f) moving=%d",
          self.center.x, self.center.y, (int)self.isMoving);
    self.isMoving = NO;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    NSLog(@"[FloatBtn] touchesCancelled center=(%.1f,%.1f)", self.center.x, self.center.y);
    self.isMoving = NO;
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

        [g_floatButton setBackgroundColor:
            [UIColor colorWithRed:0.9686f green:0.7176f blue:0.8000f alpha:0.9f]];
        g_floatButton.clipsToBounds      = NO;
        g_floatButton.layer.cornerRadius = 26.0;
        [g_floatButton setAlpha:0.9f];
        [g_floatButton setTitleColor:
            [UIColor colorWithRed:0.2941f green:0.2000f blue:0.2510f alpha:1.0f]
                            forState:UIControlStateNormal];

        // "Y" XOR: base64("Aw==")={0x03}, 0x03^0x5A=0x59='Y'
        NSData *raw = [[NSData alloc] initWithBase64EncodedString:@"Aw==" options:0];
        NSString *title = nil;
        if (raw) {
            NSMutableData *mut = [raw mutableCopy]; [raw release];
            uint8_t *bytes = (uint8_t *)[mut mutableBytes];
            for (NSUInteger i = 0; i < [mut length]; i++) bytes[i] ^= 0x5A;
            title = [[NSString alloc] initWithData:mut encoding:NSUTF8StringEncoding];
            [mut release];
        }
        if (!title) title = [@"" retain];
        [g_floatButton setTitle:title forState:UIControlStateNormal];
        [title release];
        g_floatButton.titleLabel.font = [UIFont systemFontOfSize:26.0];

        [pickerWin.rootViewController.view addSubview:g_floatButton];
        NSLog(@"[FloatBtn] created at center=(%.1f,%.1f)", g_floatButton.center.x, g_floatButton.center.y);
    }

    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width > sz.height) [g_floatButton setCenter:CGPointMake(20.0, 150.0)];

    BOOL showFloat = [[VCamLiveManager sharedInstance] getFloatWindow];
    BOOL locked    = (BOOL)g_lockScreenVisible;
    BOOL hidden    = !showFloat || locked;

    [g_floatButton setHidden:hidden];
    pickerWin.hidden = hidden;
    [g_floatButton setEnabled:showFloat];
    [g_floatButton setUserInteractionEnabled:showFloat];

    if (hidden) return;

    NSDictionary *fp = BINFlashLoadPrefs();
    BOOL flashOn     = BINFlashBoolForKey(fp, kBINFlashKeyFlash,     kBINFlashDefaultFlash);
    BOOL autoColor   = BINFlashBoolForKey(fp, kBINFlashKeyAutoColor, kBINFlashDefaultAutoColor);
    BOOL menuPresent = [[VCamBridge sharedInstance] isPresent];

    // Update color dot visibility
    vcamUpdateColorDot(flashOn && autoColor);

    if (!flashOn || !autoColor) {
        [g_floatButton setRingHue:-1.0];
        return;
    }
    if (menuPresent) return;

    // Sample at color dot position
    if (sz.width <= 0 || sz.height <= 0) return;
    CGPoint samplePt = g_colorDot ? g_colorDot.center : g_floatButton.center;
    vcamSendPickerSampleRequest((float)(samplePt.x / sz.width),
                                (float)(samplePt.y / sz.height));
}
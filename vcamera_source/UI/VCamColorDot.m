// VCamColorDot.m
// Drag-only donut for color sampling position.
// backgroundColor=white alpha:0.01 -> BackBoard sees UIKit content -> routes
// touches to SpringBoard even when a RootHide-protected app is foreground.

#import "VCamColorDot.h"
#import "VCamColorPickerWindow.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kDotArcR  = 17.0;
static const CGFloat kDotLineW = 6.0;

VCamColorDot *g_colorDot = nil;

@implementation VCamColorDot {
    CAShapeLayer *_donutLayer;
    int           _moveLogCount;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Near-invisible background: BackBoard needs a UIKit-visible layer to route
        // touches to SpringBoard when a foreground app holds focus.
        self.backgroundColor    = [UIColor colorWithWhite:1.0 alpha:0.01];
        self.opaque             = NO;
        self.clipsToBounds      = NO;
        self.userInteractionEnabled = YES;
        [self _buildDonut];
        NSLog(@"[ColorDot] init frame=(%.0f,%.0f,%.0f,%.0f)",
              frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    return self;
}

- (void)_buildDonut {
    CGFloat cx = self.bounds.size.width  * 0.5;
    CGFloat cy = self.bounds.size.height * 0.5;

    _donutLayer = [[CAShapeLayer alloc] init];
    UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:CGPointMake(cx, cy)
                                                     radius:kDotArcR
                                                 startAngle:0
                                                   endAngle:2.0 * M_PI
                                                  clockwise:YES];
    _donutLayer.path        = p.CGPath;
    _donutLayer.fillColor   = [UIColor clearColor].CGColor;
    _donutLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    _donutLayer.lineWidth   = kDotLineW;
    _donutLayer.shadowColor   = [UIColor blackColor].CGColor;
    _donutLayer.shadowOpacity = 0.50f;
    _donutLayer.shadowOffset  = CGSizeMake(0, 1);
    _donutLayer.shadowRadius  = 3.0;
    [self.layer addSublayer:_donutLayer];
    [_donutLayer release];
}

// Full-bounds hit zone — every point inside the 48x48 frame registers.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(self.bounds, point);
}

// -- Drag: same incremental logic as Y button ---------------------------------
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.isMoving      = NO;
    _moveLogCount      = 0;
    UITouch *touch     = [touches anyObject];
    self.beginPosition = [touch locationInView:self];
    CGPoint sc = [touch locationInView:nil];
    NSLog(@"[ColorDot] touchesBegan screen=(%.1f,%.1f) local=(%.1f,%.1f) dotCenter=(%.1f,%.1f)",
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

    if (++_moveLogCount % 10 == 0) {
        NSLog(@"[ColorDot] touchesMoved dx=%.1f dy=%.1f newCenter=(%.1f,%.1f) moving=%d",
              dx, dy, self.center.x, self.center.y, (int)self.isMoving);
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    NSLog(@"[ColorDot] touchesEnded center=(%.1f,%.1f) moving=%d",
          self.center.x, self.center.y, (int)self.isMoving);
    self.isMoving = NO;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    NSLog(@"[ColorDot] touchesCancelled center=(%.1f,%.1f)", self.center.x, self.center.y);
    self.isMoving = NO;
}

@end

// -- vcamUpdateColorDot -------------------------------------------------------
// show=YES: ensure dot exists and is visible; show=NO: hide.
// Placed at center-screen on first creation, independent of Y button.
void vcamUpdateColorDot(BOOL show) {
    if (!show) {
        if (g_colorDot) {
            [g_colorDot setHidden:YES];
            g_colorDot.userInteractionEnabled = NO;
        }
        return;
    }

    VCamColorPickerWindow *pickerWin = [VCamColorPickerWindow sharedWindow];

    if (!g_colorDot) {
        g_colorDot = [[VCamColorDot alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];

        CGSize sz  = [UIScreen mainScreen].bounds.size;
        CGFloat cx = sz.width  * 0.5;
        CGFloat cy = sz.height * 0.5;
        [g_colorDot setCenter:CGPointMake(cx, cy)];
        g_colorDot.alpha = 0.9f;

        [pickerWin.rootViewController.view addSubview:g_colorDot];
        NSLog(@"[ColorDot] created at center=(%.1f,%.1f)", g_colorDot.center.x, g_colorDot.center.y);
    }

    [g_colorDot setHidden:NO];
    g_colorDot.userInteractionEnabled = YES;
}
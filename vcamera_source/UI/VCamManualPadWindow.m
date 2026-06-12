// VCamManualPadWindow.m

#import "VCamManualPadWindow.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <math.h>

// ── Layout constants ──────────────────────────────────────────────────────────
//  3×3 direction-button grid (centre cell is a dot label, not a button).
//  Card is 160×162; header occupies rows 0..23; grid starts at y=28.
//  Button cell: 44 wide × 38 tall, column gap 8, row gap 4.
//    col x offsets: 8, 8+44+8=60, 60+44+8=112
//    row y offsets: 28, 28+38+4=70, 70+38+4=112

#define CARD_W  160.0f
#define CARD_H  162.0f
#define BTN_W    44.0f
#define BTN_H    38.0f
#define COL0      8.0f
#define COL1     60.0f
#define COL2    112.0f
#define ROW0     28.0f
#define ROW1     70.0f
#define ROW2    112.0f

// Button tags:
//   0=↑  1=↓  2=←  3=→  4=↖  5=↗  6=↙  7=↘

// Axis mapping (confirmed by user testing v2.74):
//   regionX (rx) → VERTICAL axis on screen  (rx decreasing = UP)
//   regionY (ry) → HORIZONTAL axis on screen (ry decreasing = RIGHT)
// Therefore:
//   ↑ → rx -= step      ↓ → rx += step
//   ← → ry += step      → → ry -= step   (ry is INVERTED vs. visual intuition)
// Diagonals combine both axes.

@implementation VCamManualPadWindow {
    UIPanGestureRecognizer *_panGesture;
}

+ (instancetype)sharedWindow {
    static VCamManualPadWindow *s = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        CGRect frame = CGRectMake(sw - CARD_W - 10, 120, CARD_W, CARD_H);
        s = [[VCamManualPadWindow alloc] initWithFrame:frame];
    });
    return s;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.windowLevel = UIWindowLevelStatusBar + 7000.0;
        self.hidden = YES;

        UIViewController *root = [[UIViewController alloc] init];
        self.rootViewController = root;
        [root release];

        UIView *card = self.rootViewController.view;
        card.backgroundColor = [UIColor colorWithWhite:0.97 alpha:0.97];
        card.layer.cornerRadius = 16.0;
        card.layer.borderWidth  = 0.8;
        card.layer.borderColor  = [UIColor colorWithWhite:0.80 alpha:1.0].CGColor;
        card.clipsToBounds = YES;

        // Drag handle
        UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(60, 8, 40, 4)];
        handle.backgroundColor = [UIColor colorWithWhite:0.74 alpha:1.0];
        handle.layer.cornerRadius = 2.0;
        [card addSubview:handle];
        [handle release];

        // Close button (×) — top-right
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(CARD_W - 30, 0, 30, 24);
        [closeBtn setTitle:@"×" forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightLight];
        [closeBtn setTitleColor:[UIColor colorWithWhite:0.55 alpha:1.0] forState:UIControlStateNormal];
        [closeBtn addTarget:self action:@selector(closeTapped)
              forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:closeBtn];

        // Centre dot label (non-interactive)
        UILabel *dot = [[UILabel alloc] initWithFrame:CGRectMake(COL1, ROW1, BTN_W, BTN_H)];
        dot.text = @"·";
        dot.textAlignment = NSTextAlignmentCenter;
        dot.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightLight];
        dot.textColor = [UIColor colorWithWhite:0.70 alpha:1.0];
        [card addSubview:dot];
        [dot release];

        // 8 direction buttons
        UIColor *orange = [UIColor colorWithRed:1.0 green:0.45 blue:0.0 alpha:1.0];
        UIColor *bg     = [UIColor whiteColor];
        UIColor *border = [UIColor colorWithWhite:0.85 alpha:1.0];

        // {title, tag, x, y}
        struct { NSString *title; NSInteger tag; CGFloat x; CGFloat y; } dirs[] = {
            { @"↖", 4, COL0, ROW0 },
            { @"↑",  0, COL1, ROW0 },
            { @"↗", 5, COL2, ROW0 },
            { @"←", 2, COL0, ROW1 },
            { @"→", 3, COL2, ROW1 },
            { @"↙", 6, COL0, ROW2 },
            { @"↓",  1, COL1, ROW2 },
            { @"↘", 7, COL2, ROW2 },
        };
        for (int i = 0; i < 8; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(dirs[i].x, dirs[i].y, BTN_W, BTN_H);
            [btn setTitle:dirs[i].title forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
            [btn setTitleColor:orange forState:UIControlStateNormal];
            btn.backgroundColor = bg;
            btn.layer.cornerRadius = 10.0;
            btn.layer.borderWidth  = 1.0;
            btn.layer.borderColor  = border.CGColor;
            btn.tag = dirs[i].tag;
            [btn addTarget:self action:@selector(dirTapped:)
              forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:btn];
        }

        // Pan gesture to drag the whole window
        _panGesture = [[UIPanGestureRecognizer alloc]
                       initWithTarget:self action:@selector(handlePan:)];
        [card addGestureRecognizer:_panGesture];
    }
    return self;
}

- (void)dealloc {
    [_panGesture release];
    [super dealloc];
}

- (void)showPad { self.hidden = NO; }
- (void)hidePad { self.hidden = YES; }

// ── Drag ──────────────────────────────────────────────────────────────────────
- (void)handlePan:(UIPanGestureRecognizer *)gr {
    CGPoint t = [gr translationInView:self.rootViewController.view];
    CGRect f = self.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;

    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    f.origin.x = fmax(0, fmin(sw - f.size.width,  f.origin.x));
    f.origin.y = fmax(0, fmin(sh - f.size.height, f.origin.y));

    self.frame = f;
    [gr setTranslation:CGPointZero inView:self.rootViewController.view];
}

// ── Close ─────────────────────────────────────────────────────────────────────
- (void)closeTapped {
    [self hidePad];
    BINFlashSavePrefs(@{ kBINFlashKeyManualRegion: @(NO) });
}

// ── Direction taps ────────────────────────────────────────────────────────────
- (void)dirTapped:(UIButton *)btn {
    NSDictionary *fp = BINFlashLoadPrefs();
    double rx = BINFlashDoubleForKey(fp, kBINFlashKeyRegionX, kBINFlashDefaultRegionX);
    double ry = BINFlashDoubleForKey(fp, kBINFlashKeyRegionY, kBINFlashDefaultRegionY);
    const double step = 0.04;

    // Axis mapping (confirmed from device testing):
    //   rx = vertical axis: decreasing → UP on screen
    //   ry = horizontal axis: decreasing → RIGHT on screen (inverted)
    switch (btn.tag) {
        case 0: rx -= step; break;                  // ↑
        case 1: rx += step; break;                  // ↓
        case 2: ry += step; break;                  // ← (ry inverted)
        case 3: ry -= step; break;                  // →
        case 4: rx -= step; ry += step; break;      // ↖
        case 5: rx -= step; ry -= step; break;      // ↗
        case 6: rx += step; ry += step; break;      // ↙
        case 7: rx += step; ry -= step; break;      // ↘
    }

    rx = fmax(0.05, fmin(0.95, rx));
    ry = fmax(0.05, fmin(0.95, ry));
    BINFlashSavePrefs(@{ kBINFlashKeyRegionX: @(rx), kBINFlashKeyRegionY: @(ry) });
}

@end

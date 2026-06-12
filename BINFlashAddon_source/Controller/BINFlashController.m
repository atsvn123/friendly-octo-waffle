// BINFlashController.m
// Reconstructed from BINFlashController ObjC class methods:
//   -start            (0x947C) — 827 instructions — UI construction
//   -startWhenReady   (0xAB60)
//   -showPanel        (0xA808)
//   -tick             (0xAA30)
//   -moveView:withPan:(0xA960)
//   -handlePanelPan:  (0xA6A4)
//   -handleMiniPan:   (0xA504)

#import "BINFlashController.h"
#import "../Panel/BINFlashPanel.h"
#import "../Views/BINFlashOvalView.h"
#import "../Views/BINFlashPassThroughWindow.h"
#import "../Views/BINFlashRootController.h"
#import "../Bridge/BINFlashEffectBridge.h"

// Mini button geometry (from constant pool at 0xA524–0xA560)
// Frame: x = screenWidth - 68, y = 155, width = 54, height = 42
#define kMiniButtonRightMargin  68.0
#define kMiniButtonY            155.0
#define kMiniButtonWidth        54.0
#define kMiniButtonHeight       42.0
#define kMiniButtonCornerRadius 12.0

@implementation BINFlashController

// --- +[BINFlashController shared] (0xAD60) ---
+ (instancetype)shared {
    static BINFlashController *s_instance = nil;
    static dispatch_once_t s_once = 0;
    dispatch_once(&s_once, ^{
        s_instance = [[BINFlashController alloc] init];
    });
    return s_instance;
}

// --- -[BINFlashController startWhenReady] (0xAB60) ---
// Registers for UIApplicationDidFinishLaunchingNotification.
// On fire: calls -start on the main thread.
- (void)startWhenReady {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [self start];
    }];
}

// --- -[BINFlashController start] (0x947C) ---
- (void)start {
    // Guard: only build once
    if (self.window) return;

    CGRect screenBounds = [UIScreen mainScreen].bounds;

    // Find the active UIWindowScene (iOS 13+)
    UIWindowScene *targetScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (!targetScene)
                targetScene = ws;
            if (ws.activationState == UISceneActivationStateForegroundActive ||
                ws.activationState == UISceneActivationStateForegroundInactive) {
                targetScene = ws;
                break;
            }
        }
    }

    // Use scene's coordinate space if available (for correct sizing on multi-display)
    if (targetScene)
        screenBounds = targetScene.coordinateSpace.bounds;

    // --- BINFlashPassThroughWindow ---
    BINFlashPassThroughWindow *window = [[BINFlashPassThroughWindow alloc] initWithFrame:screenBounds];
    self.window = window;
    if (targetScene)
        window.windowScene = targetScene;
    window.windowLevel     = UIWindowLevelAlert + 1000.0;
    window.backgroundColor = [UIColor clearColor];

    // Root view controller (transparent, no custom behavior)
    BINFlashRootController *rootVC = [BINFlashRootController new];
    window.rootViewController = rootVC;
    rootVC.view.backgroundColor = [UIColor clearColor];

    [window setHidden:NO];

    // --- BINFlashOvalView (full-screen color picker, hidden until activated) ---
    BINFlashOvalView *oval = [[BINFlashOvalView alloc] initWithFrame:screenBounds];
    self.ovalView = oval;
    [oval setHidden:YES];
    [window addSubview:oval];

    // --- BINFlashPanel (settings panel, centered, initially hidden) ---
    CGFloat panelWidth = MIN(screenBounds.size.width - 20.0, 330.0);
    CGFloat panelX     = (screenBounds.size.width - panelWidth) * 0.5;
    // Height 560: margin(20)+Live(50)+Flash(50)+Speed(80)+Brightness(80)+Region(80)+ColorBar(44)+AimButtons(88)+HideReset(36)+margin(32)=560
    BINFlashPanel *panel = [[BINFlashPanel alloc] initWithFrame:CGRectMake(panelX, 90.0, panelWidth, 560)];
    self.panel = panel;
    self.panelLocked = NO;
    [panel setHidden:YES];

    // Panel hide handler: hides panel, shows mini button
    __unsafe_unretained BINFlashController *weakSelf = self;
    panel.hideHandler = ^{
        BINFlashController *c = weakSelf;
        if (!c) return;
        [c.panel setHidden:YES];
        [c.miniButton setHidden:NO];
    };

    [window addSubview:panel];

    // Panel pan gesture
    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePanelPan:)];
    panelPan.cancelsTouchesInView = NO;
    [panel addGestureRecognizer:panelPan];

    // --- Mini "BIN" button ---
    UIButton *mini = [UIButton buttonWithType:UIButtonTypeCustom];
    self.miniButton = mini;
    [mini setFrame:CGRectMake(screenBounds.size.width - kMiniButtonRightMargin,
                              kMiniButtonY,
                              kMiniButtonWidth,
                              kMiniButtonHeight)];
    mini.backgroundColor = [UIColor colorWithRed:0.38 green:0.9 blue:0.48 alpha:0.72];
    mini.layer.cornerRadius  = kMiniButtonCornerRadius;
    mini.layer.shadowColor   = [UIColor blackColor].CGColor;
    mini.layer.shadowOpacity = 0.5f;
    mini.layer.shadowRadius  = 8.0;
    [mini setTitle:@"BIN" forState:UIControlStateNormal];
    [mini setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    mini.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [mini addTarget:self action:@selector(showPanel) forControlEvents:UIControlEventTouchUpInside];
    [mini setHidden:NO];
    [window addSubview:mini];

    // Mini button pan gesture (for repositioning)
    UIPanGestureRecognizer *miniPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleMiniPan:)];
    miniPan.cancelsTouchesInView = NO;
    [mini addGestureRecognizer:miniPan];

    // --- 20Hz timer ---
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                      target:self
                                                    selector:@selector(tick)
                                                    userInfo:nil
                                                     repeats:YES];
    self.timer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

// --- -[BINFlashController showPanel] (0xA808) ---
- (void)showPanel {
    [self.panel reloadFromPrefs];
    [self.panel setHidden:NO];
    [self.miniButton setHidden:YES];
}

// --- -[BINFlashController tick] (0xAA30) ---
// Called 20x/sec. Drives the flash effect via BINFlashEffectBridge.
- (void)tick {
    [[BINFlashEffectBridge shared] tick];
}

// --- -[BINFlashController moveView:withPan:] (0xA960) ---
// Shared drag helper: moves a view with a pan gesture, clamped within screen.
- (void)moveView:(UIView *)view withPan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.window];
    [pan setTranslation:CGPointZero inView:self.window];

    CGRect bounds = self.window.bounds;
    CGRect frame  = view.frame;
    frame.origin.x = fmax(0, fmin(frame.origin.x + translation.x, CGRectGetWidth(bounds) - CGRectGetWidth(frame)));
    frame.origin.y = fmax(0, fmin(frame.origin.y + translation.y, CGRectGetHeight(bounds) - CGRectGetHeight(frame)));
    view.frame = frame;
}

// --- -[BINFlashController handlePanelPan:] (0xA6A4) ---
- (void)handlePanelPan:(UIPanGestureRecognizer *)pan {
    if (!self.panelLocked)
        [self moveView:self.panel withPan:pan];
}

// --- -[BINFlashController handleMiniPan:] (0xA504) ---
- (void)handleMiniPan:(UIPanGestureRecognizer *)pan {
    [self moveView:self.miniButton withPan:pan];
}

- (void)dealloc {
    [_timer invalidate];
    [_timer release];
    [_window release];
    [_panel release];
    [_ovalView release];
    [_miniButton release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

@end

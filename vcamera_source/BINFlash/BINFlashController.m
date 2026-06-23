// BINFlashController.m
// Reconstructed from BINFlashController ObjC class (0x947C–0xB07C)
// Updated for merged vcamera.dylib: all imports flat (same directory).

#import "BINFlashController.h"
#import "BINFlashPanel.h"
#import "BINFlashOvalView.h"
#import "BINFlashPassThroughWindow.h"
#import "BINFlashRootController.h"
#import "BINFlashEffectBridge.h"

#define kMiniButtonRightMargin  68.0
#define kMiniButtonY            155.0
#define kMiniButtonWidth        54.0
#define kMiniButtonHeight       42.0
#define kMiniButtonCornerRadius 12.0

@implementation BINFlashController

+ (instancetype)shared {
    static BINFlashController *s_instance = nil;
    static dispatch_once_t s_once = 0;
    dispatch_once(&s_once, ^{ s_instance = [[BINFlashController alloc] init]; });
    return s_instance;
}

- (void)startWhenReady {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { [self start]; }];
}

- (void)start {
    if (self.window) return;

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    UIWindowScene *targetScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (!targetScene) targetScene = ws;
            if (ws.activationState == UISceneActivationStateForegroundActive ||
                ws.activationState == UISceneActivationStateForegroundInactive) {
                targetScene = ws; break;
            }
        }
    }
    if (targetScene) screenBounds = targetScene.coordinateSpace.bounds;

    BINFlashPassThroughWindow *window = [[BINFlashPassThroughWindow alloc] initWithFrame:screenBounds];
    self.window = window;
    if (targetScene) window.windowScene = targetScene;
    window.windowLevel     = UIWindowLevelAlert + 1000.0;
    window.backgroundColor = [UIColor clearColor];

    BINFlashRootController *rootVC = [BINFlashRootController new];
    window.rootViewController = rootVC;
    rootVC.view.backgroundColor = [UIColor clearColor];
    [window setHidden:NO];

    BINFlashOvalView *oval = [[BINFlashOvalView alloc] initWithFrame:screenBounds];
    self.ovalView = oval;
    [oval setHidden:YES];
    [window addSubview:oval];

    CGFloat panelWidth = MIN(screenBounds.size.width - 20.0, 330.0);
    CGFloat panelX     = (screenBounds.size.width - panelWidth) * 0.5;
    BINFlashPanel *panel = [[BINFlashPanel alloc] initWithFrame:CGRectMake(panelX, 90.0, panelWidth, 560)];
    self.panel = panel;
    self.panelLocked = NO;
    [panel setHidden:YES];

    __unsafe_unretained BINFlashController *weakSelf = self;
    panel.hideHandler = ^{
        BINFlashController *c = weakSelf;
        if (!c) return;
        [c.panel setHidden:YES];
        [c.miniButton setHidden:NO];
    };
    [window addSubview:panel];

    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePanelPan:)];
    panelPan.cancelsTouchesInView = NO;
    [panel addGestureRecognizer:panelPan];

    UIButton *mini = [UIButton buttonWithType:UIButtonTypeCustom];
    self.miniButton = mini;
    [mini setFrame:CGRectMake(screenBounds.size.width - kMiniButtonRightMargin,
                              kMiniButtonY, kMiniButtonWidth, kMiniButtonHeight)];
    mini.backgroundColor    = [UIColor colorWithRed:0.38 green:0.9 blue:0.48 alpha:0.72];
    mini.layer.cornerRadius = kMiniButtonCornerRadius;
    mini.layer.shadowColor  = [UIColor blackColor].CGColor;
    mini.layer.shadowOpacity = 0.5f;
    mini.layer.shadowRadius  = 8.0;
    [mini setTitle:@"BIN" forState:UIControlStateNormal];
    [mini setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    mini.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [mini addTarget:self action:@selector(showPanel) forControlEvents:UIControlEventTouchUpInside];
    [mini setHidden:NO];
    [window addSubview:mini];

    UIPanGestureRecognizer *miniPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleMiniPan:)];
    miniPan.cancelsTouchesInView = NO;
    [mini addGestureRecognizer:miniPan];

    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                      target:self
                                                    selector:@selector(tick)
                                                    userInfo:nil
                                                     repeats:YES];
    self.timer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)showPanel {
    [self.panel reloadFromPrefs];
    [self.panel setHidden:NO];
    [self.miniButton setHidden:YES];
}

- (void)tick {
    [[BINFlashEffectBridge shared] tick];
}

- (void)moveView:(UIView *)view withPan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.window];
    [pan setTranslation:CGPointZero inView:self.window];
    CGRect bounds = self.window.bounds, frame = view.frame;
    frame.origin.x = fmax(0, fmin(frame.origin.x + translation.x, CGRectGetWidth(bounds) - CGRectGetWidth(frame)));
    frame.origin.y = fmax(0, fmin(frame.origin.y + translation.y, CGRectGetHeight(bounds) - CGRectGetHeight(frame)));
    view.frame = frame;
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)pan {
    if (!self.panelLocked) [self moveView:self.panel withPan:pan];
}

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

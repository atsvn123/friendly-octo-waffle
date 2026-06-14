// VCamMenuViewController.m
// Vietnamese white bottom-sheet menu — v2.86

#import "VCamMenuViewController.h"
#import "VCamColorPickerWindow.h"
#import "VCamManualPadWindow.h"
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"
#import "../BINFlash/BINFlashPrefs.h"
#import "../BINFlash/BINFlashColorBar.h"
#import <QuartzCore/QuartzCore.h>
#include <ifaddrs.h>
#include <arpa/inet.h>

static NSString * const kVcamMenuTopFraction = @"vcam.menu.topfraction";
static NSString * const kVcamMenuOpacity     = @"vcam.menu.opacity";

// ── Helpers ───────────────────────────────────────────────────────────────────
static UIColor *AccentColor(void) {
    // #D98CA8 (soft rose pink)
    return [UIColor colorWithRed:0.8510f green:0.5490f blue:0.6588f alpha:1.0f];
}
static UIColor *SectionBg(void) {
    return [UIColor colorWithWhite:0.96 alpha:1.0];
}
static UIColor *BorderColor(void) {
    return [UIColor colorWithWhite:0.85 alpha:1.0];
}

// ── Slider row ────────────────────────────────────────────────────────────────
@interface VCamSliderRow : UIView
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel  *valueLabel;
- (instancetype)initWithTitle:(NSString *)title min:(float)minV max:(float)maxV value:(float)val;
@end

@implementation VCamSliderRow

- (instancetype)initWithTitle:(NSString *)title min:(float)minV max:(float)maxV value:(float)val {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:13.0];
        _titleLabel.textColor = [UIColor darkGrayColor];
        [self addSubview:_titleLabel];

        _slider = [[UISlider alloc] init];
        _slider.minimumValue = minV;
        _slider.maximumValue = maxV;
        _slider.value        = val;
        _slider.tintColor = AccentColor();
        _slider.minimumTrackTintColor = AccentColor();
        [self addSubview:_slider];

        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightMedium];
        _valueLabel.textColor = [UIColor darkGrayColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_valueLabel];
    }
    return self;
}

- (void)dealloc {
    [_titleLabel release]; [_slider release]; [_valueLabel release];
    [super dealloc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    _titleLabel.frame = CGRectMake(0, 2, w - 50, 17);
    _valueLabel.frame = CGRectMake(w - 48, 2, 48, 17);
    _slider.frame     = CGRectMake(0, 21, w, 24);
}
@end

// ── Toggle row ────────────────────────────────────────────────────────────────
@interface VCamToggleRow : UIView
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) UISwitch *toggle;
- (instancetype)initWithTitle:(NSString *)title on:(BOOL)on;
@end

@implementation VCamToggleRow

- (instancetype)initWithTitle:(NSString *)title on:(BOOL)on {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor blackColor];
        [self addSubview:_titleLabel];

        _toggle = [[UISwitch alloc] init];
        _toggle.on = on;
        _toggle.onTintColor = AccentColor();
        [self addSubview:_toggle];
    }
    return self;
}

- (void)dealloc {
    [_titleLabel release]; [_toggle release];
    [super dealloc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    CGFloat w = self.bounds.size.width;
    _titleLabel.frame = CGRectMake(0, (h-22)/2, w - 62, 22);
    CGSize tsz = _toggle.intrinsicContentSize;
    _toggle.frame = CGRectMake(w - tsz.width, (h - tsz.height)/2, tsz.width, tsz.height);
}
@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface VCamMenuViewController () <UITextFieldDelegate> {
    UIView       *_overlayView;
    UIView       *_cardView;
    UIScrollView *_scrollView;
    UIView       *_contentView;

    // Drag-handle overlay (fixed on card, above scrollView)
    UIView       *_handleView;

    // Remembered card position (fraction of screen height where card top sits)
    CGFloat       _savedCardTopFraction;

    UILabel      *_versionLabel;
    UITextField  *_rtmpField;
    UISwitch     *_liveSwitch;
    UILabel      *_liveStatusLabel;
    UISwitch     *_flashSwitch;
    UIView       *_flashPanel;
    CGFloat       _flashPanelFullH;

    UIView          *_colorSwatch;
    VCamToggleRow   *_autoColorRow;
    VCamToggleRow   *_staticFlashRow;
    VCamSliderRow   *_speedRow;
    VCamSliderRow   *_brightnessRow;
    VCamSliderRow   *_regionRow;
    UISegmentedControl *_positionSeg;
    BINFlashColorBar *_colorBar;

    // Menu opacity slider ("Độ mờ menu")
    VCamSliderRow   *_opacityRow;

    // RTMP rotation selector
    UISegmentedControl *_rotationSeg;

    // Debug panel (collapsible, shows g_vcamDiag stream)
    UIView       *_debugHeaderView;
    UIView       *_debugPanel;
    UITextView   *_debugTextView;
    UIButton     *_debugToggleBtn;
    BOOL          _debugPanelVisible;

    NSTimer  *_refreshTimer;
    BOOL     _flashPanelVisible;
}
@end

@implementation VCamMenuViewController

// ── Lifecycle ─────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    [self buildOverlay];
    [self buildCard];        // loads _savedCardTopFraction, builds handle + scrollView
    [self buildContent];     // populates scrollView content
    [self refreshFromPrefs];

    // Float window is always on — user no longer has a toggle for it.
    [[VCamLiveManager sharedInstance] setFloatWindow:YES];

    _refreshTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(timerTick)
                                                     userInfo:nil
                                                      repeats:YES] retain];

    // Auto color is now driven by vcamUpdateFloatButton() — no picker window to show.
    NSDictionary *fp0 = BINFlashLoadPrefs();
    if (BINFlashBoolForKey(fp0, kBINFlashKeyManualRegion, kBINFlashDefaultManualRegion)) {
        [[VCamManualPadWindow sharedWindow] showPad];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Slide card off-screen downward before animation starts.
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    _cardView.frame = CGRectMake(0, sh, sw, _cardView.frame.size.height);
    _overlayView.alpha = 0;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat cardTopY = [self clampedCardTopY:sh * _savedCardTopFraction screenH:sh];
    CGFloat cardH    = sh - cardTopY;
    [UIView animateWithDuration:0.38 delay:0
         usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        _cardView.frame = CGRectMake(0, cardTopY, sw, cardH);
        _overlayView.alpha = 1.0;
    } completion:nil];
}

- (void)dealloc {
    [_refreshTimer invalidate];
    [_refreshTimer release];
    [_autoColorRow release];
    [_staticFlashRow release];
    [_speedRow release];
    [_brightnessRow release];
    [_regionRow release];
    [_positionSeg release];
    [_colorBar release];
    [_opacityRow release];
    [_rotationSeg release];
    [_debugHeaderView release];
    [_debugPanel release];
    [_debugTextView release];
    [_debugToggleBtn release];
    [super dealloc];
}

- (void)showDiag:(NSString *)msg {
    if (!_debugPanelVisible || !_debugTextView) return;
    NSString *text = msg ? msg : @"";
    _debugTextView.text = text;
    if (text.length > 0)
        [_debugTextView scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
}

- (void)animateDismissWithCompletion:(void(^)(void))completion {
    [_refreshTimer invalidate];
    [_refreshTimer release];
    _refreshTimer = nil;
    // (picker is float button — no draggable flag needed)
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        _cardView.frame = CGRectMake(0, sh, sw, _cardView.frame.size.height);
        _overlayView.alpha = 0;
    } completion:^(BOOL f) {
        if (completion) completion();
    }];
}

// ── Build overlay ─────────────────────────────────────────────────────────────

- (void)buildOverlay {
    _overlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    _overlayView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    _overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(hideTapped:)];
    [_overlayView addGestureRecognizer:tap];
    [tap release];
    [self.view addSubview:_overlayView];
    [_overlayView release];
}

// ── Build card ────────────────────────────────────────────────────────────────

- (void)buildCard {
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;

    // Load saved top fraction. Default 0.17 → card fills bottom 83% of screen.
    double savedFraction = [[NSUserDefaults standardUserDefaults] doubleForKey:kVcamMenuTopFraction];
    if (savedFraction < 0.05 || savedFraction > 0.92) savedFraction = 0.17;
    _savedCardTopFraction = (CGFloat)savedFraction;

    CGFloat cardTopY = [self clampedCardTopY:sh * _savedCardTopFraction screenH:sh];
    CGFloat cardH    = sh - cardTopY;

    _cardView = [[UIView alloc] initWithFrame:CGRectMake(0, cardTopY, sw, cardH)];
    _cardView.backgroundColor = [UIColor whiteColor];
    _cardView.layer.cornerRadius  = 20.0;
    _cardView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _cardView.layer.masksToBounds = YES;
    [self.view addSubview:_cardView];
    [_cardView release];

    // Restore saved opacity (applied to card view).
    double savedOpacity = [[NSUserDefaults standardUserDefaults] doubleForKey:kVcamMenuOpacity];
    if (savedOpacity < 10.0 || savedOpacity > 100.0) savedOpacity = 100.0;
    _cardView.alpha = (CGFloat)(savedOpacity / 100.0);

    // ── Drag handle overlay (sits above scrollView, fixed on card) ──
    // 44px tall, transparent background — captures pan gestures for Y repositioning.
    _handleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sw, 44)];
    _handleView.backgroundColor = [UIColor clearColor];

    UIView *handleBar = [[UIView alloc] initWithFrame:CGRectMake((sw-40)/2, 12, 40, 4)];
    handleBar.backgroundColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    handleBar.layer.cornerRadius = 2.0;
    [_handleView addSubview:handleBar];
    [handleBar release];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(handlePan:)];
    [_handleView addGestureRecognizer:pan];
    [pan release];

    // ── ScrollView fills the full card; handleView layered on top ──
    _scrollView = [[UIScrollView alloc] initWithFrame:_cardView.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.showsVerticalScrollIndicator = YES;
    _scrollView.alwaysBounceVertical = YES;
    // Leave 44px top inset so content isn't hidden under the handleView at rest.
    _scrollView.contentInset = UIEdgeInsetsMake(44, 0, 0, 0);
    [_cardView addSubview:_scrollView];
    [_scrollView release];

    _contentView = [[UIView alloc] initWithFrame:_scrollView.bounds];
    _contentView.backgroundColor = [UIColor whiteColor];
    [_scrollView addSubview:_contentView];
    [_contentView release];

    // Add handleView on top of scrollView.
    [_cardView addSubview:_handleView];
    [_handleView release];
}

// ── Drag handle pan gesture ───────────────────────────────────────────────────

- (CGFloat)clampedCardTopY:(CGFloat)y screenH:(CGFloat)sh {
    // Allow card to be dragged anywhere from 60px below top to leaving 100px visible.
    return MAX(60.0, MIN(sh - 100.0, y));
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat translation = [pan translationInView:self.view].y;

    static CGFloat s_panStartY = 0;
    if (pan.state == UIGestureRecognizerStateBegan) {
        s_panStartY = _cardView.frame.origin.y;
    }

    CGFloat newTopY = [self clampedCardTopY:s_panStartY + translation screenH:sh];
    CGFloat newH    = sh - newTopY;
    _cardView.frame = CGRectMake(0, newTopY, sw, newH);

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        _savedCardTopFraction = newTopY / sh;
        [[NSUserDefaults standardUserDefaults] setDouble:(double)_savedCardTopFraction
                                                  forKey:kVcamMenuTopFraction];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

// ── Build content ─────────────────────────────────────────────────────────────

- (void)buildContent {
    CGFloat sw  = _cardView.frame.size.width;
    CGFloat pad = 16.0;
    CGFloat cw  = sw - pad * 2;
    CGFloat y   = 4.0;

    // Version label (visible through transparent handleView above it)
    _versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, cw, 15)];
    _versionLabel.text = @"v2.154-VCAM";
    _versionLabel.font = [UIFont systemFontOfSize:11.0];
    _versionLabel.textColor = [UIColor lightGrayColor];
    _versionLabel.textAlignment = NSTextAlignmentCenter;
    [_contentView addSubview:_versionLabel];
    [_versionLabel release];
    y += 22.0;

    // RTMP URL
    UILabel *rtmpLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, cw, 13)];
    rtmpLabel.text = @"RTMP URL";
    rtmpLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    rtmpLabel.textColor = [UIColor lightGrayColor];
    [_contentView addSubview:rtmpLabel];
    [rtmpLabel release];
    y += 15.0;

    _rtmpField = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, cw, 40)];
    _rtmpField.backgroundColor    = SectionBg();
    _rtmpField.layer.cornerRadius = 10.0;
    _rtmpField.layer.borderWidth  = 1.0;
    _rtmpField.layer.borderColor  = BorderColor().CGColor;
    _rtmpField.font = [UIFont systemFontOfSize:12.5];
    _rtmpField.textColor = [UIColor darkGrayColor];
    _rtmpField.placeholder = @"rtmp://127.0.0.1:1935/live";
    UIView *lpad = [[UIView alloc] initWithFrame:CGRectMake(0,0,10,40)];
    _rtmpField.leftView = lpad;
    [lpad release];
    _rtmpField.leftViewMode = UITextFieldViewModeAlways;
    _rtmpField.returnKeyType = UIReturnKeyDone;
    _rtmpField.autocorrectionType = UITextAutocorrectionTypeNo;
    _rtmpField.delegate = self;
    [_contentView addSubview:_rtmpField];
    y += 48.0;

    // LIVE section (includes rotation control)
    UIView *liveSec = [self sectionBox:CGRectMake(pad, y, cw, 128)];
    [_contentView addSubview:liveSec];

    UILabel *liveDot = [self dotLabel:@"LIVE" dotColor:[UIColor systemGreenColor]];
    liveDot.frame = CGRectMake(12, 12, 160, 22);
    [liveSec addSubview:liveDot];

    _liveSwitch = [[UISwitch alloc] init];
    _liveSwitch.onTintColor = [UIColor systemGreenColor];
    NSDictionary *liveFp = BINFlashLoadPrefs();
    BOOL isLiveOn = BINFlashBoolForKey(liveFp, kBINFlashKeyLive, NO);
    _liveSwitch.on = isLiveOn;
    CGSize lsz = _liveSwitch.intrinsicContentSize;
    _liveSwitch.frame = CGRectMake(cw - lsz.width - 4, (44 - lsz.height)/2 + 4,
                                   lsz.width, lsz.height);
    [_liveSwitch addTarget:self action:@selector(liveToggled:)
          forControlEvents:UIControlEventValueChanged];
    [liveSec addSubview:_liveSwitch];
    [_liveSwitch release];

    _liveStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 40, cw - 24, 18)];
    _liveStatusLabel.font = [UIFont systemFontOfSize:11.5];
    _liveStatusLabel.textColor = [UIColor grayColor];
    [liveSec addSubview:_liveStatusLabel];
    [_liveStatusLabel release];

    // Hairline separator
    UIView *liveSep = [[UIView alloc] initWithFrame:CGRectMake(12, 62, cw - 24, 0.5)];
    liveSep.backgroundColor = BorderColor();
    [liveSec addSubview:liveSep];
    [liveSep release];

    // "Xoay RTMP" label + rotation segmented control — enabled only when LIVE is on
    UILabel *rotInLive = [[UILabel alloc] initWithFrame:CGRectMake(12, 66, 90, 16)];
    rotInLive.text = @"Xoay RTMP";
    rotInLive.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    rotInLive.textColor = [UIColor lightGrayColor];
    [liveSec addSubview:rotInLive];
    [rotInLive release];

    NSInteger savedRotIdx = [[NSUserDefaults standardUserDefaults]
                              integerForKey:@"vcam.rtmp.rotation.idx"];
    if (savedRotIdx < 0 || savedRotIdx > 4) savedRotIdx = 0;

    _rotationSeg = [[UISegmentedControl alloc]
                    initWithItems:@[@"Auto", @"0°", @"90°", @"180°", @"270°"]];
    _rotationSeg.frame = CGRectMake(8, 86, cw - 16, 32);
    _rotationSeg.selectedSegmentIndex = savedRotIdx;
    _rotationSeg.enabled = isLiveOn;
    _rotationSeg.alpha = isLiveOn ? 1.0 : 0.4;
    _rotationSeg.tintColor = AccentColor();
    if (@available(iOS 13.0, *)) {
        _rotationSeg.selectedSegmentTintColor = AccentColor();
        [_rotationSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor darkGrayColor]}
                                    forState:UIControlStateNormal];
        [_rotationSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                                    forState:UIControlStateSelected];
    }
    [_rotationSeg addTarget:self action:@selector(rotationSegChanged:)
           forControlEvents:UIControlEventValueChanged];
    [liveSec addSubview:_rotationSeg];

    y += 136.0;

    if (isLiveOn) {
        _rtmpField.text = [NSString stringWithFormat:@"rtmp://%@:1935/live", [self deviceWifiIP]];
        _rtmpField.enabled = NO;
        _rtmpField.alpha = 0.7;
    }

    // FLASH section header
    UIView *flashSec = [self sectionBox:CGRectMake(pad, y, cw, 56)];
    [_contentView addSubview:flashSec];

    UILabel *flashDot = [self dotLabel:@"FLASH" dotColor:AccentColor()];
    flashDot.frame = CGRectMake(12, 16, 160, 22);
    [flashSec addSubview:flashDot];

    NSDictionary *fp = BINFlashLoadPrefs();
    BOOL flashOn = BINFlashBoolForKey(fp, kBINFlashKeyFlash, kBINFlashDefaultFlash);
    _flashSwitch = [[UISwitch alloc] init];
    _flashSwitch.onTintColor = AccentColor();
    _flashSwitch.on = flashOn;
    CGSize fsz = _flashSwitch.intrinsicContentSize;
    _flashSwitch.frame = CGRectMake(cw - fsz.width - 4, (56 - fsz.height)/2,
                                    fsz.width, fsz.height);
    [_flashSwitch addTarget:self action:@selector(flashToggled:)
           forControlEvents:UIControlEventValueChanged];
    [flashSec addSubview:_flashSwitch];
    [_flashSwitch release];

    y += 64.0;

    // Flash panel (expandable)
    _flashPanel = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 0)];
    _flashPanel.backgroundColor = [UIColor clearColor];
    _flashPanel.clipsToBounds = YES;
    [_contentView addSubview:_flashPanel];
    [_flashPanel release];
    _flashPanelVisible = flashOn;
    _flashPanelFullH = [self buildFlashPanel:fp contentWidth:cw];
    _flashPanel.frame = CGRectMake(pad, y, cw, flashOn ? _flashPanelFullH : 0);

    y += (flashOn ? _flashPanelFullH : 0) + 8.0;

    // ── "Độ mờ menu" opacity slider (replaces Ẩn menu button) ──
    double savedOpacity = [[NSUserDefaults standardUserDefaults] doubleForKey:kVcamMenuOpacity];
    if (savedOpacity < 10.0 || savedOpacity > 100.0) savedOpacity = 100.0;

    _opacityRow = [[VCamSliderRow alloc] initWithTitle:@"Độ mờ menu" min:10.0 max:100.0
                                                  value:(float)savedOpacity];
    _opacityRow.frame = CGRectMake(pad, y, cw, 50);
    _opacityRow.valueLabel.text = [NSString stringWithFormat:@"%.0f%%", savedOpacity];
    [_opacityRow.slider addTarget:self action:@selector(opacityChanged:)
                 forControlEvents:UIControlEventValueChanged];
    [_contentView addSubview:_opacityRow];

    y += 58.0;   // opacity row + gap

    // ── DEBUG section header (collapsible) ──────────────────────────────────────
    _debugHeaderView = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 44)];
    _debugHeaderView.backgroundColor = SectionBg();
    _debugHeaderView.layer.cornerRadius = 12.0;
    _debugHeaderView.layer.borderWidth  = 1.0;
    _debugHeaderView.layer.borderColor  = BorderColor().CGColor;

    UILabel *debugLbl = [self dotLabel:@"DEBUG"
                             dotColor:[UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0]];
    debugLbl.frame = CGRectMake(12, 11, 130, 22);
    [_debugHeaderView addSubview:debugLbl];

    _debugToggleBtn = [[UIButton buttonWithType:UIButtonTypeSystem] retain];
    _debugToggleBtn.frame = CGRectMake(cw - 66, 10, 62, 24);
    [_debugToggleBtn setTitle:@"▼ Hiện" forState:UIControlStateNormal];
    _debugToggleBtn.titleLabel.font = [UIFont systemFontOfSize:11.0];
    [_debugToggleBtn addTarget:self action:@selector(toggleDebugPanel)
              forControlEvents:UIControlEventTouchUpInside];
    [_debugHeaderView addSubview:_debugToggleBtn];

    UITapGestureRecognizer *debugTap = [[UITapGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(toggleDebugPanel)];
    [_debugHeaderView addGestureRecognizer:debugTap];
    [debugTap release];

    [_contentView addSubview:_debugHeaderView];
    y += 52.0;

    // ── DEBUG text panel (dark, monospaced — collapsed by default) ───────────────
    _debugPanel = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 0)];
    _debugPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    _debugPanel.layer.cornerRadius = 8.0;
    _debugPanel.clipsToBounds = YES;
    [_contentView addSubview:_debugPanel];

    _debugTextView = [[UITextView alloc] initWithFrame:CGRectMake(4, 4, cw - 8, 192)];
    _debugTextView.backgroundColor = [UIColor clearColor];
    UIFont *monoFont = [UIFont fontWithName:@"Courier" size:9.5];
    _debugTextView.font = monoFont ? monoFont : [UIFont systemFontOfSize:9.5];
    _debugTextView.textColor = [UIColor colorWithRed:0.25 green:1.0 blue:0.45 alpha:1.0];
    _debugTextView.editable = NO;
    _debugTextView.selectable = NO;
    _debugTextView.scrollEnabled = YES;
    _debugTextView.showsVerticalScrollIndicator = YES;
    _debugTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _debugTextView.text = @"(waiting for data…)";
    [_debugPanel addSubview:_debugTextView];

    // y stays at collapsed height (0); bottom padding
    y += 20.0;
    _contentView.frame = CGRectMake(0, 0, sw, y);
    _scrollView.contentSize = CGSizeMake(sw, y);
}

// ── Build flash panel, returns total height ───────────────────────────────────

- (CGFloat)buildFlashPanel:(NSDictionary *)fp contentWidth:(CGFloat)cw {
    CGFloat y = 6.0;

    // Color swatch row
    UIView *colorRow = [[UIView alloc] initWithFrame:CGRectMake(0, y, cw, 56)];
    colorRow.backgroundColor = SectionBg();
    colorRow.layer.cornerRadius = 10.0;
    colorRow.layer.borderWidth  = 1.0;
    colorRow.layer.borderColor  = BorderColor().CGColor;

    _colorSwatch = [[UIView alloc] initWithFrame:CGRectMake(12, 12, 32, 32)];
    _colorSwatch.layer.cornerRadius = 16.0;
    _colorSwatch.layer.borderWidth  = 2.0;
    _colorSwatch.layer.borderColor  = [UIColor whiteColor].CGColor;
    [colorRow addSubview:_colorSwatch];
    [_colorSwatch release];

    UILabel *colorHint = [[UILabel alloc] initWithFrame:CGRectMake(54, 17, 120, 20)];
    colorHint.text = @"Màu flash hiện tại";
    colorHint.font = [UIFont systemFontOfSize:13.0];
    colorHint.textColor = [UIColor darkGrayColor];
    [colorRow addSubview:colorHint];
    [colorHint release];

    [_flashPanel addSubview:colorRow];
    [colorRow release];
    y += 64.0;

    // Auto color pick
    BOOL autoOn = BINFlashBoolForKey(fp, kBINFlashKeyAutoColor, kBINFlashDefaultAutoColor);
    _autoColorRow = [[VCamToggleRow alloc] initWithTitle:@"Tự động chọn màu" on:autoOn];
    _autoColorRow.frame = CGRectMake(0, y, cw, 44);
    [_autoColorRow.toggle addTarget:self action:@selector(autoColorToggled:)
                   forControlEvents:UIControlEventValueChanged];
    [_flashPanel addSubview:_autoColorRow];
    y += 50.0;

    // Static flash (no strobe) toggle — disabled while auto color is active.
    BOOL staticOn = BINFlashBoolForKey(fp, kBINFlashKeyStaticFlash, kBINFlashDefaultStaticFlash);
    _staticFlashRow = [[VCamToggleRow alloc] initWithTitle:@"Ánh sáng tĩnh (tắt nhấp nháy)" on:staticOn];
    _staticFlashRow.frame = CGRectMake(0, y, cw, 44);
    [_staticFlashRow.toggle addTarget:self action:@selector(staticFlashToggled:)
                    forControlEvents:UIControlEventValueChanged];
    if (autoOn) {
        _staticFlashRow.toggle.enabled = NO;
        _staticFlashRow.alpha = 0.4;
    }
    [_flashPanel addSubview:_staticFlashRow];
    y += 50.0;

    // Separator
    [_flashPanel addSubview:[self separator:CGRectMake(0, y, cw, 1)]];
    y += 8.0;

    // Speed slider
    double spd = BINFlashDoubleForKey(fp, kBINFlashKeySpeed, kBINFlashDefaultSpeed);
    _speedRow = [[VCamSliderRow alloc] initWithTitle:@"Tốc độ" min:0.5 max:30.0 value:(float)spd];
    _speedRow.frame = CGRectMake(0, y, cw, 50);
    _speedRow.valueLabel.text = [NSString stringWithFormat:@"%.1f", spd];
    [_speedRow.slider addTarget:self action:@selector(speedChanged:)
               forControlEvents:UIControlEventValueChanged];
    [_flashPanel addSubview:_speedRow];
    y += 56.0;

    // Brightness slider
    double bri = BINFlashDoubleForKey(fp, kBINFlashKeyBrightness, kBINFlashDefaultBrightness);
    _brightnessRow = [[VCamSliderRow alloc] initWithTitle:@"Độ sáng" min:0 max:100.0 value:(float)bri];
    _brightnessRow.frame = CGRectMake(0, y, cw, 50);
    _brightnessRow.valueLabel.text = [NSString stringWithFormat:@"%.0f", bri];
    [_brightnessRow.slider addTarget:self action:@selector(brightnessChanged:)
                   forControlEvents:UIControlEventValueChanged];
    [_flashPanel addSubview:_brightnessRow];
    y += 56.0;

    // Region (oval size) slider
    double reg = BINFlashDoubleForKey(fp, kBINFlashKeyRegion, kBINFlashDefaultRegion);
    _regionRow = [[VCamSliderRow alloc] initWithTitle:@"Kích thước vùng" min:0 max:100.0 value:(float)reg];
    _regionRow.frame = CGRectMake(0, y, cw, 50);
    _regionRow.valueLabel.text = [NSString stringWithFormat:@"%.0f", reg];
    [_regionRow.slider addTarget:self action:@selector(regionChanged:)
                forControlEvents:UIControlEventValueChanged];
    [_flashPanel addSubview:_regionRow];
    y += 60.0;

    // Position mode label
    UILabel *posLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, y, cw, 13)];
    posLabel.text = @"CHẾ ĐỘ VỊ TRÍ";
    posLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    posLabel.textColor = [UIColor lightGrayColor];
    [_flashPanel addSubview:posLabel];
    [posLabel release];
    y += 15.0;

    // Position mode segmented control
    BOOL manualOn = BINFlashBoolForKey(fp, kBINFlashKeyManualRegion, kBINFlashDefaultManualRegion);
    _positionSeg = [[UISegmentedControl alloc] initWithItems:@[@"Bộ lọc (Face)", @"Thủ công"]];
    _positionSeg.selectedSegmentIndex = manualOn ? 1 : 0;
    _positionSeg.frame = CGRectMake(0, y, cw, 36);
    [_positionSeg addTarget:self action:@selector(positionSegChanged:)
           forControlEvents:UIControlEventValueChanged];
    [_flashPanel addSubview:_positionSeg];
    y += 44.0 + 4.0;

    // Hue color bar
    UILabel *hueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, y, 50, 14)];
    hueLabel.text = @"MÀU SẮC";
    hueLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    hueLabel.textColor = [UIColor lightGrayColor];
    [_flashPanel addSubview:hueLabel];
    [hueLabel release];
    y += 16.0;

    double hue = BINFlashDoubleForKey(fp, kBINFlashKeyHue, kBINFlashDefaultHue);
    _colorBar = [[BINFlashColorBar alloc] initWithFrame:CGRectMake(0, y, cw, 36)];
    _colorBar.hue = (CGFloat)hue;
    [_colorBar addTarget:self action:@selector(colorBarChanged:)
        forControlEvents:UIControlEventValueChanged];
    [_flashPanel addSubview:_colorBar];
    y += 44.0;

    y += 4.0; // bottom padding

    // Apply disabled state for sub-options if flash is currently off.
    [self updateFlashSubOptionState];

    return y;
}

// ── Helper: section box ───────────────────────────────────────────────────────

- (UIView *)sectionBox:(CGRect)frame {
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor    = SectionBg();
    v.layer.cornerRadius = 12.0;
    v.layer.borderWidth  = 1.0;
    v.layer.borderColor  = BorderColor().CGColor;
    return [v autorelease];
}

- (UIView *)separator:(CGRect)frame {
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = BorderColor();
    return [v autorelease];
}

- (UILabel *)dotLabel:(NSString *)text dotColor:(UIColor *)color {
    UILabel *lbl = [[[UILabel alloc] init] autorelease];
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc]
        initWithString:@"● " attributes:@{
            NSForegroundColorAttributeName: color,
            NSFontAttributeName: [UIFont systemFontOfSize:12.0]
        }];
    [as appendAttributedString:[[[NSAttributedString alloc]
        initWithString:text attributes:@{
            NSForegroundColorAttributeName: [UIColor blackColor],
            NSFontAttributeName: [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
        }] autorelease]];
    lbl.attributedText = as;
    [as release];
    return lbl;
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (NSString *)deviceWifiIP {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return @"127.0.0.1";
    NSString *ip = @"127.0.0.1";
    for (struct ifaddrs *ifa = interfaces; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(ifa->ifa_name, "en0") != 0) continue;
        char host[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, host, sizeof(host));
        ip = [NSString stringWithUTF8String:host];
        break;
    }
    freeifaddrs(interfaces);
    return ip;
}

- (void)liveToggled:(UISwitch *)sw {
    int32_t code = sw.on ? 1000 : 1001;
    if (sw.on && _rotationSeg) {
        // Resend current rotation before enabling LIVE.
        static const int32_t kAngles[] = {-1, 0, 90, 180, 270};
        NSInteger idx = _rotationSeg.selectedSegmentIndex;
        if (idx >= 0 && idx <= 4) {
            int32_t rotBuf[2] = {1019, kAngles[idx]};
            [[VCamBridge sharedInstance] send:[NSData dataWithBytes:rotBuf length:8]];
        }
    }
    [[VCamBridge sharedInstance] send:[self packetCode:code]];
    BINFlashSavePrefs(@{ kBINFlashKeyLive: @(sw.on) });
    // Enable rotation control only while LIVE is on.
    if (_rotationSeg) {
        _rotationSeg.enabled = sw.on;
        _rotationSeg.alpha   = sw.on ? 1.0 : 0.4;
    }
    if (sw.on) {
        NSString *ip = [self deviceWifiIP];
        _rtmpField.text = [NSString stringWithFormat:@"rtmp://%@:1935/live", ip];
        _rtmpField.enabled = NO;
        _rtmpField.alpha = 0.7;
    } else {
        _rtmpField.text = @"";
        _rtmpField.enabled = YES;
        _rtmpField.alpha = 1.0;
    }
    [self updateLiveStatus];
}

- (void)flashToggled:(UISwitch *)sw {
    BINFlashSavePrefs(@{ kBINFlashKeyFlash: @(sw.on) });
    [self updateFlashSubOptionState];
    [self setFlashPanelVisible:sw.on animated:YES];
}

// When flash is OFF: disable and grey auto-color and static-flash toggles.
// When flash is ON: restore to full interaction.
- (void)updateFlashSubOptionState {
    BOOL on = _flashSwitch.on;
    BOOL autoColor = _autoColorRow ? _autoColorRow.toggle.on : NO;
    if (_autoColorRow) {
        _autoColorRow.alpha = on ? 1.0 : 0.4;
        _autoColorRow.toggle.enabled = on;
    }
    if (_staticFlashRow) {
        // Disabled when flash is off OR when auto color is on (auto color locks it ON).
        BOOL canEdit = on && !autoColor;
        _staticFlashRow.alpha = canEdit ? 1.0 : 0.4;
        _staticFlashRow.toggle.enabled = canEdit;
    }
}

- (void)autoColorToggled:(UISwitch *)sw {
    if (sw.on) {
        // Auto color forces static flash ON (constant light, no strobing).
        // Static flash row is disabled until auto color is turned off.
        BINFlashSavePrefs(@{ kBINFlashKeyAutoColor: @(YES),
                             kBINFlashKeyStaticFlash: @(YES) });
        _staticFlashRow.toggle.on = YES;
        _staticFlashRow.toggle.enabled = NO;
        _staticFlashRow.alpha = 0.4;
    } else {
        BINFlashSavePrefs(@{ kBINFlashKeyAutoColor: @(NO) });
        _staticFlashRow.toggle.enabled = YES;
        _staticFlashRow.alpha = 1.0;
    }
}

- (void)staticFlashToggled:(UISwitch *)sw {
    BINFlashSavePrefs(@{ kBINFlashKeyStaticFlash: @(sw.on) });
}

- (void)speedChanged:(UISlider *)sl {
    _speedRow.valueLabel.text = [NSString stringWithFormat:@"%.1f", sl.value];
    BINFlashSavePrefs(@{ kBINFlashKeySpeed: @((double)sl.value) });
}

- (void)brightnessChanged:(UISlider *)sl {
    _brightnessRow.valueLabel.text = [NSString stringWithFormat:@"%.0f", sl.value];
    BINFlashSavePrefs(@{ kBINFlashKeyBrightness: @((double)sl.value) });
}

- (void)regionChanged:(UISlider *)sl {
    _regionRow.valueLabel.text = [NSString stringWithFormat:@"%.0f", sl.value];
    BINFlashSavePrefs(@{ kBINFlashKeyRegion: @((double)sl.value) });
}

- (void)colorBarChanged:(BINFlashColorBar *)bar {
    BINFlashSavePrefs(@{ kBINFlashKeyHue: @((double)bar.hue) });
    [self updateColorSwatch];
}

- (void)positionSegChanged:(UISegmentedControl *)seg {
    BOOL manual = (seg.selectedSegmentIndex == 1);
    BINFlashSavePrefs(@{ kBINFlashKeyManualRegion: @(manual) });
    if (manual) [[VCamManualPadWindow sharedWindow] showPad];
    else        [[VCamManualPadWindow sharedWindow] hidePad];
}

- (void)opacityChanged:(UISlider *)sl {
    CGFloat alpha = sl.value / 100.0;
    _cardView.alpha = alpha;
    _opacityRow.valueLabel.text = [NSString stringWithFormat:@"%.0f%%", sl.value];
    [[NSUserDefaults standardUserDefaults] setDouble:(double)sl.value forKey:kVcamMenuOpacity];
}

- (void)rotationSegChanged:(UISegmentedControl *)seg {
    // Map segment index → rotation angle: 0=Auto(-1), 1=0°, 2=90°, 3=180°, 4=270°
    static const int32_t kAngles[] = {-1, 0, 90, 180, 270};
    NSInteger idx = seg.selectedSegmentIndex;
    if (idx < 0 || idx > 4) return;
    int32_t angle = kAngles[idx];

    [[NSUserDefaults standardUserDefaults] setInteger:idx forKey:@"vcam.rtmp.rotation.idx"];

    // Send code 1019 to mediaserverd immediately (works even when LIVE is off).
    int32_t buf[2] = {1019, angle};
    [[VCamBridge sharedInstance] send:[NSData dataWithBytes:buf length:8]];
}

- (void)toggleDebugPanel {
    _debugPanelVisible = !_debugPanelVisible;
    CGFloat targetH = _debugPanelVisible ? 200.0 : 0.0;
    [UIView animateWithDuration:0.22 animations:^{
        CGRect pf = _debugPanel.frame;
        pf.size.height = targetH;
        _debugPanel.frame = pf;
        [self updateContentSize];
    }];
    NSString *title = _debugPanelVisible ? @"▲ Ẩn" : @"▼ Hiện";
    [_debugToggleBtn setTitle:title forState:UIControlStateNormal];
    // Populate immediately when opening
    if (_debugPanelVisible && _debugTextView) {
        NSString *diag = g_vcamDiag ? g_vcamDiag : @"(no data)";
        _debugTextView.text = diag;
    }
}

- (void)hideTapped:(UITapGestureRecognizer *)tap {
    // Guard: only dismiss when tap is outside the card.
    // On iOS 16, system gesture handling can route orphaned touches to the overlay
    // even when the original touch landed on the card — causing accidental dismissal.
    CGPoint pt = [tap locationInView:self.view];
    if (_cardView && CGRectContainsPoint(_cardView.frame, pt)) return;
    [[VCamBridge sharedInstance] dismiss];
}

// ── Flash panel show/hide ─────────────────────────────────────────────────────

- (void)setFlashPanelVisible:(BOOL)visible animated:(BOOL)animated {
    _flashPanelVisible = visible;
    void (^changes)(void) = ^{
        CGRect f = _flashPanel.frame;
        f.size.height = visible ? _flashPanelFullH : 0;
        _flashPanel.frame = f;
        [self recomputeOpacityRowY];
    };
    if (animated) {
        [UIView animateWithDuration:0.28 animations:changes
                         completion:^(BOOL fin){ [self updateContentSize]; }];
    } else {
        changes();
        [self updateContentSize];
    }
}

- (void)recomputeOpacityRowY {
    if (!_opacityRow) return;
    CGFloat flashBottom = CGRectGetMaxY(_flashPanel.frame);
    CGRect rf = _opacityRow.frame;
    rf.origin.y = flashBottom + 8.0;
    _opacityRow.frame = rf;
    [self recomputeDebugY];
}

- (void)recomputeDebugY {
    if (!_debugHeaderView || !_debugPanel) return;
    CGFloat opBottom = CGRectGetMaxY(_opacityRow.frame) + 8.0;
    CGRect hf = _debugHeaderView.frame;
    hf.origin.y = opBottom;
    _debugHeaderView.frame = hf;
    CGRect pf = _debugPanel.frame;
    pf.origin.y = CGRectGetMaxY(_debugHeaderView.frame) + 4.0;
    _debugPanel.frame = pf;
}

- (void)updateContentSize {
    CGFloat bottom;
    if (_debugPanel) {
        bottom = CGRectGetMaxY(_debugPanel.frame) + 20.0;
    } else if (_opacityRow) {
        bottom = CGRectGetMaxY(_opacityRow.frame) + 28.0;
    } else return;
    _contentView.frame = CGRectMake(0, 0, _contentView.frame.size.width, bottom);
    _scrollView.contentSize = CGSizeMake(_contentView.frame.size.width, bottom);
}

// ── Refresh ───────────────────────────────────────────────────────────────────

- (void)timerTick {
    [self updateLiveStatus];
    [self updateColorSwatch];
    if (_debugPanelVisible && _debugTextView) {
        NSString *diag = g_vcamDiag ? g_vcamDiag : @"(no data)";
        _debugTextView.text = diag;
        if (diag.length > 0)
            [_debugTextView scrollRangeToVisible:NSMakeRange(diag.length - 1, 1)];
    }
}

- (void)updateLiveStatus {
    BOOL connected = [VCamBridge sharedInstance].isConnected;
    if (_liveSwitch.on && connected) {
        _liveStatusLabel.text = @"✅ Đã sẵn sàng";
        _liveStatusLabel.textColor = [UIColor systemGreenColor];
    } else if (_liveSwitch.on) {
        _liveStatusLabel.text = @"⏳ Đang kết nối...";
        _liveStatusLabel.textColor = [UIColor systemOrangeColor];
    } else {
        _liveStatusLabel.text = @"⚫ Tắt";
        _liveStatusLabel.textColor = [UIColor lightGrayColor];
    }
}

- (void)updateColorSwatch {
    if (!_colorSwatch) return;
    NSDictionary *fp = BINFlashLoadPrefs();
    double hue = BINFlashDoubleForKey(fp, kBINFlashKeyHue, kBINFlashDefaultHue);
    _colorSwatch.backgroundColor = [UIColor colorWithHue:(CGFloat)hue
                                              saturation:1.0
                                              brightness:1.0
                                                   alpha:1.0];
    if (_colorBar) _colorBar.hue = (CGFloat)hue;
}

- (void)refreshFromPrefs {
    NSDictionary *fp = BINFlashLoadPrefs();
    if (_speedRow)      { _speedRow.slider.value      = (float)BINFlashDoubleForKey(fp, kBINFlashKeySpeed,      kBINFlashDefaultSpeed);      _speedRow.valueLabel.text = [NSString stringWithFormat:@"%.1f", _speedRow.slider.value]; }
    if (_brightnessRow) { _brightnessRow.slider.value = (float)BINFlashDoubleForKey(fp, kBINFlashKeyBrightness, kBINFlashDefaultBrightness); _brightnessRow.valueLabel.text = [NSString stringWithFormat:@"%.0f", _brightnessRow.slider.value]; }
    if (_regionRow)     { _regionRow.slider.value     = (float)BINFlashDoubleForKey(fp, kBINFlashKeyRegion,     kBINFlashDefaultRegion);     _regionRow.valueLabel.text = [NSString stringWithFormat:@"%.0f", _regionRow.slider.value]; }
    [self updateLiveStatus];
    [self updateColorSwatch];
}

// ── IPC helper ───────────────────────────────────────────────────────────────

- (NSMutableData *)packetCode:(int32_t)code {
    NSMutableData *d = [NSMutableData dataWithCapacity:4];
    [d appendBytes:&code length:4];
    return d;
}

// ── UITextFieldDelegate ───────────────────────────────────────────────────────

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

@end

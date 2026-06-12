// BINFlashPanel.m
// Reconstructed from BINFlashPanel ObjC class (0x5324–0x8EBC)
//
// Key addresses:
//   initWithFrame:    0x5324  (687 instructions)
//   reloadFromPrefs   0x6AA0
//   switchChanged:    0x78CC
//   sliderChanged:    0x7A98
//   colorChanged:     0x7B84
//   nudgeRegionByX:y: 0x7C24
//   resetTapped       0x8344
//   sub_79A4          0x79A4 — key/value → save helper
//   sub_7E78          0x7E78 — full save + notify_post

#import "BINFlashPanel.h"
#import "../Views/BINFlashColorBar.h"
#import "../Prefs/BINFlashPrefs.h"

// Panel dimensions (from constant pool in initWithFrame: at 0x5324)
#define kPanelMaxWidth      330.0
#define kPanelMargin        20.0
#define kPanelCornerRadius  12.0
#define kShadowOpacity      0.5f
#define kShadowRadius       8.0
#define kRowHeight          50.0
#define kSliderRowHeight    80.0

@implementation BINFlashPanel

// --- -[BINFlashPanel initWithFrame:] (0x5324) ---
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    // Background and styling
    self.backgroundColor = [UIColor whiteColor];
    self.layer.cornerRadius = kPanelCornerRadius;
    self.layer.shadowColor  = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = kShadowOpacity;
    self.layer.shadowRadius  = kShadowRadius;
    self.layer.shadowOffset  = CGSizeZero;

    CGFloat y = kPanelMargin;
    CGFloat w = frame.size.width;

    // Live switch row
    UISwitch *liveSwitch = [self addSwitchRow:@"Live"
                                          key:kBINFlashKeyLive
                                            y:y];
    self.liveSwitch = liveSwitch;
    y += kRowHeight;

    // Flash switch row
    UISwitch *flashSwitch = [self addSwitchRow:@"Flash"
                                           key:kBINFlashKeyFlash
                                             y:y];
    self.flashSwitch = flashSwitch;
    y += kRowHeight;

    // Speed slider row (range: 0.5 – 102.3 Hz)
    UILabel *speedValueLabel = nil;
    UISlider *speedSlider = [self addSliderRow:@"Speed"
                                           key:kBINFlashKeySpeed
                                           min:0.5
                                           max:102.3
                                             y:y
                                    valueLabel:&speedValueLabel];
    self.speedSlider     = speedSlider;
    self.speedValueLabel = speedValueLabel;
    y += kSliderRowHeight;

    // Brightness slider (0–100)
    UILabel *brightnessValueLabel = nil;
    UISlider *brightnessSlider = [self addSliderRow:@"Brightness"
                                                key:kBINFlashKeyBrightness
                                                min:0
                                                max:100
                                                  y:y
                                         valueLabel:&brightnessValueLabel];
    self.brightnessSlider     = brightnessSlider;
    self.brightnessValueLabel = brightnessValueLabel;
    y += kSliderRowHeight;

    // Region slider (0–100)
    UILabel *regionValueLabel = nil;
    UISlider *regionSlider = [self addSliderRow:@"Region"
                                            key:kBINFlashKeyRegion
                                            min:0
                                            max:100
                                              y:y
                                     valueLabel:&regionValueLabel];
    self.regionSlider     = regionSlider;
    self.regionValueLabel = regionValueLabel;
    y += kSliderRowHeight;

    // Color bar (hue selector)
    BINFlashColorBar *colorBar = [[BINFlashColorBar alloc] initWithFrame:CGRectMake(kPanelMargin, y, w - kPanelMargin*2, 36)];
    [colorBar addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:colorBar];
    self.colorBar = colorBar;
    y += 44;

    // Aim/nudge buttons (4 directional: left, up, down, right)
    NSArray *aimButtons = @[
        [self addAimButtonWithSystemName:@"arrow.left"  fallback:@"◀" frame:CGRectMake(kPanelMargin,       y+16, 44, 44) action:@selector(nudgeLeftTapped)],
        [self addAimButtonWithSystemName:@"arrow.up"    fallback:@"▲" frame:CGRectMake(kPanelMargin+52,    y,    44, 44) action:@selector(nudgeUpTapped)],
        [self addAimButtonWithSystemName:@"arrow.down"  fallback:@"▼" frame:CGRectMake(kPanelMargin+52,    y+32, 44, 44) action:@selector(nudgeDownTapped)],
        [self addAimButtonWithSystemName:@"arrow.right" fallback:@"▶" frame:CGRectMake(kPanelMargin+104,   y+16, 44, 44) action:@selector(nudgeRightTapped)],
    ];
    self.aimButtons = aimButtons;
    y += 88;

    // Hide and Reset buttons
    UIButton *hideBtn  = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.frame = CGRectMake(kPanelMargin,       y, (w - kPanelMargin*3) / 2, 36);
    [hideBtn setTitle:@"Hide" forState:UIControlStateNormal];
    [hideBtn addTarget:self action:@selector(hideTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:hideBtn];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(CGRectGetMaxX(hideBtn.frame) + kPanelMargin, y, CGRectGetWidth(hideBtn.frame), 36);
    [resetBtn setTitle:@"Reset" forState:UIControlStateNormal];
    [resetBtn addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:resetBtn];

    return self;
}

#pragma mark - Factory helpers

// --- -[BINFlashPanel addSwitchRow:key:y:] (0x6100) ---
- (UISwitch *)addSwitchRow:(NSString *)title key:(NSString *)key y:(CGFloat)y {
    CGFloat w = self.bounds.size.width;

    UILabel *label = [self labelWithText:title frame:CGRectMake(kPanelMargin, y, w*0.5, kRowHeight)];
    [self addSubview:label];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(w - 72, y + 7, 51, 31)];
    sw.onTintColor = [UIColor colorWithRed:0.38 green:0.9 blue:0.48 alpha:1.0];
    sw.accessibilityIdentifier = key;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:sw];

    return sw;
}

// --- -[BINFlashPanel addSliderRow:key:min:max:y:valueLabel:] (0x6768) ---
- (UISlider *)addSliderRow:(NSString *)title key:(NSString *)key
                       min:(float)minVal max:(float)maxVal
                         y:(CGFloat)y valueLabel:(UILabel **)outLabel {
    CGFloat w = self.bounds.size.width;

    UILabel *titleLabel = [self labelWithText:title frame:CGRectMake(kPanelMargin, y, w*0.4, 22)];
    [self addSubview:titleLabel];

    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(w*0.4 + kPanelMargin, y, w*0.35, 22)];
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    [self addSubview:valueLabel];
    if (outLabel) *outLabel = valueLabel;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(kPanelMargin, y + 24, w - kPanelMargin*2, 22)];
    slider.minimumValue = minVal;
    slider.maximumValue = maxVal;
    slider.tintColor = [UIColor colorWithRed:0.38 green:0.9 blue:0.48 alpha:1.0];
    slider.accessibilityIdentifier = key;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:slider];

    return slider;
}

// --- -[BINFlashPanel addAimButtonWithSystemName:fallback:frame:action:] (0x6404) ---
- (UIButton *)addAimButtonWithSystemName:(NSString *)systemName
                                fallback:(NSString *)fallback
                                   frame:(CGRect)frame
                                  action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.layer.cornerRadius = frame.size.width / 2.0;
    btn.backgroundColor = [UIColor colorWithRed:0.38 green:0.9 blue:0.48 alpha:1.0];
    btn.tintColor = [UIColor whiteColor];

    if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
        UIImage *img = [UIImage systemImageNamed:systemName];
        [btn setImage:img forState:UIControlStateNormal];
    } else {
        [btn setTitle:fallback forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }

    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:btn];
    return btn;
}

// --- -[BINFlashPanel labelWithText:frame:] (0x5F98) ---
- (UILabel *)labelWithText:(NSString *)text frame:(CGRect)frame {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.textColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    return label;
}

#pragma mark - Prefs sync

// --- -[BINFlashPanel reloadFromPrefs] (0x6AA0) ---
- (void)reloadFromPrefs {
    NSDictionary *prefs = BINFlashLoadPrefs();

    [self.liveSwitch  setOn:BINFlashBoolForKey(prefs, kBINFlashKeyLive,   kBINFlashDefaultLive)   animated:NO];
    [self.flashSwitch setOn:BINFlashBoolForKey(prefs, kBINFlashKeyFlash,  kBINFlashDefaultFlash)  animated:NO];

    self.speedSlider.value      = (float)BINFlashDoubleForKey(prefs, kBINFlashKeySpeed,      kBINFlashDefaultSpeed);
    self.brightnessSlider.value = (float)BINFlashDoubleForKey(prefs, kBINFlashKeyBrightness, kBINFlashDefaultBrightness);
    self.regionSlider.value     = (float)BINFlashDoubleForKey(prefs, kBINFlashKeyRegion,     kBINFlashDefaultRegion);

    double hue = BINFlashDoubleForKey(prefs, kBINFlashKeyHue, kBINFlashDefaultHue);
    [self.colorBar setHue:hue];

    [self updateValueLabels];
    [self updateAimButtons:prefs];
}

// --- -[BINFlashPanel updateValueLabels] (0x7388) ---
- (void)updateValueLabels {
    self.speedValueLabel.text      = [NSString stringWithFormat:@"%.1f", self.speedSlider.value];
    self.brightnessValueLabel.text = [NSString stringWithFormat:@"%.0f", self.brightnessSlider.value];
    self.regionValueLabel.text     = [NSString stringWithFormat:@"%.0f", self.regionSlider.value];
}

// --- -[BINFlashPanel updateAimButtons:] (0x75EC) ---
// Highlight aim buttons when manualRegion is active (border turns white).
- (void)updateAimButtons:(NSDictionary *)prefs {
    BOOL manual = BINFlashBoolForKey(prefs, kBINFlashKeyManualRegion, kBINFlashDefaultManualRegion);
    for (UIButton *btn in self.aimButtons) {
        btn.layer.borderWidth = manual ? 2.0 : 0.0;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
    }
}

#pragma mark - Control event handlers

// --- sub_79A4 (0x79A4) — internal save helper ---
// Builds single-entry dict and calls BINFlashSavePrefs.
- (void)_saveKey:(NSString *)key value:(id)value {
    if (!key || !value) return;
    BINFlashSavePrefs(@{key: value});
}

// --- -[BINFlashPanel switchChanged:] (0x78CC) ---
- (void)switchChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    [self _saveKey:key value:@(sender.isOn)];
}

// --- -[BINFlashPanel sliderChanged:] (0x7A98) ---
- (void)sliderChanged:(UISlider *)sender {
    [self updateValueLabels];
    NSString *key = sender.accessibilityIdentifier;
    [self _saveKey:key value:@(sender.value)];
}

// --- -[BINFlashPanel colorChanged:] (0x7B84) ---
- (void)colorChanged:(id)sender {
    double hue = [self.colorBar hue];
    [self _saveKey:kBINFlashKeyHue value:@(hue)];
}

#pragma mark - Region nudge

// --- -[BINFlashPanel nudgeRegionByX:y:] (0x7C24) ---
- (void)nudgeRegionByX:(double)dx y:(double)dy {
    NSDictionary *prefs = BINFlashLoadPrefs();
    double rx = BINFlashDoubleForKey(prefs, kBINFlashKeyRegionX, kBINFlashDefaultRegionX);
    double ry = BINFlashDoubleForKey(prefs, kBINFlashKeyRegionY, kBINFlashDefaultRegionY);

    rx = fmax(fmin(rx + dx, 1.0), 0.0);
    ry = fmax(fmin(ry + dy, 1.0), 0.0);

    BINFlashSavePrefs(@{
        kBINFlashKeyRegionX:      @(rx),
        kBINFlashKeyRegionY:      @(ry),
        kBINFlashKeyManualRegion: @YES,
    });

    NSDictionary *updated = BINFlashLoadPrefs();
    [self updateAimButtons:updated];
}

- (void)nudgeLeftTapped  { [self nudgeRegionByX:-0.1 y:0];  }
- (void)nudgeRightTapped { [self nudgeRegionByX:+0.1 y:0];  }
- (void)nudgeUpTapped    { [self nudgeRegionByX:0    y:-0.1];}
- (void)nudgeDownTapped  { [self nudgeRegionByX:0    y:+0.1];}

#pragma mark - Hide / Reset

// --- -[BINFlashPanel hideTapped] (0x82B0) ---
- (void)hideTapped {
    if (self.hideHandler)
        self.hideHandler();
}

// --- -[BINFlashPanel resetTapped] (0x8344) ---
- (void)resetTapped {
    NSDictionary *defaults = @{
        kBINFlashKeyLive:         @(kBINFlashDefaultLive),
        kBINFlashKeyFlash:        @(kBINFlashDefaultFlash),
        kBINFlashKeyManualRegion: @(kBINFlashDefaultManualRegion),
        kBINFlashKeySpeed:        @(kBINFlashDefaultSpeed),
        kBINFlashKeyBrightness:   @(kBINFlashDefaultBrightness),
        kBINFlashKeyRegion:       @(kBINFlashDefaultRegion),
        kBINFlashKeyHue:          @(kBINFlashDefaultHue),
        kBINFlashKeyRegionX:      @(kBINFlashDefaultRegionX),
        kBINFlashKeyRegionY:      @(kBINFlashDefaultRegionY),
    };
    BINFlashSavePrefs(defaults);
    [self reloadFromPrefs];
}

- (void)dealloc {
    [_liveSwitch release];
    [_flashSwitch release];
    [_speedSlider release];
    [_brightnessSlider release];
    [_regionSlider release];
    [_speedValueLabel release];
    [_brightnessValueLabel release];
    [_regionValueLabel release];
    [_colorBar release];
    [_aimButtons release];
    [_hideHandler release];
    [super dealloc];
}

@end

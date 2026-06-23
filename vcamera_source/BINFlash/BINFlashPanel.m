// BINFlashPanel.m
// Reconstructed from BINFlashPanel ObjC class (0x5324–0x8EBC)
// Updated for merged vcamera.dylib: imports flat (same directory).

#import "BINFlashPanel.h"
#import "BINFlashColorBar.h"
#import "BINFlashPrefs.h"

#define kPanelMaxWidth      330.0
#define kPanelMargin        20.0
#define kPanelCornerRadius  12.0
#define kShadowOpacity      0.5f
#define kShadowRadius       8.0
#define kRowHeight          50.0
#define kSliderRowHeight    80.0

@implementation BINFlashPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor     = [UIColor whiteColor];
    self.layer.cornerRadius  = kPanelCornerRadius;
    self.layer.shadowColor   = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = kShadowOpacity;
    self.layer.shadowRadius  = kShadowRadius;
    self.layer.shadowOffset  = CGSizeZero;

    CGFloat y = kPanelMargin, w = frame.size.width;

    UISwitch *liveSwitch  = [self addSwitchRow:@"Live"  key:kBINFlashKeyLive  y:y];
    self.liveSwitch = liveSwitch;
    y += kRowHeight;

    UISwitch *flashSwitch = [self addSwitchRow:@"Flash" key:kBINFlashKeyFlash y:y];
    self.flashSwitch = flashSwitch;
    y += kRowHeight;

    UILabel *speedValueLabel = nil;
    UISlider *speedSlider = [self addSliderRow:@"Speed" key:kBINFlashKeySpeed
                                           min:0.5 max:102.3 y:y valueLabel:&speedValueLabel];
    self.speedSlider = speedSlider; self.speedValueLabel = speedValueLabel;
    y += kSliderRowHeight;

    UILabel *brightnessValueLabel = nil;
    UISlider *brightnessSlider = [self addSliderRow:@"Brightness" key:kBINFlashKeyBrightness
                                                min:0 max:100 y:y valueLabel:&brightnessValueLabel];
    self.brightnessSlider = brightnessSlider; self.brightnessValueLabel = brightnessValueLabel;
    y += kSliderRowHeight;

    UILabel *regionValueLabel = nil;
    UISlider *regionSlider = [self addSliderRow:@"Region" key:kBINFlashKeyRegion
                                            min:0 max:100 y:y valueLabel:&regionValueLabel];
    self.regionSlider = regionSlider; self.regionValueLabel = regionValueLabel;
    y += kSliderRowHeight;

    BINFlashColorBar *colorBar = [[BINFlashColorBar alloc]
        initWithFrame:CGRectMake(kPanelMargin, y, w - kPanelMargin*2, 36)];
    [colorBar addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:colorBar];
    self.colorBar = colorBar;
    y += 44;

    NSArray *aimButtons = @[
        [self addAimButtonWithSystemName:@"arrow.left"  fallback:@"◀"
              frame:CGRectMake(kPanelMargin,     y+16, 44, 44) action:@selector(nudgeLeftTapped)],
        [self addAimButtonWithSystemName:@"arrow.up"    fallback:@"▲"
              frame:CGRectMake(kPanelMargin+52,  y,    44, 44) action:@selector(nudgeUpTapped)],
        [self addAimButtonWithSystemName:@"arrow.down"  fallback:@"▼"
              frame:CGRectMake(kPanelMargin+52,  y+32, 44, 44) action:@selector(nudgeDownTapped)],
        [self addAimButtonWithSystemName:@"arrow.right" fallback:@"▶"
              frame:CGRectMake(kPanelMargin+104, y+16, 44, 44) action:@selector(nudgeRightTapped)],
    ];
    self.aimButtons = aimButtons;
    y += 88;

    UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.frame = CGRectMake(kPanelMargin, y, (w - kPanelMargin*3) / 2, 36);
    [hideBtn setTitle:@"Hide" forState:UIControlStateNormal];
    [hideBtn addTarget:self action:@selector(hideTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:hideBtn];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(CGRectGetMaxX(hideBtn.frame) + kPanelMargin, y,
                                CGRectGetWidth(hideBtn.frame), 36);
    [resetBtn setTitle:@"Reset" forState:UIControlStateNormal];
    [resetBtn addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:resetBtn];

    return self;
}

- (UISwitch *)addSwitchRow:(NSString *)title key:(NSString *)key y:(CGFloat)y {
    CGFloat w = self.bounds.size.width;
    [self addSubview:[self labelWithText:title frame:CGRectMake(kPanelMargin, y, w*0.5, kRowHeight)]];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(w - 72, y + 7, 51, 31)];
    sw.onTintColor = [UIColor colorWithRed:0.38 green:0.9 blue:0.48 alpha:1.0];
    sw.accessibilityIdentifier = key;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:sw];
    return sw;
}

- (UISlider *)addSliderRow:(NSString *)title key:(NSString *)key
                       min:(float)minVal max:(float)maxVal
                         y:(CGFloat)y valueLabel:(UILabel **)outLabel {
    CGFloat w = self.bounds.size.width;
    [self addSubview:[self labelWithText:title frame:CGRectMake(kPanelMargin, y, w*0.4, 22)]];
    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(w*0.4 + kPanelMargin, y, w*0.35, 22)];
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    [self addSubview:valueLabel];
    if (outLabel) *outLabel = valueLabel;
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(kPanelMargin, y + 24, w - kPanelMargin*2, 22)];
    slider.minimumValue = minVal; slider.maximumValue = maxVal;
    slider.tintColor = [UIColor colorWithRed:0.38 green:0.9 blue:0.48 alpha:1.0];
    slider.accessibilityIdentifier = key;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:slider];
    return slider;
}

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
        [btn setImage:[UIImage systemImageNamed:systemName] forState:UIControlStateNormal];
    } else {
        [btn setTitle:fallback forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:btn];
    return btn;
}

- (UILabel *)labelWithText:(NSString *)text frame:(CGRect)frame {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.textColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    return label;
}

- (void)reloadFromPrefs {
    NSDictionary *prefs = BINFlashLoadPrefs();
    [self.liveSwitch  setOn:BINFlashBoolForKey(prefs, kBINFlashKeyLive,   kBINFlashDefaultLive)   animated:NO];
    [self.flashSwitch setOn:BINFlashBoolForKey(prefs, kBINFlashKeyFlash,  kBINFlashDefaultFlash)  animated:NO];
    self.speedSlider.value      = (float)BINFlashDoubleForKey(prefs, kBINFlashKeySpeed,      kBINFlashDefaultSpeed);
    self.brightnessSlider.value = (float)BINFlashDoubleForKey(prefs, kBINFlashKeyBrightness, kBINFlashDefaultBrightness);
    self.regionSlider.value     = (float)BINFlashDoubleForKey(prefs, kBINFlashKeyRegion,     kBINFlashDefaultRegion);
    [self.colorBar setHue:BINFlashDoubleForKey(prefs, kBINFlashKeyHue, kBINFlashDefaultHue)];
    [self updateValueLabels];
    [self updateAimButtons:prefs];
}

- (void)updateValueLabels {
    self.speedValueLabel.text      = [NSString stringWithFormat:@"%.1f", self.speedSlider.value];
    self.brightnessValueLabel.text = [NSString stringWithFormat:@"%.0f", self.brightnessSlider.value];
    self.regionValueLabel.text     = [NSString stringWithFormat:@"%.0f", self.regionSlider.value];
}

- (void)updateAimButtons:(NSDictionary *)prefs {
    BOOL manual = BINFlashBoolForKey(prefs, kBINFlashKeyManualRegion, kBINFlashDefaultManualRegion);
    for (UIButton *btn in self.aimButtons) {
        btn.layer.borderWidth = manual ? 2.0 : 0.0;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
    }
}

- (void)_saveKey:(NSString *)key value:(id)value {
    if (!key || !value) return;
    BINFlashSavePrefs(@{key: value});
}

- (void)switchChanged:(UISwitch *)sender {
    [self _saveKey:sender.accessibilityIdentifier value:@(sender.isOn)];
}

- (void)sliderChanged:(UISlider *)sender {
    [self updateValueLabels];
    [self _saveKey:sender.accessibilityIdentifier value:@(sender.value)];
}

- (void)colorChanged:(id)sender {
    [self _saveKey:kBINFlashKeyHue value:@([self.colorBar hue])];
}

- (void)nudgeRegionByX:(double)dx y:(double)dy {
    NSDictionary *prefs = BINFlashLoadPrefs();
    double rx = fmax(fmin(BINFlashDoubleForKey(prefs, kBINFlashKeyRegionX, kBINFlashDefaultRegionX) + dx, 1.0), 0.0);
    double ry = fmax(fmin(BINFlashDoubleForKey(prefs, kBINFlashKeyRegionY, kBINFlashDefaultRegionY) + dy, 1.0), 0.0);
    BINFlashSavePrefs(@{ kBINFlashKeyRegionX: @(rx), kBINFlashKeyRegionY: @(ry), kBINFlashKeyManualRegion: @YES });
    [self updateAimButtons:BINFlashLoadPrefs()];
}

- (void)nudgeLeftTapped  { [self nudgeRegionByX:-0.1 y:0];   }
- (void)nudgeRightTapped { [self nudgeRegionByX:+0.1 y:0];   }
- (void)nudgeUpTapped    { [self nudgeRegionByX:0    y:-0.1]; }
- (void)nudgeDownTapped  { [self nudgeRegionByX:0    y:+0.1]; }

- (void)hideTapped  { if (self.hideHandler) self.hideHandler(); }

- (void)resetTapped {
    BINFlashSavePrefs(@{
        kBINFlashKeyLive:         @(kBINFlashDefaultLive),
        kBINFlashKeyFlash:        @(kBINFlashDefaultFlash),
        kBINFlashKeyManualRegion: @(kBINFlashDefaultManualRegion),
        kBINFlashKeySpeed:        @(kBINFlashDefaultSpeed),
        kBINFlashKeyBrightness:   @(kBINFlashDefaultBrightness),
        kBINFlashKeyRegion:       @(kBINFlashDefaultRegion),
        kBINFlashKeyHue:          @(kBINFlashDefaultHue),
        kBINFlashKeyRegionX:      @(kBINFlashDefaultRegionX),
        kBINFlashKeyRegionY:      @(kBINFlashDefaultRegionY),
    });
    [self reloadFromPrefs];
}

- (void)dealloc {
    [_liveSwitch release]; [_flashSwitch release];
    [_speedSlider release]; [_brightnessSlider release]; [_regionSlider release];
    [_speedValueLabel release]; [_brightnessValueLabel release]; [_regionValueLabel release];
    [_colorBar release]; [_aimButtons release]; [_hideHandler release];
    [super dealloc];
}

@end

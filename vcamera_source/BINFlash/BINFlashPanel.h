// BINFlashPanel.h
#import <UIKit/UIKit.h>
@class BINFlashColorBar;

@interface BINFlashPanel : UIView
@property (nonatomic, strong) UISwitch  *liveSwitch;
@property (nonatomic, strong) UISwitch  *flashSwitch;
@property (nonatomic, strong) UISlider  *speedSlider;
@property (nonatomic, strong) UISlider  *brightnessSlider;
@property (nonatomic, strong) UISlider  *regionSlider;
@property (nonatomic, strong) UILabel   *speedValueLabel;
@property (nonatomic, strong) UILabel   *brightnessValueLabel;
@property (nonatomic, strong) UILabel   *regionValueLabel;
@property (nonatomic, strong) BINFlashColorBar *colorBar;
@property (nonatomic, strong) NSArray   *aimButtons;
@property (nonatomic, copy)   void (^hideHandler)(void);
- (void)reloadFromPrefs;
- (void)updateValueLabels;
- (void)updateAimButtons:(NSDictionary *)prefs;
- (void)nudgeRegionByX:(double)dx y:(double)dy;
- (void)switchChanged:(UISwitch *)sender;
- (void)sliderChanged:(UISlider *)sender;
- (void)colorChanged:(id)sender;
- (void)nudgeLeftTapped;
- (void)nudgeRightTapped;
- (void)nudgeUpTapped;
- (void)nudgeDownTapped;
- (void)hideTapped;
- (void)resetTapped;
@end

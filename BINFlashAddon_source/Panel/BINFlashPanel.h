// BINFlashPanel.h
// Reconstructed from BINFlashPanel ObjC class (0x5324–0x8EBC)
//
// The main settings panel UI. Floats above the camera app at UIWindowLevelAlert+1000.
// Contains: Live switch, Flash switch, Speed/Brightness/Region sliders,
// Hue color bar, aim/nudge buttons, value labels.
// All changes call BINFlashSavePrefs() which writes plist + notify_post.

#import <UIKit/UIKit.h>
@class BINFlashColorBar;

@interface BINFlashPanel : UIView

// UI controls (properties mirror binary ivars)
@property (nonatomic, strong) UISwitch  *liveSwitch;
@property (nonatomic, strong) UISwitch  *flashSwitch;
@property (nonatomic, strong) UISlider  *speedSlider;
@property (nonatomic, strong) UISlider  *brightnessSlider;
@property (nonatomic, strong) UISlider  *regionSlider;
@property (nonatomic, strong) UILabel   *speedValueLabel;
@property (nonatomic, strong) UILabel   *brightnessValueLabel;
@property (nonatomic, strong) UILabel   *regionValueLabel;
@property (nonatomic, strong) BINFlashColorBar *colorBar;
@property (nonatomic, strong) NSArray   *aimButtons;        // 4 UIButton direction keys

// Block invoked by hideTapped (set by BINFlashController::start)
@property (nonatomic, copy)   void (^hideHandler)(void);

// Sync all UI controls to current preferences
- (void)reloadFromPrefs;  // 0x6AA0

// Update numeric display labels (speed/brightness/region current values)
- (void)updateValueLabels;  // 0x7388

// Highlight aim buttons based on current manualRegion state
- (void)updateAimButtons:(NSDictionary *)prefs;  // 0x75EC

// Move region target by (dx, dy) in [0,1] coordinate space, clamps to bounds
- (void)nudgeRegionByX:(double)dx y:(double)dy;  // 0x7C24

// Control event handlers
- (void)switchChanged:(UISwitch *)sender;   // 0x78CC
- (void)sliderChanged:(UISlider *)sender;   // 0x7A98
- (void)colorChanged:(id)sender;            // 0x7B84

// Button actions
- (void)nudgeLeftTapped;   // 0x8250 → nudgeRegionByX:-0.1 y:0
- (void)nudgeRightTapped;  // 0x8268 → nudgeRegionByX:+0.1 y:0
- (void)nudgeUpTapped;     // 0x8280 → nudgeRegionByX:0 y:-0.1
- (void)nudgeDownTapped;   // 0x8298 → nudgeRegionByX:0 y:+0.1
- (void)hideTapped;        // 0x82B0 → call hideHandler block
- (void)resetTapped;       // 0x8344 → reset all prefs to defaults

@end

// VCamColorDot.h
// Drag-only donut that marks where color sampling happens.
// No tap action. Position -> vcamSendPickerSampleRequest coordinates.

#import <UIKit/UIKit.h>

@interface VCamColorDot : UIView

@property (nonatomic, assign) BOOL    isMoving;
@property (nonatomic, assign) CGPoint beginPosition;
@property (nonatomic, assign) float   offsetX;
@property (nonatomic, assign) float   offsetY;

@end

// Global — read by vcamUpdateFloatButton to compute sample coords.
extern VCamColorDot *g_colorDot;

// Called from vcamUpdateFloatButton every 200ms on main queue.
// show=YES: create if needed and show; show=NO: hide.
void vcamUpdateColorDot(BOOL show);
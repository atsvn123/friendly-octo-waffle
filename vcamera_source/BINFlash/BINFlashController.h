// BINFlashController.h
#import <UIKit/UIKit.h>
@class BINFlashPanel;
@class BINFlashOvalView;

@interface BINFlashController : NSObject
+ (instancetype)shared;
- (void)startWhenReady;
- (void)start;
- (void)showPanel;
- (void)tick;
@property (nonatomic, strong) UIWindow       *window;
@property (nonatomic, strong) BINFlashPanel  *panel;
@property (nonatomic, strong) BINFlashOvalView *ovalView;
@property (nonatomic, strong) UIButton       *miniButton;
@property (nonatomic, strong) NSTimer        *timer;
@property (nonatomic, assign) BOOL            panelLocked;
@end

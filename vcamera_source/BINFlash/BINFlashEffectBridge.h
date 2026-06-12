// BINFlashEffectBridge.h
#import <Foundation/Foundation.h>
@interface BINFlashEffectBridge : NSObject
+ (instancetype)shared;
- (void)tick;
- (void)registerFilter:(id)filter;
@end

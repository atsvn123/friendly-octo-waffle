// BINFlashEffectBridge.h
// Reconstructed from BINFlashEffectBridge ObjC class + sub_B394 (0xB394)
// + sub_C924 (0xC924) + sub_CA08 (0xCA08)
//
// BINFlashEffectBridge is the hook layer between the UI settings and the
// GPUImage beauty filter pipeline running inside the camera app.
//
// It:
//   1. Swizzles GPUImageBaseBeautyFaceFilter::setWhite: and
//      ::setUniformsWithLandmarks: via method_setImplementation (NOT MSHook)
//   2. Maintains a weak NSHashTable of registered filter instances
//   3. Computes a pulsing white value 20x/sec and applies it to all filters

#import <Foundation/Foundation.h>

@interface BINFlashEffectBridge : NSObject

// Singleton
+ (instancetype)shared;

// Called by BINFlashController::tick every 50ms.
// First call: performs method_setImplementation swizzles (dispatch_once guarded).
// Every call: reads prefs, computes white value, applies to all registered filters.
- (void)tick;

// Register a GPUImageBaseBeautyFaceFilter instance.
// Called from within the swizzle hooks when a filter calls setWhite: or
// setUniformsWithLandmarks:. Stored as a weak reference — auto-removed on dealloc.
- (void)registerFilter:(id)filter;

@end

// Tweak.x
// Reconstructed from InitFunc_0 (0xB588) and stru_100F8 block
//
// BINFlashAddon.dylib entry point.
// IDA: dispatch_async(dispatch_get_main_queue(), ^{ [[BINFlashController shared] startWhenReady]; })

#import "../Controller/BINFlashController.h"
#import <UIKit/UIKit.h>

// --- InitFunc_0 (0xB588) ---
__attribute__((constructor))
static void BINFlashAddon_Init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BINFlashController shared] startWhenReady];
    });
}

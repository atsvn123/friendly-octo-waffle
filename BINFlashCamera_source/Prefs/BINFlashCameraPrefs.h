// BINFlashCameraPrefs.h
// Reconstructed from sub_539C (0x539C) — prefs loader with 100ms cache
//
// Reads from the same plist domain as BINFlashAddon:
//   "com.meo.flashaddon" — 4 path fallback (rootful + rootless jailbreak)
// Listens to the same Darwin notify channel:
//   "com.meo.flashaddon.changed"
//
// Key difference vs BINFlashAddon: cached with 100ms TTL using CFAbsoluteTimeGetCurrent.
// (BINFlashAddon reads at 20Hz via NSTimer; BINFlashCamera re-reads every 100ms on demand)

#import <Foundation/Foundation.h>

// Plist domain and notify key (shared with BINFlashAddon)
#define kBINFlashCameraPlistDomain  @"com.meo.flashaddon"
#define kBINFlashCameraNotifyKey    "com.meo.flashaddon.changed"

// Pref keys (same as BINFlashAddon)
#define kBINFlashKeyLive           @"live"
#define kBINFlashKeyFlash          @"flash"
#define kBINFlashKeySpeed          @"speed"
#define kBINFlashKeyBrightness     @"brightness"
#define kBINFlashKeyRegion         @"region"
#define kBINFlashKeyHue            @"hue"
#define kBINFlashKeyManualRegion   @"manualRegion"
#define kBINFlashKeyRegionX        @"regionX"
#define kBINFlashKeyRegionY        @"regionY"

// Default values
#define kBINFlashDefaultLive          YES
#define kBINFlashDefaultFlash         YES
#define kBINFlashDefaultSpeed         3.0
#define kBINFlashDefaultBrightness    51.0
#define kBINFlashDefaultRegion        30.0
#define kBINFlashDefaultHue           0.33
#define kBINFlashDefaultManualRegion  NO
#define kBINFlashDefaultRegionX       0.5
#define kBINFlashDefaultRegionY       0.42

// Cache TTL: 100ms (sub_539C checks CFAbsoluteTimeGetCurrent difference)
#define kBINFlashCameraPrefsCacheTTL  0.1

// Load prefs (with 100ms cache). sub_539C(). Thread-safe.
NSDictionary *BINFlashCameraLoadPrefs(void);

// Helpers: read typed values from prefs dict
double BINFlashCameraDoubleForKey(NSDictionary *prefs, NSString *key, double def);
BOOL   BINFlashCameraBoolForKey(NSDictionary *prefs, NSString *key, BOOL def);

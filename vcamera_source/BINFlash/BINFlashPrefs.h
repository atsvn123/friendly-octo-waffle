// BINFlashPrefs.h
// Unified flash prefs — merges BINFlashAddon (plist write + notify_post)
// with BINFlashCamera (100ms read cache for per-frame calls).
//
// SpringBoard side: BINFlashPanel calls BINFlashSavePrefs() to persist.
// mediaserverd side: BINFlashLoadPrefs() is called per-frame with a 100ms cache.

#import <Foundation/Foundation.h>

// Darwin notify channel (shared across processes)
#define kBINFlashNotifyChannel "com.meo.flashaddon.changed"

// Pref keys
#define kBINFlashKeyLive         @"live"
#define kBINFlashKeyFlash        @"flash"
#define kBINFlashKeyManualRegion @"manualRegion"
#define kBINFlashKeySpeed        @"speed"
#define kBINFlashKeyBrightness   @"brightness"
#define kBINFlashKeyRegion       @"region"
#define kBINFlashKeyHue          @"hue"
#define kBINFlashKeyRegionX      @"regionX"
#define kBINFlashKeyRegionY      @"regionY"
#define kBINFlashKeyAutoColor    @"autoColor"
#define kBINFlashKeyStaticFlash  @"staticFlash"

// Default values
#define kBINFlashDefaultLive          YES
#define kBINFlashDefaultFlash         NO
#define kBINFlashDefaultManualRegion  NO
#define kBINFlashDefaultSpeed         3.0
#define kBINFlashDefaultBrightness    51.0
#define kBINFlashDefaultRegion        30.0
#define kBINFlashDefaultHue           0.33
#define kBINFlashDefaultRegionX       0.5
#define kBINFlashDefaultRegionY       0.42
#define kBINFlashDefaultAutoColor     NO
#define kBINFlashDefaultStaticFlash   NO

// Cache TTL for per-frame reads (100ms)
#define kBINFlashPrefsCacheTTL  0.1

// Load prefs (100ms cache). Safe to call at 30fps from mediaserverd.
NSDictionary *BINFlashLoadPrefs(void);

// Save prefs: merges newValues, writes all 4 plist paths, posts Darwin notify.
// Called from SpringBoard side (BINFlashPanel) only.
void BINFlashSavePrefs(NSDictionary *newValues);

// Typed getters
BOOL   BINFlashBoolForKey(NSDictionary *prefs, NSString *key, BOOL defaultValue);
double BINFlashDoubleForKey(NSDictionary *prefs, NSString *key, double defaultValue);

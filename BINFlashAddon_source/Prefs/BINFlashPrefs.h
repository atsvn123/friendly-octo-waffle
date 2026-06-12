// BINFlashPrefs.h
// Reconstructed from sub_6CDC (0x6CDC), sub_7E78 (0x7E78), sub_89C4 (0x89C4)
// sub_7258 (0x7258), sub_72F0 (0x72F0)
//
// Preference system:
//   - Persistent: plist at com.meo.flashaddon (4 paths for rootful/rootless support)
//   - In-process: Darwin notify state (64-bit packed, zero-latency reads)
//   - notify_post("com.meo.flashaddon.changed") broadcasts to all listeners

#import <Foundation/Foundation.h>

// Darwin notify channel name
#define kBINFlashNotifyChannel "com.meo.flashaddon.changed"

// Plist key constants
#define kBINFlashKeyLive         @"live"
#define kBINFlashKeyFlash        @"flash"
#define kBINFlashKeyManualRegion @"manualRegion"
#define kBINFlashKeySpeed        @"speed"
#define kBINFlashKeyBrightness   @"brightness"
#define kBINFlashKeyRegion       @"region"
#define kBINFlashKeyHue          @"hue"
#define kBINFlashKeyRegionX      @"regionX"
#define kBINFlashKeyRegionY      @"regionY"

// Default values (from sub_6CDC / sub_72F0 call sites)
#define kBINFlashDefaultLive        YES
#define kBINFlashDefaultFlash       NO
#define kBINFlashDefaultManualRegion NO
#define kBINFlashDefaultSpeed       3.0
#define kBINFlashDefaultBrightness  51.0
#define kBINFlashDefaultRegion      30.0
#define kBINFlashDefaultHue         0.33
#define kBINFlashDefaultRegionX     0.5
#define kBINFlashDefaultRegionY     0.42

// sub_6CDC (0x6CDC)
// Load current preferences. Checks Darwin notify state first (zero-latency path),
// falls back to plist on disk. Returns autoreleased NSDictionary.
NSDictionary *BINFlashLoadPrefs(void);

// sub_7258 (0x7258)
// Safe bool getter from prefs dict. Returns defaultValue if key absent or non-bool.
BOOL BINFlashBoolForKey(NSDictionary *prefs, NSString *key, BOOL defaultValue);

// sub_72F0 (0x72F0)
// Safe double getter from prefs dict. Returns defaultValue if key absent or non-numeric.
double BINFlashDoubleForKey(NSDictionary *prefs, NSString *key, double defaultValue);

// sub_7E78 (0x7E78)
// Save preference changes. Merges newValues into current prefs, writes to all 4 plist paths,
// packs 64-bit notify state, calls notify_post.
void BINFlashSavePrefs(NSDictionary *newValues);

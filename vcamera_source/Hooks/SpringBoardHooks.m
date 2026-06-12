// SpringBoardHooks.m
// Reconstructed from vcamera.dylib SpringBoard hook set — fully verified against IDA.
// iOS 15 + 16 compatibility layer added on top of IDA-verified hooks.
//
// Hooks installed by installSpringBoardHooks():
//   SpringBoard: applicationDidFinishLaunching:, isShowingHomescreen
//   SBLockScreenManager: lockScreenViewControllerWillDismiss,
//       lockScreenViewControllerWillPresent, lockScreenViewControllerDidPresent,
//       _isPasscodeVisible, isLockScreenActive, setPasscodeVisible:animated:
//   SBDashBoardLockScreenEnvironment: handleVolumeUpButtonPress,
//       handleVolumeDownButtonPress, handleLockButtonPress  [iOS 15 only]
//   SpringBoard: volumeUpButtonDown:, volumeDownButtonDown:  [iOS 16 fallback]
//   FBSOrientationUpdate: initWithOrientation:sequenceNumber:duration:rotationDirection:
//   BWAmbientLightSensor: luxLevel, rearLuxLevel
//   Darwin CFNotification: lockcomplete, lockstate  [cross-version lock screen fallback]

#import "SpringBoardHooks.h"
#import <substrate.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"

// ── iOS version (detected once at hook-install time) ────────────────────────
static int s_iosMajor = 0;

// ── Saved original IMPs ──────────────────────────────────────────────────────
static IMP orig_applicationDidFinishLaunching        = NULL;
static IMP orig_isShowingHomescreen                  = NULL;
// SBLockScreenManager (6 hooks — IDA confirmed at 0x86760–0x86868)
static IMP orig_lockScreenWillDismiss                = NULL;
static IMP orig_lockScreenWillPresent                = NULL;
static IMP orig_lockScreenDidPresent                 = NULL;
static IMP orig_isPasscodeVisible                    = NULL;
static IMP orig_isLockScreenActive                   = NULL;
static IMP orig_setPasscodeVisible                   = NULL;
// SBDashBoardLockScreenEnvironment (3 hooks — iOS 15 only)
static IMP orig_handleVolumeUp                       = NULL;
static IMP orig_handleVolumeDown                     = NULL;
static IMP orig_handleLockButton                     = NULL;
// iOS 16 volume fallback: SpringBoard volumeUpButtonDown: / volumeDownButtonDown:
static IMP orig_sb_volumeUpDown                      = NULL;
static IMP orig_sb_volumeDownDown                    = NULL;
// FBSOrientationUpdate (1 hook — passthrough only)
static IMP orig_fbs_orientationInit                  = NULL;
// BWAmbientLightSensor (2 hooks — IDA sub_86A00 / sub_86A20)
static IMP orig_luxLevel                             = NULL;
static IMP orig_rearLuxLevel                         = NULL;

// ── Binary globals ──────────────────────────────────────────────────────────
// dword_130320 (press counter), qword_130328 (last-press timestamp)
static int    dword_130320 = 0;
static double qword_130328 = 0.0;
// byte_130151 (homescreen state — used by float button thread)
// declared in VCamBridge.h as extern volatile uint8_t g_menuReady
// g_lockScreenVisible (lock screen presenting state — shared with vcamUpdateFloatButton)
// declared in VCamBridge.h as extern volatile uint8_t g_lockScreenVisible

// ── Darwin notification callbacks — cross-version lock screen tracking ───────
// Works on iOS 15 and 16. Supplements (and on iOS 16 replaces) the
// SBLockScreenManager selector hooks below.
// com.apple.springboard.lockcomplete fires when the device is fully locked.
// com.apple.springboard.lockstate fires when the lock state changes (unlock).
static void onDarwinLockComplete(CFNotificationCenterRef c, void *o,
                                  CFStringRef n, const void *ob, CFDictionaryRef i) {
    g_lockScreenVisible = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VCamBridge sharedInstance] dismiss];
    });
}

static void onDarwinUnlocked(CFNotificationCenterRef c, void *o,
                               CFStringRef n, const void *ob, CFDictionaryRef i) {
    g_lockScreenVisible = 0;
}

// ── SpringBoard applicationDidFinishLaunching: (sub_866C0) ──────────────────
// IDA: [bridge setSpringBoard:application] FIRST, then call original.
// iOS 16 addition: set g_menuReady=1 after launch since isShowingHomescreen
// may not fire immediately on iOS 16 (App Library / new home screen).
static void hook_applicationDidFinishLaunching(id self, SEL cmd, id application) {
    VCamBridge *bridge = [VCamBridge sharedInstance];
    [bridge setSpringBoard:application];   // application arg, NOT self
    ((void (*)(id, SEL, id))orig_applicationDidFinishLaunching)(self, cmd, application);
    g_menuReady = 1;
}

// ── SpringBoard isShowingHomescreen (sub_8673C) ──────────────────────────────
// IDA: byte_130151 = result (direct assignment — no ternary)
static BOOL hook_isShowingHomescreen(id self, SEL cmd) {
    BOOL result = ((BOOL (*)(id, SEL))orig_isShowingHomescreen)(self, cmd);
    g_menuReady = result;   // direct assignment, no ternary
    return result;
}

// ── SBLockScreenManager hooks (6 hooks, IDA sub_86760–sub_86868) ─────────────
// WillDismiss: call original, then clear g_lockScreenVisible
static void hook_lockScreenWillDismiss(id self, SEL cmd) {
    ((void (*)(id, SEL))orig_lockScreenWillDismiss)(self, cmd);
    g_lockScreenVisible = 0;
}
// WillPresent: set g_lockScreenVisible=1, dismiss menu, call original
static void hook_lockScreenWillPresent(id self, SEL cmd) {
    g_lockScreenVisible = 1;
    [[VCamBridge sharedInstance] dismiss];
    ((void (*)(id, SEL))orig_lockScreenWillPresent)(self, cmd);
}
// DidPresent / _isPasscodeVisible / isLockScreenActive / setPasscodeVisible: — pure passthrough
static void hook_lockScreenDidPresent(id self, SEL cmd) {
    ((void (*)(id, SEL))orig_lockScreenDidPresent)(self, cmd);
}
static BOOL hook_isPasscodeVisible(id self, SEL cmd) {
    return ((BOOL (*)(id, SEL))orig_isPasscodeVisible)(self, cmd);
}
static BOOL hook_isLockScreenActive(id self, SEL cmd) {
    return ((BOOL (*)(id, SEL))orig_isLockScreenActive)(self, cmd);
}
static void hook_setPasscodeVisible(id self, SEL cmd, BOOL visible, BOOL animated) {
    ((void (*)(id, SEL, BOOL, BOOL))orig_setPasscodeVisible)(self, cmd, visible, animated);
}

// ── Volume button double-press → presentation (sub_86878 / sub_8693C) ────────
// IDA-exact:
//   1. Call original FIRST
//   2. oldCount = dword_130320++ (post-increment, test OLD value)
//   3. Even old value → save timestamp; odd old value → check elapsed
//   4. Threshold = 0.400000006f (float literal widened to double)
//   5. presentation() called DIRECTLY (NO dispatch_async)
static void volumeButtonPressed(id self, SEL cmd, IMP orig) {
    ((void (*)(id, SEL))orig)(self, cmd);   // original FIRST

    char oldCount = (char)(dword_130320++);  // post-increment, test old (pre-increment) value
    NSDate *d = [NSDate date];
    double now = [d timeIntervalSince1970];

    if ((oldCount & 1) == 0) {
        qword_130328 = now;   // even old value: save timestamp
    } else {
        double elapsed = now - qword_130328;
        if (elapsed < 0.400000006) {   // 0.400000006f as double — NO elapsed >= 0.0 check
            qword_130328 = 0.0;
            [[VCamBridge sharedInstance] presentation];   // direct call, NO dispatch_async
        }
    }
}

static void hook_handleVolumeUp(id self, SEL cmd) {
    volumeButtonPressed(self, cmd, orig_handleVolumeUp);
}
static void hook_handleVolumeDown(id self, SEL cmd) {
    volumeButtonPressed(self, cmd, orig_handleVolumeDown);
}

// ── iOS 16 volume button fallback — SpringBoard volumeUpButtonDown: / volumeDownButtonDown:
// These take an event argument (UIEvent or similar). Only installed when
// SBDashBoardLockScreenEnvironment selectors were absent (iOS 16).
// Same double-press counter logic as the iOS 15 path.
static void hook_sb_volumeUpDown(id self, SEL cmd, id event) {
    ((void (*)(id, SEL, id))orig_sb_volumeUpDown)(self, cmd, event);
    char oldCount = (char)(dword_130320++);
    NSDate *d = [NSDate date];
    double now = [d timeIntervalSince1970];
    if ((oldCount & 1) == 0) {
        qword_130328 = now;
    } else {
        double elapsed = now - qword_130328;
        if (elapsed < 0.400000006) {
            qword_130328 = 0.0;
            [[VCamBridge sharedInstance] presentation];
        }
    }
}

static void hook_sb_volumeDownDown(id self, SEL cmd, id event) {
    ((void (*)(id, SEL, id))orig_sb_volumeDownDown)(self, cmd, event);
    char oldCount = (char)(dword_130320++);
    NSDate *d = [NSDate date];
    double now = [d timeIntervalSince1970];
    if ((oldCount & 1) == 0) {
        qword_130328 = now;
    } else {
        double elapsed = now - qword_130328;
        if (elapsed < 0.400000006) {
            qword_130328 = 0.0;
            [[VCamBridge sharedInstance] presentation];
        }
    }
}

// ── Lock button → dismiss menu (sub_8681C) ────────────────────────────────────
// IDA: [bridge dismiss] then original (confirmed correct order)
static void hook_handleLockButton(id self, SEL cmd) {
    [[VCamBridge sharedInstance] dismiss];
    ((void (*)(id, SEL))orig_handleLockButton)(self, cmd);
}

// ── FBSOrientationUpdate initWithOrientation:... (sub_8660C) — pure passthrough
// IDA: pure passthrough on initWithOrientation:sequenceNumber:duration:rotationDirection:
// NOT on `orientation`. No g_deviceOrientation assignment.
static id hook_fbsOrientationUpdateInit(id self, SEL cmd, int orientation,
                                         NSUInteger seq, double dur, int rotDir) {
    return ((id (*)(id, SEL, int, NSUInteger, double, int))
            orig_fbs_orientationInit)(self, cmd, orientation, seq, dur, rotDir);
}

// ── BWAmbientLightSensor lux hooks (sub_86A00 / sub_86A20) ───────────────────
// luxLevel:     IDA: BLR orig, MOV W0,#0x64, RET → returns integer 100 in x0
// rearLuxLevel: IDA: BLR orig, MOV W8,#0x42B481E5, FMOV S0,W8, RET → returns float in s0
static NSInteger hook_luxLevel(id self, SEL _cmd) {
    ((NSInteger (*)(id, SEL))orig_luxLevel)(self, _cmd);   // call for side effects
    return 100;   // W0/X0 — integer return (NOT double/d0) — matches IDA MOV W0,#0x64
}
static float hook_rearLuxLevel(id self, SEL _cmd) {
    ((float (*)(id, SEL))orig_rearLuxLevel)(self, _cmd);   // call for side effects
    return 90.2537f;   // S0 — IEEE 754 0x42B481E5 — NOT 90.254
}

// ── installSpringBoardHooks ───────────────────────────────────────────────────
void installSpringBoardHooks(void) {
    // Detect iOS version once.
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    s_iosMajor = (int)v.majorVersion;

    // ── Darwin notifications — cross-version lock screen tracking ───────────────
    // Supplement SBLockScreenManager hooks (iOS 15). On iOS 16, where
    // lockScreenViewControllerWillPresent/WillDismiss selectors may not exist,
    // these are the primary mechanism for g_lockScreenVisible and menu dismiss.
    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(darwin, NULL, onDarwinLockComplete,
        CFSTR("com.apple.springboard.lockcomplete"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(darwin, NULL, onDarwinUnlocked,
        CFSTR("com.apple.springboard.lockstate"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // ── SpringBoard ─────────────────────────────────────────────────────────────
    Class sbClass = objc_getClass("SpringBoard");
    if (sbClass) {
        Method mFinish = class_getInstanceMethod(sbClass, @selector(applicationDidFinishLaunching:));
        if (mFinish)
            MSHookMessageEx(sbClass,
                @selector(applicationDidFinishLaunching:),
                (IMP)hook_applicationDidFinishLaunching,
                &orig_applicationDidFinishLaunching);

        Method mHome = class_getInstanceMethod(sbClass, @selector(isShowingHomescreen));
        if (mHome)
            MSHookMessageEx(sbClass,
                @selector(isShowingHomescreen),
                (IMP)hook_isShowingHomescreen,
                &orig_isShowingHomescreen);
    }

    // ── SBLockScreenManager — 6 hooks (IDA confirmed) ──────────────────────────
    // On iOS 16 the lifecycle selectors may not exist; class_getInstanceMethod
    // guards ensure no crash. Darwin notifications (above) are the fallback.
    Class lsmClass = objc_getClass("SBLockScreenManager");
    if (lsmClass) {
        Method m;
        m = class_getInstanceMethod(lsmClass, @selector(lockScreenViewControllerWillDismiss));
        if (m) MSHookMessageEx(lsmClass,
            @selector(lockScreenViewControllerWillDismiss),
            (IMP)hook_lockScreenWillDismiss, &orig_lockScreenWillDismiss);

        m = class_getInstanceMethod(lsmClass, @selector(lockScreenViewControllerWillPresent));
        if (m) MSHookMessageEx(lsmClass,
            @selector(lockScreenViewControllerWillPresent),
            (IMP)hook_lockScreenWillPresent, &orig_lockScreenWillPresent);

        m = class_getInstanceMethod(lsmClass, @selector(lockScreenViewControllerDidPresent));
        if (m) MSHookMessageEx(lsmClass,
            @selector(lockScreenViewControllerDidPresent),
            (IMP)hook_lockScreenDidPresent, &orig_lockScreenDidPresent);

        m = class_getInstanceMethod(lsmClass, @selector(_isPasscodeVisible));
        if (m) MSHookMessageEx(lsmClass,
            @selector(_isPasscodeVisible),
            (IMP)hook_isPasscodeVisible, &orig_isPasscodeVisible);

        m = class_getInstanceMethod(lsmClass, @selector(isLockScreenActive));
        if (m) MSHookMessageEx(lsmClass,
            @selector(isLockScreenActive),
            (IMP)hook_isLockScreenActive, &orig_isLockScreenActive);

        m = class_getInstanceMethod(lsmClass, @selector(setPasscodeVisible:animated:));
        if (m) MSHookMessageEx(lsmClass,
            @selector(setPasscodeVisible:animated:),
            (IMP)hook_setPasscodeVisible, &orig_setPasscodeVisible);
    }

    // ── SBDashBoardLockScreenEnvironment — volume + lock buttons (iOS 15) ───────
    // Class does not exist on iOS 16; null check handles gracefully.
    // dashVolumeHooked tracks whether we hooked volume here — if not, we try
    // the iOS 16 SpringBoard fallback below.
    Class dashClass = objc_getClass("SBDashBoardLockScreenEnvironment");
    BOOL dashVolumeHooked = NO;
    if (dashClass) {
        Method mUp = class_getInstanceMethod(dashClass, @selector(handleVolumeUpButtonPress));
        if (mUp) {
            MSHookMessageEx(dashClass,
                @selector(handleVolumeUpButtonPress),
                (IMP)hook_handleVolumeUp, &orig_handleVolumeUp);
            dashVolumeHooked = YES;
        }
        Method mDown = class_getInstanceMethod(dashClass, @selector(handleVolumeDownButtonPress));
        if (mDown)
            MSHookMessageEx(dashClass,
                @selector(handleVolumeDownButtonPress),
                (IMP)hook_handleVolumeDown, &orig_handleVolumeDown);

        Method mLock = class_getInstanceMethod(dashClass, @selector(handleLockButtonPress));
        if (mLock)
            MSHookMessageEx(dashClass,
                @selector(handleLockButtonPress),
                (IMP)hook_handleLockButton, &orig_handleLockButton);
    }

    // ── iOS 16 volume fallback: SpringBoard volumeUpButtonDown: / volumeDownButtonDown: ──
    // Only installed when the SBDashBoardLockScreenEnvironment selectors were absent,
    // preventing double-counting on iOS 15 where both call paths might fire.
    if (!dashVolumeHooked) {
        Class sbCls = objc_getClass("SpringBoard");
        if (sbCls) {
            Method mUp16 = class_getInstanceMethod(sbCls, @selector(volumeUpButtonDown:));
            if (mUp16)
                MSHookMessageEx(sbCls,
                    @selector(volumeUpButtonDown:),
                    (IMP)hook_sb_volumeUpDown, &orig_sb_volumeUpDown);

            Method mDown16 = class_getInstanceMethod(sbCls, @selector(volumeDownButtonDown:));
            if (mDown16)
                MSHookMessageEx(sbCls,
                    @selector(volumeDownButtonDown:),
                    (IMP)hook_sb_volumeDownDown, &orig_sb_volumeDownDown);
        }
    }

    // ── FBSOrientationUpdate — pure passthrough ─────────────────────────────────
    // Low-level FrontBoard class; stable across iOS 15 and 16.
    Class fbsClass = objc_getClass("FBSOrientationUpdate");
    if (fbsClass) {
        Method m = class_getInstanceMethod(fbsClass,
            @selector(initWithOrientation:sequenceNumber:duration:rotationDirection:));
        if (m)
            MSHookMessageEx(fbsClass,
                @selector(initWithOrientation:sequenceNumber:duration:rotationDirection:),
                (IMP)hook_fbsOrientationUpdateInit, &orig_fbs_orientationInit);
    }

    // ── BWAmbientLightSensor — fixed lux values (IDA sub_86A00 / sub_86A20) ─────
    Class luxClass = objc_getClass("BWAmbientLightSensor");
    if (luxClass) {
        Method mLux = class_getInstanceMethod(luxClass, @selector(luxLevel));
        if (mLux)
            MSHookMessageEx(luxClass,
                @selector(luxLevel),
                (IMP)hook_luxLevel, &orig_luxLevel);

        Method mRear = class_getInstanceMethod(luxClass, @selector(rearLuxLevel));
        if (mRear)
            MSHookMessageEx(luxClass,
                @selector(rearLuxLevel),
                (IMP)hook_rearLuxLevel, &orig_rearLuxLevel);
    }
}

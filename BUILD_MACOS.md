# Building VCAMVIP on macOS 15 (Sequoia)

Targets: iOS 15.x and iOS 16.x · Architectures: arm64 + arm64e  
Host: macOS 15.6 · Xcode 16 · Theos at `/opt/theos`

---

## Why macOS is better than WSL

| | WSL (current) | macOS |
|---|---|---|
| arm64e support | No — AutoPatches.dylib workaround | Yes — native clang |
| NTFS permissions | Must build in /tmp | Build anywhere |
| iOS SDKs | 15.6 only | All SDKs via Theos |
| dpkg-deb | Available in apt | `brew install dpkg` |

---

## 1. Prerequisites

```bash
# 1. Install Xcode 16 from the App Store (includes clang, lipo, otool, SDK)
xcode-select --install

# 2. Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3. Build tools
brew install dpkg ldid

# Verify
clang --version          # should say Apple clang 16.x
dpkg-deb --version
ldid                     # prints usage
```

---

## 2. Install Theos

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
# Installs to /opt/theos by default
# Includes: substrate.h, CydiaSubstrate.framework stubs, iOS SDKs, make wrappers
```

After install, verify:
```bash
ls /opt/theos/sdks/          # should list iPhoneOS SDKs
ls /opt/theos/vendor/lib/    # should contain CydiaSubstrate.framework
```

---

## 3. Makefile changes

Open `VCAMVIP_theos/Makefile` and make two changes:

### 3a. SDK target (required)

```makefile
# BEFORE (WSL — iOS 15.6 SDK from Xcode 13/14)
export TARGET = iphone:clang:15.6:14.0

# AFTER (macOS — uses whatever SDK Xcode 16 ships, deployment target stays 14.0)
export TARGET = iphone:clang:latest:14.0
```

Xcode 16 ships iOS 18 SDK. The string `latest` tells Theos to use the highest available SDK.  
Deployment target `14.0` means the binary still runs on iOS 14.0+.

### 3b. Architecture (required for true arm64e)

```makefile
# BEFORE (WSL — arm64 only because Linux clang cannot produce arm64e)
export ARCHS = arm64

# AFTER (macOS — native clang supports both)
export ARCHS = arm64 arm64e
```

This produces fat binaries. No `AutoPatches.dylib` workaround needed.  
The `Architecture: iphoneos-arm64e` line in `control` stays the same — it already covers both.

---

## 4. Build procedure

```bash
#!/bin/bash
# Run this in macOS Terminal (not WSL)
set -e

VERSION="3.00"          # change for each build
PROJ="$HOME/Desktop/VCAMVIP2"
BUILD="/tmp/build_v${VERSION}"

# 1. Fresh build directory
rm -rf "$BUILD"
mkdir -p "$BUILD"

# 2. Copy source (no NTFS permission issues on macOS)
cp -r "$PROJ/VCAMVIP_theos"           "$BUILD/VCAMVIP_theos"
cp -r "$PROJ/vcamera_source"          "$BUILD/vcamera_source"
cp -r "$PROJ/BINFlashAddon_source"    "$BUILD/BINFlashAddon_source"
cp -r "$PROJ/BINFlashCamera_source"   "$BUILD/BINFlashCamera_source"
cp -r "$PROJ/NetHelper_source"        "$BUILD/NetHelper_source"

# 3. Clear Theos object cache (MANDATORY — stale .o causes wrong binary)
rm -rf "$BUILD/VCAMVIP_theos/.theos"

# 4. Build
cd "$BUILD/VCAMVIP_theos"
THEOS=/opt/theos make package THEOS_PACKAGE_SCHEME=rootless

# 5. Copy .deb to Desktop
cp packages/*.deb "$PROJ/"
echo "Done: $PROJ/com.cam.chmp4_${VERSION}_iphoneos-arm64e.deb"
```

Save as `build.sh` on the Desktop and run with `bash ~/Desktop/build.sh`.

---

## 5. Verify the output

```bash
DEB="$HOME/Desktop/VCAMVIP2/com.cam.chmp4_3.00_iphoneos-arm64e.deb"

# Check architectures — must show arm64 AND arm64e
dpkg-deb -x "$DEB" /tmp/chk
lipo -archs /tmp/chk/var/jb/Library/MobileSubstrate/DynamicLibraries/vcamera.dylib
# Expected: arm64 arm64e

# Check version string is correct
strings /tmp/chk/var/jb/Library/MobileSubstrate/DynamicLibraries/vcamera.dylib | grep "v3"

# Check CydiaSubstrate load command present (required — no Sileo patcher dialog)
otool -L /tmp/chk/var/jb/Library/MobileSubstrate/DynamicLibraries/vcamera.dylib | grep CydiaSubstrate
# Expected: @rpath/CydiaSubstrate.framework/CydiaSubstrate

# Check deb contents
dpkg-deb -c "$DEB"

rm -rf /tmp/chk
```

---

## 6. SDK availability notes

Xcode 16 (macOS 15) ships iOS 18 SDK by default. The `latest` keyword in TARGET uses it.

The deployment target (`14.0`) controls which OS APIs are available at runtime:
- No `@available` guards needed for anything that exists on iOS 14+
- For APIs that differ between iOS 15 and iOS 16 (e.g. SpringBoard class names), the existing `class_getInstanceMethod` null-checks in `SpringBoardHooks.m` are sufficient — they already guard against missing classes at runtime on both versions

There is no need to install a separate iOS 15.6 SDK on macOS. The iOS 18 SDK + deployment target 14.0 compiles the same source code. Runtime behavior is determined by the actual device OS, not the SDK version.

---

## 7. iOS 15 vs iOS 16 runtime compatibility

The same binary handles both OS versions via existing guards in the source:

| Hook | iOS 15 | iOS 16 | Guard |
|---|---|---|---|
| `SBDashBoardLockScreenEnvironment` | Present | Removed | `class_getInstanceMethod` null check |
| `SBLockScreenManager` | Present | Present (different selectors) | `class_getInstanceMethod` null checks on each method |
| Lock state via Darwin notify | `com.apple.springboard.lockcomplete` | same | registered for all versions |
| `applicationDidFinishLaunching:` | Standard | Standard | No guard needed |
| `hook_luxLevel` return type `NSInteger` | Works | Works | IDA-confirmed integer return |

No separate dylib or `.plist` filter required. One binary, both OS versions.

---

## 8. Differences from WSL build output

| | WSL (arm64 only) | macOS (fat) |
|---|---|---|
| vcamera.dylib | 638 KB arm64 | ~1.0 MB fat |
| Requires AutoPatches.dylib | Yes (`.roothidepatch` symlinks in prerm) | No — but symlinks harmless if kept |
| `.deb` size (estimated) | ~220 KB | ~350 KB |
| Sileo RootHide patcher dialog | Not shown (CydiaSubstrate dep present) | Not shown |

---

## 9. Troubleshooting

**`make: xcrun: No such file or directory`**  
→ Run `xcode-select --install` and accept the license: `sudo xcodebuild -license`

**`error: SDK "iphone" not found`**  
→ Theos can't find the iOS SDK. Check `/opt/theos/sdks/` exists and contains `iPhoneOS*.sdk`  
→ Re-run the Theos install script

**`dpkg-deb: error: control directory has bad permissions`**  
→ You built from a path on an NTFS volume (e.g. directly from `/mnt/c/` in WSL). Use the `/tmp/` copy procedure above. On macOS this error never occurs.

**Sileo still shows patcher dialog after installing fat binary**  
→ Check `otool -L vcamera.dylib | grep CydiaSubstrate` — must be present  
→ Check `lipo -archs vcamera.dylib` — must include `arm64e`  
→ If arm64e is missing, verify the Makefile `ARCHS = arm64 arm64e` change was applied before copying to `/tmp/`

**`ld: symbol not found` for MSHookMessageEx / MSHookFunction**  
→ Ensure `-framework CydiaSubstrate` is in `vcamera_LDFLAGS` and `NetHelper_LDFLAGS` in the Makefile (already present in current Makefile)

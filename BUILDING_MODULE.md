# BUILDING_MODULE.md — Correct Build Instructions

> MANDATORY: Read this file before every build. Do not deviate from this procedure.

---

## Environment

- **Build host:** Windows 11, WSL (default distro)
- **Theos path:** `/opt/theos` (NOT `/home/builduser/theos`)
- **SDK:** `iPhoneOS15.6.sdk` (lives at `/opt/theos/sdks/iPhoneOS15.6.sdk`)
- **Makefile TARGET:** `iphone:clang:15.6:14.0` — do NOT change this
- **Windows drive in WSL:** `/mnt/c/`
- **Project root on Windows:** `C:\Users\Hello\Desktop\VCAMVIP2\`
- **Project root in WSL:** `/mnt/c/Users/Hello/Desktop/VCAMVIP2/`

---

## Build Command

```bash
wsl -- bash -c "bash /mnt/c/Users/Hello/Desktop/VCAMVIP2/build_vXXX.sh 2>&1"
```

---

## Build Script Template

Write a script named `build_vXXX.sh` (where XXX = version) at the project root, then invoke it via WSL. Template:

```bash
#!/bin/bash
set -e
PROJ=/mnt/c/Users/Hello/Desktop/VCAMVIP2
rm -rf /tmp/build_vXXX
mkdir -p /tmp/build_vXXX
cp -r "$PROJ/VCAMVIP_theos"    /tmp/build_vXXX/VCAMVIP_theos
cp -r "$PROJ/vcamera_source"   /tmp/build_vXXX/vcamera_source
cp -r "$PROJ/NetHelper_source" /tmp/build_vXXX/NetHelper_source
rm -rf /tmp/build_vXXX/VCAMVIP_theos/.theos
echo "=== copy done ==="
cd /tmp/build_vXXX/VCAMVIP_theos
THEOS=/opt/theos ARCHS=arm64 make package THEOS_PACKAGE_SCHEME=rootless 2>&1
echo "=== build done ==="
NEWEST_DEB=$(ls -t packages/*.deb | head -1)
echo "=== package: $NEWEST_DEB ==="
dpkg-deb -x "$NEWEST_DEB" /tmp/verify_vXXX
strings /tmp/verify_vXXX/var/jb/Library/MobileSubstrate/DynamicLibraries/vcamera.dylib | grep CHMP
echo "=== verified ==="
cp "$NEWEST_DEB" /mnt/c/Users/Hello/Desktop/com.cam.chmp4_X.XX_iphoneos-arm64.deb
echo "=== copied to Desktop ==="
```

---

## Rules

1. **Always copy to `/tmp/`** — building directly from `/mnt/c/` fails at `dpkg-deb` due to NTFS permissions (777).
2. **Always delete `.theos/` cache** before build — stale `.o` files cause wrong binaries to ship silently.
3. **`VCAMVIP_theos` must be a sibling of `vcamera_source`** in the temp dir — the Makefile uses `../vcamera_source/` relative paths.
4. **THEOS=/opt/theos** — not `/home/builduser/theos`, not `/opt/theos2`, not anything else.
5. **Do NOT change `TARGET = iphone:clang:15.6:14.0`** in the Makefile — the SDK exists and works.
6. **Always pass `ARCHS=arm64` explicitly** on the make command line — arm64 only. Do not rely on the Makefile export alone.
   NOTE — arm64e: Ubuntu clang 14 (the toolchain used here) cannot produce true arm64e code. Attempting `ARCHS="arm64 arm64e"` causes BOTH slices to compile as arm64, then `lipo` fails with "same architecture". arm64e requires Apple's LLVM (only in Xcode on macOS). arm64e compatibility on A12+ devices is handled at runtime by RootHide AutoPatches.dylib via the `.roothidepatch` symlinks shipped in the deb.
   NOTE — Logos race: if fat builds ever become possible, use `make -j1` to avoid a race where arm64 and arm64e Logos preprocessing both resolve `../vcamera_source/Tweak/Tweak.x.m` to the same intermediate path and collide.
7. **Auto-find the newest deb** with `ls -t packages/*.deb | head -1` — never hardcode the filename.
8. **Always verify** by extracting the deb and checking `strings vcamera.dylib | grep CHMP` matches the new version.
9. **Copy to Desktop** at `/mnt/c/Users/Hello/Desktop/` — not to the project directory.
10. **Bump version** in `VCAMVIP_theos/control` AND update version string in `vcamera_source/UI/VCamMenuViewController.m` before building.
8. **Clean up NTFS reparse points** if `cp` fails with symlink errors: run PowerShell `Remove-Item` on any `C:*` directories inside `VCAMVIP_theos` before copying.

---

## Pre-build NTFS Reparse Point Cleanup (if needed)

If `cp` fails with "cannot create symbolic link" errors, run this in PowerShell first:

```powershell
$base = "C:\Users\Hello\Desktop\VCAMVIP2\VCAMVIP_theos"
Get-ChildItem -Path $base -Recurse -Attributes ReparsePoint -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue }
Get-ChildItem -Path $base -Directory | Where-Object { $_.Name -like "C:*" } |
    ForEach-Object { Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue }
```

These are leftover Theos packaging artifacts (staging symlinks with Windows absolute paths). They are safe to delete.

---

## Verify Build

```bash
wsl -- bash -c "dpkg-deb -x /mnt/c/Users/Hello/Desktop/com.cam.chmp4_X.XX_iphoneos-arm64.deb /tmp/chkXXX && strings /tmp/chkXXX/var/jb/Library/MobileSubstrate/DynamicLibraries/vcamera.dylib | grep -i 'v2\.\|CHMP'"
```

Expected output: `v2.XX-VCAM` (the version label string from VCamMenuViewController.m).
Note: the version string is `v2.XX-VCAM`, not `CHMP-X.XX`. The build script's verify step uses `grep -i "v2\.\|CHMP"` to match either format.

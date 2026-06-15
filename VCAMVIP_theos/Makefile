# VCAMVIP — Theos Makefile
# Devices : arm64 (A10–A11: iPhone 7/8/X) and arm64e (A12+: XS/XR/11/12/13/14/SE2/SE3)
# iOS     : 15.x and 16.x (Dopamine RootHide — rootless, paths under /var/jb/)
# Hook lib: ElleKit (MSHookMessageEx/MSHookFunction compatible with substrate.h API)
#
# NOTE: This Linux build system uses Ubuntu clang 14 which cannot produce true arm64e code.
#       We build arm64 only. RootHide AutoPatches.dylib (loaded via .roothidepatch symlinks
#       shipped in the deb) handles arm64e compatibility on A12+ devices automatically.
#       Architecture in control is iphoneos-arm64e so Sileo shows the package to all devices.

export THEOS_PACKAGE_SCHEME = rootless
export TARGET               = iphone:clang:15.6:14.0
export ARCHS                = arm64

INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

# ═══════════════════════════════════════════════════════════════
# vcamera.dylib
# Injects into: mediaserverd, lskdd, SpringBoard
# Includes BINFlash camera effect + UI (merged from BINFlashCamera + BINFlashAddon)
# ═══════════════════════════════════════════════════════════════
TWEAK_NAME += vcamera

vcamera_FILES = \
	../vcamera_source/Tweak/Tweak.x \
	../vcamera_source/Hooks/MediaServerHooks.m \
	../vcamera_source/Hooks/SpringBoardHooks.m \
	../vcamera_source/VCamBridge/VCamBridge.m \
	../vcamera_source/VCamLive/VCamLiveManager.m \
	../vcamera_source/Network/ServerSocket.m \
	../vcamera_source/Network/VCamClientSocket.m \
	../vcamera_source/Network/VCamNetworkRequest.m \
	../vcamera_source/UI/VCamMenuViewController.m \
	../vcamera_source/UI/VCamFloatButton.m \
	../vcamera_source/UI/VCamColorDot.m \
	../vcamera_source/UI/VCamColorPickerWindow.m \
	../vcamera_source/UI/VCamColorSampleListener.m \
	../vcamera_source/UI/VCamManualPadWindow.m \
	../vcamera_source/H264Decoder/H264Decoder.m \
	../vcamera_source/RTMP/RTMPServer.m \
	../vcamera_source/RTMP/RTMPServerCXX.mm \
	../vcamera_source/RTMP/TCPServer.cpp \
	../vcamera_source/RTMP/DataLayer.cpp \
	../vcamera_source/RTMP/librtmp/AMF.cpp \
	../vcamera_source/RTMP/librtmp/RTMPEndpoint.cpp \
	../vcamera_source/RTMP/librtmp/RTMPServerSession.cpp \
	../vcamera_source/BINFlash/BINFlashPrefs.m \
	../vcamera_source/BINFlash/BINFlashPixelEffect.m \
	../vcamera_source/BINFlash/BINFlashFaceRegion.m \
	../vcamera_source/BINFlash/BINFlashCameraHooks.m \
	../vcamera_source/BINFlash/BINFlashColorBar.m \
	../vcamera_source/Vendor/GPUImage/GLProgram.m \
	../vcamera_source/Vendor/GPUImage/GPUImageBoxBlurFilter.m \
	../vcamera_source/Vendor/GPUImage/GPUImageFilter.m \
	../vcamera_source/Vendor/GPUImage/GPUImageFilterGroup.m \
	../vcamera_source/Vendor/GPUImage/GPUImageFramebuffer.m \
	../vcamera_source/Vendor/GPUImage/GPUImageFramebufferCache.m \
	../vcamera_source/Vendor/GPUImage/GPUImageGaussianBlurFilter.m \
	../vcamera_source/Vendor/GPUImage/GPUImageOutput.m \
	../vcamera_source/Vendor/GPUImage/GPUImageRawDataInput.m \
	../vcamera_source/Vendor/GPUImage/GPUImageRawDataOutput.m \
	../vcamera_source/Vendor/GPUImage/GPUImageSharpenFilter.m \
	../vcamera_source/Vendor/GPUImage/GPUImageTextureInput.m \
	../vcamera_source/Vendor/GPUImage/GPUImageTextureOutput.m \
	../vcamera_source/Vendor/GPUImage/GPUImageThreeInputFilter.m \
	../vcamera_source/Vendor/GPUImage/GPUImageTwoInputFilter.m \
	../vcamera_source/Vendor/GPUImage/GPUImageTwoPassFilter.m \
	../vcamera_source/Vendor/GPUImage/GPUImageTwoPassTextureSamplingFilter.m \
	../vcamera_source/Vendor/GPUImageBeauty/GPUImageBoxDifferenceFilter.m \
	../vcamera_source/Vendor/GPUImageBeauty/GPUImageBoxHighPassFilter.m \
	../vcamera_source/Vendor/GPUImageBeauty/GPUImageBaseBeautyFaceFilter.m \
	../vcamera_source/Vendor/GPUImageBeauty/GPUImageBeautyFaceFilter.m \
	../vcamera_source/Vendor/GPUImageBeauty/GPUImageThinFaceFilter.m \
	../vcamera_source/Vendor/GPUImage/GPUImageContext.m \
	../vcamera_source/Vendor/GPUImage/GPUImageMovieWriter.m \
	../vcamera_source/Vendor/GPUImage/GPUImagePicture.m \
	../vcamera_source/Vendor/GPUImage/GPUImagePicture+TextureSubimage.m \
	../vcamera_source/Vendor/GPUImage/GPUImageView.m

vcamera_FRAMEWORKS = \
	Foundation UIKit CoreMedia CoreVideo VideoToolbox \
	AVFoundation CoreFoundation Security OpenGLES QuartzCore CoreGraphics CoreImage Vision IOSurface

vcamera_LDFLAGS = -lMobileGestalt -lc++ -undefined dynamic_lookup -framework CydiaSubstrate

vcamera_CFLAGS = \
	-fno-objc-arc \
	-O0 \
	-fstack-protector-all \
	-funwind-tables \
	-DGLES_SILENCE_DEPRECATION \
	-Wno-objc-missing-super-calls \
	-Wno-deprecated-declarations \
	-Wno-unused-property-ivar \
	-Wno-error \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source/include \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source/RTMP \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source/H264Decoder \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source/Network \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source/UI \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source/BINFlash \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source/Vendor/GPUImage \
	-I$(THEOS_PROJECT_DIR)/../vcamera_source/Vendor/GPUImageBeauty

vcamera_CCFLAGS = $(vcamera_CFLAGS) -std=c++14

# ═══════════════════════════════════════════════════════════════
# NetHelper.dylib
# Injects into: mediaserverd, SpringBoard
# ═══════════════════════════════════════════════════════════════
TWEAK_NAME += NetHelper

NetHelper_FILES = \
	../NetHelper_source/Tweak/Tweak.x \
	../NetHelper_source/Hooks/NetHelperHooks.m

NetHelper_FRAMEWORKS = Foundation CoreFoundation

NetHelper_CFLAGS = \
	-fno-objc-arc \
	-O0 \
	-fstack-protector-all \
	-funwind-tables \
	-fexceptions \
	-I$(THEOS_PROJECT_DIR)/../NetHelper_source \
	-I$(THEOS_PROJECT_DIR)/../NetHelper_source/Hooks

NetHelper_LDFLAGS = -undefined dynamic_lookup -framework CydiaSubstrate

NetHelper_CCFLAGS = $(NetHelper_CFLAGS)

# ═══════════════════════════════════════════════════════════════
include $(THEOS_MAKE_PATH)/tweak.mk

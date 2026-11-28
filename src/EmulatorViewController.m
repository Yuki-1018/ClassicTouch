//
// ClassicTouch - Native Classic iOS Emulator for Modern iOS & iPadOS
//
// Copyright (c) 2026 ClassicTouch Authors.
// SPDX-License-Identifier: GPL-2.0-only
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; version 2 of the License.
//

#import "EmulatorViewController.h"
#import "ios_metal_view.h"
#import "AndroidMetalView.h"
#import "ios_audio_bridge.h"
#import "ios_motion_manager.h"
#import "ios_jit_helper.h"
#import "ios_bootrom_helper.h"
#import "ios_winrt_media_probe.h"
#import "ios_network_proxy.h"
#import "ios_usb_mux.h"
#import "ios_ipa_installer.h"
#import "adb/ADBClient.h"
#import "ios_guest_tools.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>

extern int lighttouch_android_ensure_cache(const char *cache_path, const char *system_path);
#include <pthread.h>
#include <pthread/qos.h>
#include <stdbool.h>
#include <stdlib.h>
#include <time.h>
#include <zlib.h>

#if __has_include("lighttouch.h")
#import "lighttouch.h"

static BOOL ClassicITPackCoversDevice(NSString *path, NSString *boardStr, NSString *buildStr) {
    NSArray<NSDictionary *> *entries = nil;
    NSData *payload = ClassicInflateITPack(path, &entries);
    if (!payload || !entries) return NO;
    uint64_t total = payload.length;

    NSMutableString *major = [NSMutableString string];
    for (NSUInteger i = 0; i < buildStr.length; i++) {
        unichar ch = [buildStr characterAtIndex:i];
        if (ch >= '0' && ch <= '9') [major appendFormat:@"%C", ch];
        else break;
    }
    NSString *majorWildcard = major.length > 0 ? [major stringByAppendingString:@"*"] : nil;

    uint64_t offset = 0;
    const uint8_t *raw = (const uint8_t *)payload.bytes;
    for (NSDictionary *e in entries) {
        NSUInteger sz = (NSUInteger)[e[@"size"] unsignedLongLongValue];
        NSString *name = [e[@"name"] isKindOfClass:[NSString class]] ? e[@"name"] : @"";
        if (offset + sz > total) break;
        if ([name hasSuffix:@"/manifest.json"]) {
            NSData *mData = [NSData dataWithBytesNoCopy:(void *)(raw + offset) length:sz freeWhenDone:NO];
            NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:mData options:0 error:nil];
            if ([manifest isKindOfClass:[NSDictionary class]] && ![manifest[@"stub"] boolValue]) {
                NSDictionary *req = [manifest[@"requires"] isKindOfClass:[NSDictionary class]] ? manifest[@"requires"] : nil;
                NSArray *boards = [req[@"boards"] isKindOfClass:[NSArray class]] ? req[@"boards"] : nil;
                NSArray *builds = [req[@"builds"] isKindOfClass:[NSArray class]] ? req[@"builds"] : nil;
                if ([boards containsObject:boardStr] &&
                    ([builds containsObject:buildStr] || (majorWildcard && [builds containsObject:majorWildcard]))) {
                    return YES;
                }
            }
        }
        offset += sz;
    }
    return NO;
}

static NSString *ClassicLocateGuestPackage(const char *board, const char *build) {
    NSString *boardStr = board && *board ? [NSString stringWithUTF8String:board] : @"";
    NSString *buildStr = build && *build ? [NSString stringWithUTF8String:build] : @"";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleTools = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"guest-tools"];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *docTools = [docs stringByAppendingPathComponent:@"guest-tools"];
    NSArray<NSString *> *dirs = bundleTools ? @[bundleTools, docTools] : @[docTools];

    for (NSString *dir in dirs) {
        NSArray<NSString *> *files = [[fm contentsOfDirectoryAtPath:dir error:nil]
                                      sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *f in files) {
            if (![f.pathExtension isEqualToString:@"itpack"] || [f isEqualToString:@"host-tools.itpack"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:f];
            if (boardStr.length > 0 && buildStr.length > 0 && ClassicITPackCoversDevice(full, boardStr, buildStr)) {
                return full;
            }
        }
    }
    // Never force an unmatched .itpack onto builds that have no manifest entry (e.g., 1.x m68ap-1A543a);
    // passing a non-matching package makes lt::guest_offer throw LT_UNSUPPORTED before QEMU starts.
    return nil;
}
#endif

#define L(key) NSLocalizedString((key), nil)

typedef NS_ENUM(NSInteger, ClassicMenuPositionMode) {
    ClassicMenuPositionAutoBottom = 0,
    ClassicMenuPositionAutoTop,
    ClassicMenuPositionCustom
};

@protocol ClassicDisplayView <NSObject>
@property (nonatomic, weak) id<IOSMetalViewDelegate> touchDelegate;
@property (nonatomic, copy) void (^onTouchEvent)(int touchId, int phase, float x, float y);
@property (nonatomic, copy) void (^onZoomChanged)(CGFloat scale, CGPoint offset);
@property (nonatomic, assign, readonly) double fps;
@property (nonatomic, assign, readonly) NSUInteger totalFramesRendered;
@property (nonatomic, assign) NSInteger displayRotationDegrees;
@property (nonatomic, assign) BOOL zoomModeEnabled;
@property (nonatomic, assign) CGFloat zoomScale;
@property (nonatomic, assign) CGPoint panOffset;
- (CGRect)activeScreenRect;
- (void)resetZoom;
- (void)purgeTextureCaches;
- (void)updateFramePixels:(const void *)bgraPixels width:(int)w height:(int)h stride:(int)stride;
@end

@interface IOSMetalView (ClassicDisplay) <ClassicDisplayView>
@end

@interface AndroidMetalView (ClassicDisplay) <ClassicDisplayView>
@end

@interface EmulatorViewController () <IOSMotionManagerDelegate, UIDocumentPickerDelegate> {
@public
    pthread_t _emulatorThread;
    BOOL _isEmulating;
    BOOL _threadExited;
    BOOL _forceStopRequested;
    BOOL _isStopping;
    UIImpactFeedbackGenerator *_haptic;
    UIView *_shutdownOverlay;
    UIButton *_forceStopButton;
    void (^_shutdownCompletion)(void);

    lt_device *_device;
    lt_runtime *_runtime;
    uint64_t _lastFrameSeq;

    BOOL _isAndroidMode;
    void *_androidEngineHandle;
    _Atomic BOOL _androidQemuExited;
    int _androidTouchSlots[5];
    FILE *_androidSerialFile;
    int (*_pfnAndroidMain)(int argc, char **argv);
    void (*_pfnAndroidConfigureImages)(const char *sys, const char *usr, const char *cac);
    void (*_pfnAndroidConfigureDisplay)(int width, int height, int dpi);
    void (*_pfnAndroidAddProp)(const char *name, const char *val);
    void (*_pfnAndroidSetFrameCb)(void (*cb)(void *, int, int, int, const void *), void *);
    void (*_pfnAndroidSetDirtyFrameCb)(void (*cb)(void *, int, int, int, int, int, int, int, const void *), void *);
    void (*_pfnAndroidSetLogCb)(void (*cb)(void *, const char *, size_t), void *);
    IOSMetalView *_iosMetalView;
    AndroidMetalView *_androidMetalView;
    void (*_pfnAndroidTouch)(int slot, int x, int y, int down);
    void (*_pfnAndroidButton)(int keycode, int down);
    void (*_pfnAndroidAccel)(float x, float y, float z);
    int (*_pfnAndroidAudioPull)(int16_t *out, int max_frames, int *rate, int *ch);
    void (*_pfnAndroidSync)(void);
    void (*_pfnAndroidQuit)(void);

    BOOL _isWinRTMode;
    BOOL _isChromeOSMode;
    BOOL _isUbuntuTouchVirtMode;
    void *_winrtEngineHandle;
    _Atomic BOOL _winrtQemuExited;
    FILE *_winrtSerialFile;
    int (*_pfnWinrtMain)(int argc, char **argv);
    void (*_pfnWinrtSetFrameCb)(void (*cb)(void *, int, int, int, const void *), void *);
    void (*_pfnWinrtSetDirtyFrameCb)(void (*cb)(void *, int, int, int, int, int, int, int, const void *), void *);
    void (*_pfnWinrtPointerAbs)(int x, int y, int buttons);
    void (*_pfnWinrtTouch)(int slot, int x, int y, int phase);
    void (*_pfnWinrtScroll)(int wheel_delta);
    void (*_pfnWinrtKeyQcode)(int qcode, int down);
    void (*_pfnWinrtSendCad)(void);
    void (*_pfnWinrtResetUsb)(void);
    int (*_pfnWinrtAudioPull)(int16_t *out, int max_frames, int *rate, int *ch);
    void (*_pfnWinrtSync)(void);
    void (*_pfnWinrtQuit)(void);

    int _winrtActiveTouches[5];
    int _utTouchSlots[10];
    float _winrtTouchX[5];
    float _winrtTouchY[5];
    NSTimeInterval _winrtTwoFingerStartTime;
    float _winrtTwoFingerLastY;
    BOOL _winrtTwoFingerScrolled;
    BOOL _winrtMouseMode;
    float _winrtCursorX;
    float _winrtCursorY;
    float _winrtTrackLastX;
    float _winrtTrackLastY;
    float _winrtTrackStartX;
    float _winrtTrackStartY;
    NSTimeInterval _winrtTrackStartTime;
    NSTimeInterval _winrtLastTapUpTime;
    BOOL _winrtTrackMoved;
    BOOL _winrtTrackLeftDrag;
    BOOL _winrtMouseDragLock;
    BOOL _winrtTrackRightSent;
    uint64_t _winrtTrackGen;
    BOOL _winrtModCtrl;
    BOOL _winrtModAlt;
    BOOL _winrtModShift;
    BOOL _winrtModWin;

    double _accelX, _accelY, _accelZ;
    double _gyroX, _gyroY, _gyroZ;
    double _lastSentAccelX, _lastSentAccelY, _lastSentAccelZ;
    double _lastSentGyroX, _lastSentGyroY, _lastSentGyroZ;
    BOOL _hasSentMotion;
    uint64_t _lastMotionNs;
    NSInteger _effectiveMotionOri;
    uint64_t _gyroPulseUntilNs;
    double _gyroPulseDirZ;
    BOOL _boardSupportsAccel;
    BOOL _boardSupportsGyro;
    BOOL _homePressActive;
    BOOL _homeLongPressSent;
    uint64_t _homePressGen;
    NSInteger _hostInterfaceOrientation;
    uint64_t _guestPasteboardSerial;
    NSInteger _lastHostPasteboardChangeCount;
    NSString *_lastSyncedPasteboardString;
}

@property (nonatomic, strong) MTKView<ClassicDisplayView> *metalView;
@property (nonatomic, strong) UIView *zoomIndicatorBar;
@property (nonatomic, strong) IOSAudioBridge *audioBridge;
@property (nonatomic, strong) IOSMotionManager *motionManager;
@property (nonatomic, strong) UIVisualEffectView *telemetryCard;
@property (nonatomic, strong) UILabel *telemetryLabel;
@property (nonatomic, strong) UIView *hardwareBar;
@property (nonatomic, strong) UIVisualEffectView *barBlurView;
@property (nonatomic, strong) UIButton *homeButton;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIButton *powerButton;
@property (nonatomic, strong) UIButton *volUpButton;
@property (nonatomic, strong) UIButton *volDownButton;
@property (nonatomic, strong) UIButton *moreMenuButton;
@property (nonatomic, strong) UIButton *winrtInputModeButton;
@property (nonatomic, strong) UIButton *winrtDragButton;
@property (nonatomic, strong) UIButton *winrtKeyboardButton;
@property (nonatomic, strong) UIButton *winrtQuickKeysButton;
@property (nonatomic, strong) UIButton *winrtResetUsbButton;
@property (nonatomic, strong) UIView *winrtKeyInputView;
@property (nonatomic, strong) NSDictionary<NSNumber *, UIButton *> *winrtAccessoryModButtons;
@property (nonatomic, strong) UIButton *hudToggleButton;
@property (nonatomic, strong) UIButton *restartButton;
@property (nonatomic, strong) UIButton *exitButton;
@property (nonatomic, strong) UIButton *collapseButton;
@property (nonatomic, strong) UIStackView *hardwareStack;
@property (nonatomic, strong) NSLayoutConstraint *barLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *barBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *barHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *stackLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *stackTrailingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *collapseWidthConstraint;
@property (nonatomic, assign) BOOL barCollapsed;
@property (nonatomic, assign) BOOL hasInitializedBarPosition;
@property (nonatomic, assign) BOOL userMovedBarManually;
@property (nonatomic, assign) CGFloat savedCollapsedLeading;
@property (nonatomic, assign) BOOL hasSavedCollapsedLeading;
@property (nonatomic, assign) BOOL collapseButtonOnTrailing;
@property (nonatomic, assign) ClassicMenuPositionMode menuPositionMode;
@property (nonatomic, assign) NSUInteger tempHideToken;
@property (nonatomic, assign) CGSize lastLayoutViewSize;
@property (nonatomic, assign) UIEdgeInsets lastLayoutSafeInsets;
@property (nonatomic, assign) BOOL hasLastLayoutGeometry;
@property (nonatomic, assign) BOOL cachedJitAvailable;
@property (nonatomic, strong) CADisplayLink *telemetryTimer;
@property (nonatomic, strong, nullable) NSTimer *clipboardSyncTimer;
@property (atomic, strong, nullable) IOSUsbMuxBridge *usbBridge;
@property (atomic, strong, nullable) AEADBClient *androidAdbClient;
@property (nonatomic, strong, nullable) UIVisualEffectView *ipaProgressCard;
@property (nonatomic, strong, nullable) UILabel *ipaProgressLabel;
@property (nonatomic, strong, nullable) UIProgressView *ipaProgressBar;
@property (nonatomic, strong, nullable) UIButton *ipaCancelButton;
@property (atomic, assign) BOOL ipaInstallInFlight;
@property (atomic, assign) BOOL ipaInstallCancelRequested;

@end

static void s_frame_pixel_listener(void *opaque, const lt_frame_info *info, const void *pixels);
static void s_direct_iosurface_listener(void *opaque, void *iosurface_ref, int w, int h);
static void *emulator_worker_thread(void *arg);
static void *emulator_winrt_worker(EmulatorViewController *vc);

typedef void (*qemu_ios_direct_cb_t)(void *opaque, void *iosurface_ref, int w, int h);
typedef void (*qemu_ios_set_direct_cb_fn)(qemu_ios_direct_cb_t cb, void *opaque);

static void emulator_set_direct_iosurface_cb(qemu_ios_direct_cb_t cb, void *opaque) {
    static qemu_ios_set_direct_cb_fn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (qemu_ios_set_direct_cb_fn)dlsym(RTLD_DEFAULT, "qemu_ios_set_direct_iosurface_callback");
    });
    if (fn) {
        fn(cb, opaque);
    }
}

static int ClassicWinRTQCodeForHIDUsage(UIKeyboardHIDUsage code) {
    if (code >= UIKeyboardHIDUsageKeyboardA && code <= UIKeyboardHIDUsageKeyboardZ) {
        static const int kAlphaQCodes[26] = {
            36, 53, 51, 38, 25, 39, 40, 41, 30, 42, 43, 44, 55,
            54, 31, 32, 23, 26, 37, 27, 29, 52, 24, 50, 28, 49
        };
        return kAlphaQCodes[(int)code - (int)UIKeyboardHIDUsageKeyboardA];
    }
    if (code >= UIKeyboardHIDUsageKeyboard1 && code <= UIKeyboardHIDUsageKeyboard0) {
        return 9 + ((int)code - (int)UIKeyboardHIDUsageKeyboard1);
    }
    if (code >= UIKeyboardHIDUsageKeyboardF1 && code <= UIKeyboardHIDUsageKeyboardF10) {
        return 62 + ((int)code - (int)UIKeyboardHIDUsageKeyboardF1);
    }
    switch (code) {
    case UIKeyboardHIDUsageKeyboardReturnOrEnter: return 35;
    case UIKeyboardHIDUsageKeyboardEscape:        return 8;
    case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: return 21;
    case UIKeyboardHIDUsageKeyboardTab:           return 22;
    case UIKeyboardHIDUsageKeyboardSpacebar:      return 60;
    case UIKeyboardHIDUsageKeyboardHyphen:        return 19;
    case UIKeyboardHIDUsageKeyboardEqualSign:     return 20;
    case UIKeyboardHIDUsageKeyboardOpenBracket:   return 33;
    case UIKeyboardHIDUsageKeyboardCloseBracket:  return 34;
    case UIKeyboardHIDUsageKeyboardBackslash:     return 48;
    case UIKeyboardHIDUsageKeyboardSemicolon:     return 45;
    case UIKeyboardHIDUsageKeyboardQuote:         return 46;
    case UIKeyboardHIDUsageKeyboardGraveAccentAndTilde: return 47;
    case UIKeyboardHIDUsageKeyboardComma:         return 56;
    case UIKeyboardHIDUsageKeyboardPeriod:        return 57;
    case UIKeyboardHIDUsageKeyboardSlash:         return 58;
    case UIKeyboardHIDUsageKeyboardCapsLock:      return 61;
    case UIKeyboardHIDUsageKeyboardF11:           return 92;
    case UIKeyboardHIDUsageKeyboardF12:           return 93;
    case UIKeyboardHIDUsageKeyboardHome:          return 95;
    case UIKeyboardHIDUsageKeyboardPageUp:        return 96;
    case UIKeyboardHIDUsageKeyboardDeleteForward: return 104;
    case UIKeyboardHIDUsageKeyboardEnd:           return 98;
    case UIKeyboardHIDUsageKeyboardPageDown:      return 97;
    case UIKeyboardHIDUsageKeyboardRightArrow:    return 102;
    case UIKeyboardHIDUsageKeyboardLeftArrow:     return 99;
    case UIKeyboardHIDUsageKeyboardDownArrow:     return 101;
    case UIKeyboardHIDUsageKeyboardUpArrow:       return 100;
    case UIKeyboardHIDUsageKeyboardInsert:        return 103;
    case UIKeyboardHIDUsageKeyboardLeftControl:   return 5;
    case UIKeyboardHIDUsageKeyboardRightControl:  return 6;
    case UIKeyboardHIDUsageKeyboardLeftShift:     return 1;
    case UIKeyboardHIDUsageKeyboardRightShift:    return 2;
    case UIKeyboardHIDUsageKeyboardLeftAlt:       return 3;
    case UIKeyboardHIDUsageKeyboardRightAlt:      return 4;
    case UIKeyboardHIDUsageKeyboardLeftGUI:       return 117;
    case UIKeyboardHIDUsageKeyboardRightGUI:      return 118;
    default: return 0;
    }
}

@interface ClassicWinRTKeyInputView : UIView <UIKeyInput>
@property (nonatomic, copy) void (^onKeyQcode)(int qcode, int down);
@property (nonatomic, copy, nullable) void (^onAfterNonModifierKey)(void);
@property (nonatomic, assign) BOOL externalShiftHeld;
@property (nonatomic, strong, nullable) UIView *customInputAccessoryView;
@end

@implementation ClassicWinRTKeyInputView

- (UIView *)inputAccessoryView { return self.customInputAccessoryView; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }

- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }

- (void)tapQCode:(int)q shifted:(BOOL)shifted {
    void (^sendKey)(int, int) = self.onKeyQcode;
    if (!sendKey || q <= 0) return;
    BOOL needLocalShift = shifted && !self.externalShiftHeld;
    if (needLocalShift) sendKey(1, 1);
    sendKey(q, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        sendKey(q, 0);
        if (needLocalShift) sendKey(1, 0);
    });
    if (self.onAfterNonModifierKey) {
        self.onAfterNonModifierKey();
    }
}

- (void)insertText:(NSString *)text {
    if (!self.onKeyQcode || text.length == 0) return;
    static const int kAlpha[26] = {
        36, 53, 51, 38, 25, 39, 40, 41, 30, 42, 43, 44, 55,
        54, 31, 32, 23, 26, 37, 27, 29, 52, 24, 50, 28, 49
    };
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        if (ch >= 'a' && ch <= 'z') {
            [self tapQCode:kAlpha[ch - 'a'] shifted:NO];
        } else if (ch >= 'A' && ch <= 'Z') {
            [self tapQCode:kAlpha[ch - 'A'] shifted:YES];
        } else if (ch >= '1' && ch <= '9') {
            [self tapQCode:(9 + (ch - '1')) shifted:NO];
        } else {
            switch (ch) {
            case '0':  [self tapQCode:18 shifted:NO]; break;
            case ' ':  [self tapQCode:60 shifted:NO]; break;
            case '\n':
            case '\r': [self tapQCode:35 shifted:NO]; break;
            case '\t': [self tapQCode:22 shifted:NO]; break;
            case '-':  [self tapQCode:19 shifted:NO]; break;
            case '_':  [self tapQCode:19 shifted:YES]; break;
            case '=':  [self tapQCode:20 shifted:NO]; break;
            case '+':  [self tapQCode:20 shifted:YES]; break;
            case '[':  [self tapQCode:33 shifted:NO]; break;
            case '{':  [self tapQCode:33 shifted:YES]; break;
            case ']':  [self tapQCode:34 shifted:NO]; break;
            case '}':  [self tapQCode:34 shifted:YES]; break;
            case ';':  [self tapQCode:45 shifted:NO]; break;
            case ':':  [self tapQCode:45 shifted:YES]; break;
            case '\'': [self tapQCode:46 shifted:NO]; break;
            case '"':  [self tapQCode:46 shifted:YES]; break;
            case '`':  [self tapQCode:47 shifted:NO]; break;
            case '~':  [self tapQCode:47 shifted:YES]; break;
            case '\\': [self tapQCode:48 shifted:NO]; break;
            case '|':  [self tapQCode:48 shifted:YES]; break;
            case ',':  [self tapQCode:56 shifted:NO]; break;
            case '<':  [self tapQCode:56 shifted:YES]; break;
            case '.':  [self tapQCode:57 shifted:NO]; break;
            case '>':  [self tapQCode:57 shifted:YES]; break;
            case '/':  [self tapQCode:58 shifted:NO]; break;
            case '?':  [self tapQCode:58 shifted:YES]; break;
            case '!':  [self tapQCode:9 shifted:YES]; break;
            case '@':  [self tapQCode:10 shifted:YES]; break;
            case '#':  [self tapQCode:11 shifted:YES]; break;
            case '$':  [self tapQCode:12 shifted:YES]; break;
            case '%':  [self tapQCode:13 shifted:YES]; break;
            case '^':  [self tapQCode:14 shifted:YES]; break;
            case '&':  [self tapQCode:15 shifted:YES]; break;
            case '*':  [self tapQCode:16 shifted:YES]; break;
            case '(':  [self tapQCode:17 shifted:YES]; break;
            case ')':  [self tapQCode:18 shifted:YES]; break;
            default: break;
            }
        }
    }
}

- (void)deleteBackward {
    [self tapQCode:21 shifted:NO];
}

@end

@implementation EmulatorViewController

- (instancetype)initWithMachineId:(NSString *)machineId
                      machineName:(NSString *)machineName
                     stateDirPath:(NSString *)stateDirPath
                      baseDirPath:(NSString *)baseDirPath {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _machineId = [machineId copy];
        _machineName = [machineName copy];
        _stateDirPath = [stateDirPath copy];
        _baseDirPath = [baseDirPath copy];
        _screenWidth = 320;
        _screenHeight = 480;
        _screenScale = 1;
        _isEmulating = NO;
        _iPadLandscapeRotationEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"ClassicTouch_iPadLandscapeRotate"];
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"ClassicTouch_ClipboardSyncEnabled"] == nil) {
            _clipboardSyncEnabled = YES;
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ClassicTouch_ClipboardSyncEnabled"];
        } else {
            _clipboardSyncEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"ClassicTouch_ClipboardSyncEnabled"];
        }
        _guestPasteboardSerial = 0;
        _lastHostPasteboardChangeCount = [UIPasteboard generalPasteboard].changeCount;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleHostPasteboardChanged:)
                                                     name:UIPasteboardChangedNotification
                                                   object:nil];
        _threadExited = YES;
        _lastFrameSeq = 0;
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    }
    return self;
}

- (NSString *)locateBootromForMachine:(const char *)board {
    NSString *boardStr = (board && *board) ? [NSString stringWithUTF8String:board] : @"";
    NSArray<NSString *> *candidates = nil;
    NSString *romType = nil;

    if ([boardStr isEqualToString:@"n45ap"] || [boardStr isEqualToString:@"m68ap"]) {
        candidates = @[@"bootrom_s5l8900", @"bootrom_s5l8900.bin", @"s5l8900.bin", @"s5l8900-bootrom.bin", @"bootrom.bin"];
        romType = @"s5l8900";
    } else {
        return nil;
    }

    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSArray *searchDirs = @[
        self.baseDirPath ?: @"",
        docDir ?: @"",
        docDir ? [docDir stringByAppendingPathComponent:@"bootroms"] : @"",
        docDir ? [docDir stringByAppendingPathComponent:@"Bootroms"] : @"",
        [[NSBundle mainBundle] bundlePath] ?: @"",
        [[NSBundle mainBundle] resourcePath] ?: @""
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in searchDirs) {
        if (dir.length == 0) continue;
        for (NSString *name in candidates) {
            NSString *candidatePath = [dir stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:candidatePath] && ClassicBootromFileMatchesExpectedType(candidatePath, romType)) {
                return candidatePath;
            }
        }
    }
    return nil;
}

- (NSString *)locateEngineLibrary {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 1. Bundle private frameworks path
    NSString *bundleFrameworks = [[NSBundle mainBundle] privateFrameworksPath];
    if (bundleFrameworks) {
        NSString *p = [bundleFrameworks stringByAppendingPathComponent:@"libqemu-arm.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
    }
    // 2. Resource Path
    NSString *resPath = [[NSBundle mainBundle] resourcePath];
    if (resPath) {
        NSString *p = [resPath stringByAppendingPathComponent:@"Frameworks/libqemu-arm.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
        p = [resPath stringByAppendingPathComponent:@"libqemu-arm.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
    }
    // 3. Bundle root path
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (bundlePath) {
        NSString *p = [bundlePath stringByAppendingPathComponent:@"Frameworks/libqemu-arm.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
        p = [bundlePath stringByAppendingPathComponent:@"libqemu-arm.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
    }
    // 4. Documents/Frameworks fallback
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *docLib = [docDir stringByAppendingPathComponent:@"Frameworks/libqemu-arm.dylib"];
    if ([fm fileExistsAtPath:docLib]) return docLib;

    return @"@rpath/libqemu-arm.dylib";
}

- (NSString *)locateAndroidEngineLibrary {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleFrameworks = [[NSBundle mainBundle] privateFrameworksPath];
    if (bundleFrameworks) {
        NSString *p = [bundleFrameworks stringByAppendingPathComponent:@"libqemu-android.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSString *resPath = [[NSBundle mainBundle] resourcePath];
    if (resPath) {
        NSString *p = [resPath stringByAppendingPathComponent:@"Frameworks/libqemu-android.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
        p = [resPath stringByAppendingPathComponent:@"libqemu-android.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (bundlePath) {
        NSString *p = [bundlePath stringByAppendingPathComponent:@"Frameworks/libqemu-android.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
        p = [bundlePath stringByAppendingPathComponent:@"libqemu-android.dylib"];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *docLib = [docDir stringByAppendingPathComponent:@"Frameworks/libqemu-android.dylib"];
    if ([fm fileExistsAtPath:docLib]) return docLib;

    return @"@rpath/libqemu-android.dylib";
}

- (NSString *)locateEngineLibraryNamed:(NSString *)dylibName {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleFrameworks = [[NSBundle mainBundle] privateFrameworksPath];
    if (bundleFrameworks) {
        NSString *p = [bundleFrameworks stringByAppendingPathComponent:dylibName];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSString *resPath = [[NSBundle mainBundle] resourcePath];
    if (resPath) {
        NSString *p = [resPath stringByAppendingPathComponent:[@"Frameworks" stringByAppendingPathComponent:dylibName]];
        if ([fm fileExistsAtPath:p]) return p;
        p = [resPath stringByAppendingPathComponent:dylibName];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (bundlePath) {
        NSString *p = [bundlePath stringByAppendingPathComponent:[@"Frameworks" stringByAppendingPathComponent:dylibName]];
        if ([fm fileExistsAtPath:p]) return p;
        p = [bundlePath stringByAppendingPathComponent:dylibName];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *docLib = [docDir stringByAppendingPathComponent:[@"Frameworks" stringByAppendingPathComponent:dylibName]];
    if ([fm fileExistsAtPath:docLib]) return docLib;

    return [@"@rpath/" stringByAppendingString:dylibName];
}

- (NSString *)locateWinRTEngineLibrary {
    return [self locateEngineLibraryNamed:@"libqemu-winrt.dylib"];
}

- (nullable NSString *)locateWinRTFirmware {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *p = [[NSBundle mainBundle] pathForResource:@"QEMU_EFI_1512_driver1998" ofType:@"fd" inDirectory:@"winrt"];
    if (p.length > 0 && [fm fileExistsAtPath:p]) return p;
    NSString *resPath = [[NSBundle mainBundle] resourcePath];
    if (resPath) {
        NSString *cand = [resPath stringByAppendingPathComponent:@"winrt/QEMU_EFI_1512_driver1998.fd"];
        if ([fm fileExistsAtPath:cand]) return cand;
    }
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (bundlePath) {
        NSString *cand = [bundlePath stringByAppendingPathComponent:@"winrt/QEMU_EFI_1512_driver1998.fd"];
        if ([fm fileExistsAtPath:cand]) return cand;
    }
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *docFw = [docDir stringByAppendingPathComponent:@"winrt/QEMU_EFI_1512_driver1998.fd"];
    if ([fm fileExistsAtPath:docFw]) return docFw;
    return nil;
}

- (nullable NSString *)locateLinuxVirtResource:(NSString *)name ofType:(nullable NSString *)ext {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *p = [[NSBundle mainBundle] pathForResource:name ofType:ext inDirectory:@"linux-virt"];
    if (p.length > 0 && [fm fileExistsAtPath:p]) return p;
    NSString *fileName = ext.length > 0 ? [name stringByAppendingPathExtension:ext] : name;
    NSString *rel = [@"linux-virt" stringByAppendingPathComponent:fileName];
    NSString *resPath = [[NSBundle mainBundle] resourcePath];
    if (resPath) {
        NSString *cand = [resPath stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:cand]) return cand;
    }
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (bundlePath) {
        NSString *cand = [bundlePath stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:cand]) return cand;
    }
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *docFile = [docDir stringByAppendingPathComponent:rel];
    if ([fm fileExistsAtPath:docFile]) return docFile;
    return nil;
}

- (nullable NSString *)locateLinuxVirtKernel {
    return [self locateLinuxVirtResource:@"vmlinuz-virt-armhf" ofType:nil];
}

- (nullable NSString *)locateLinuxVirtInitrd {
    return [self locateLinuxVirtResource:@"initrd-virt-armhf.cpio" ofType:@"gz"];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (_isWinRTMode || UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return _isWinRTMode
            ? ((UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
                ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown)
            : UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return _isWinRTMode || (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
        self.view.window.windowScene) {
        return self.view.window.windowScene.interfaceOrientation;
    }
    return UIInterfaceOrientationPortrait;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    // Avoid host iPadOS notification center, Stage Manager dots, or home bar
    // immediately hijacking top/bottom swipes intended for the virtual iOS guest.
    return UIRectEdgeAll;
}

- (void)setIPadLandscapeRotationEnabled:(BOOL)iPadLandscapeRotationEnabled {
    _iPadLandscapeRotationEnabled = iPadLandscapeRotationEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:iPadLandscapeRotationEnabled forKey:@"ClassicTouch_iPadLandscapeRotate"];
    [self updateMetalDisplayRotation];
    _lastMotionNs = 0;
    [self forwardMotionSample];
    [self refreshMoreMenu];
}

- (void)setClipboardSyncEnabled:(BOOL)clipboardSyncEnabled {
    _clipboardSyncEnabled = clipboardSyncEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:clipboardSyncEnabled forKey:@"ClassicTouch_ClipboardSyncEnabled"];
    [self refreshMoreMenu];
    if (clipboardSyncEnabled) {
        [self checkHostPasteboardForSync];
    }
}

- (void)startClipboardSyncTimer {
    [self stopClipboardSyncTimer];
    __weak typeof(self) weakSelf = self;
    self.clipboardSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !__atomic_load_n(&s->_isEmulating, __ATOMIC_ACQUIRE)) return;
        [s tickClipboardSync];
    }];
}

- (void)stopClipboardSyncTimer {
    [self.clipboardSyncTimer invalidate];
    self.clipboardSyncTimer = nil;
}

- (void)showToastBannerWithText:(NSString *)text icon:(NSString *)iconName {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *toast = [[UIView alloc] init];
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        toast.layer.cornerRadius = 16.0;
        toast.layer.masksToBounds = YES;
        toast.alpha = 0.0;

        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:blur];
        [NSLayoutConstraint activateConstraints:@[
            [blur.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor],
            [blur.topAnchor constraintEqualToAnchor:toast.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor]
        ]];

        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName]];
        iv.tintColor = [UIColor whiteColor];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = text;
        lbl.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        lbl.textColor = [UIColor whiteColor];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[iv, lbl]];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 8.0;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [blur.contentView addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [iv.widthAnchor constraintEqualToConstant:18.0],
            [iv.heightAnchor constraintEqualToConstant:18.0],
            [stack.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:14.0],
            [stack.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor constant:-14.0],
            [stack.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor constant:8.0],
            [stack.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor constant:-8.0]
        ]];

        [self.view addSubview:toast];
        [NSLayoutConstraint activateConstraints:@[
            [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [toast.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12.0]
        ]];

        [UIView animateWithDuration:0.22 animations:^{
            toast.alpha = 1.0;
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{
                    toast.alpha = 0.0;
                } completion:^(BOOL fin) {
                    [toast removeFromSuperview];
                }];
            });
        }];
    });
}

- (void)sendHostPasteboardToGuest:(NSString *)text showToast:(BOOL)showToast {
    if (_isAndroidMode || _isWinRTMode ||
        !__atomic_load_n(&_runtime, __ATOMIC_ACQUIRE) ||
        !__atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE) ||
        !text.length) {
        return;
    }
    typedef void (*qemu_ios_ui_paste_fn)(const char *utf8);
    static qemu_ios_ui_paste_fn pasteFn = NULL;
    if (!pasteFn) {
        pasteFn = (qemu_ios_ui_paste_fn)dlsym(RTLD_DEFAULT, "qemu_ios_ui_paste");
    }
    if (!pasteFn) {
        NSLog(@"[EmulatorVC] qemu_ios_ui_paste symbol not found");
        return;
    }

    _lastSyncedPasteboardString = [text copy];
    pasteFn([text UTF8String]);
    NSLog(@"[EmulatorVC] Sent host pasteboard to guest (%lu chars)", (unsigned long)text.length);
    if (showToast) {
        [self showToastBannerWithText:L(@"toast_clipboard_sent") icon:@"arrow.right.doc.on.clipboard"];
    }
}

- (void)checkHostPasteboardForSync {
    if (!self.clipboardSyncEnabled) return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    if (pb.changeCount != _lastHostPasteboardChangeCount) {
        _lastHostPasteboardChangeCount = pb.changeCount;
        NSString *str = pb.string;
        if (str.length > 0 && ![str isEqualToString:_lastSyncedPasteboardString]) {
            [self sendHostPasteboardToGuest:str showToast:NO];
        }
    }
}

- (void)handleHostPasteboardChanged:(NSNotification *)note {
    [self checkHostPasteboardForSync];
}

- (void)pollGuestPasteboard {
    if (_isAndroidMode || _isWinRTMode ||
        !__atomic_load_n(&_runtime, __ATOMIC_ACQUIRE) ||
        !__atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) {
        return;
    }
    typedef char *(*qemu_ios_ui_guest_pasteboard_fn)(uint64_t *serial);
    static qemu_ios_ui_guest_pasteboard_fn guestPbFn = NULL;
    if (!guestPbFn) {
        guestPbFn = (qemu_ios_ui_guest_pasteboard_fn)dlsym(RTLD_DEFAULT, "qemu_ios_ui_guest_pasteboard");
    }
    if (!guestPbFn) return;

    char *gtext = guestPbFn(&_guestPasteboardSerial);
    if (gtext) {
        NSString *str = [NSString stringWithUTF8String:gtext];
        free(gtext);
        if (self.clipboardSyncEnabled && str.length > 0 && ![str isEqualToString:_lastSyncedPasteboardString]) {
            _lastSyncedPasteboardString = [str copy];
            _lastHostPasteboardChangeCount = [UIPasteboard generalPasteboard].changeCount + 1;
            [UIPasteboard generalPasteboard].string = str;
            NSLog(@"[EmulatorVC] Received guest pasteboard to host (%lu chars)", (unsigned long)str.length);
            [self showToastBannerWithText:L(@"toast_clipboard_received") icon:@"doc.on.clipboard"];
        }
    }
}

- (void)tickClipboardSync {
    [self pollGuestPasteboard];
    [self checkHostPasteboardForSync];
}

- (void)updateMetalDisplayRotation {
    UIInterfaceOrientation ori = UIInterfaceOrientationPortrait;
    if (self.view.window.windowScene) {
        ori = self.view.window.windowScene.interfaceOrientation;
    }
    NSInteger prevOri = __atomic_exchange_n(&_hostInterfaceOrientation, (NSInteger)ori, __ATOMIC_ACQ_REL);

    BOOL isPad = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
    BOOL guestLandscape = (self.screenWidth > self.screenHeight);
    BOOL hostLandscape = (self.view.bounds.size.width > self.view.bounds.size.height);
    BOOL accelCapable = _isAndroidMode || __atomic_load_n(&_boardSupportsAccel, __ATOMIC_ACQUIRE);

    NSInteger rot = 0;
    if (_isWinRTMode) {
        rot = 0;
    } else if (guestLandscape) {
        // Landscape-native guest framebuffers (e.g. iPad 1st gen 1024x768)
        if (isPad && !self.iPadLandscapeRotationEnabled) {
            rot = 90;
        } else if (ori == UIInterfaceOrientationLandscapeLeft) {
            rot = 180;
        } else if (ori == UIInterfaceOrientationLandscapeRight) {
            rot = 0;
        } else if (ori == UIInterfaceOrientationPortraitUpsideDown) {
            rot = 270;
        } else {
            rot = 90;
        }
    } else {
        // Portrait-native framebuffers (iPhone / iPod / Android):
        // Rotate display only when iPad landscape rotation is active AND the guest board supports rotation.
        if (isPad && self.iPadLandscapeRotationEnabled && hostLandscape && accelCapable) {
            rot = (ori == UIInterfaceOrientationLandscapeLeft) ? 90 : 270;
        } else {
            rot = 0;
        }
    }
    self.metalView.displayRotationDegrees = rot;
    if (prevOri != (NSInteger)ori) {
        _lastMotionNs = 0;
        [self forwardMotionSample];
    }
}

- (void)setupZoomIndicatorBar {
    if (_zoomIndicatorBar) return;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.layer.cornerRadius = 20.0;
    blur.layer.masksToBounds = YES;
    blur.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.left.and.down.right.magnifyingglass"]];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [[UILabel alloc] init];
    label.text = L(@"zoom_mode_active_hint");
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetBtn setTitle:L(@"zoom_mode_reset_button") forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor systemTealColor] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
    resetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [resetBtn addTarget:self action:@selector(handleResetZoomFromIndicator) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, label, resetBtn]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 10.0;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [blur.contentView addSubview:stack];
    [self.view addSubview:blur];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:18],
        [iconView.heightAnchor constraintEqualToConstant:18],
        [stack.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor constant:-14],
        [stack.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor constant:-6],
        [blur.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [blur.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [blur.heightAnchor constraintEqualToConstant:40]
    ]];

    blur.alpha = 0.0;
    blur.hidden = YES;
    _zoomIndicatorBar = blur;
}

- (void)handleResetZoomFromIndicator {
    [self setZoomModeEnabled:NO];
}

- (void)toggleZoomMode {
    [self setZoomModeEnabled:!self.metalView.zoomModeEnabled];
}

- (void)setZoomModeEnabled:(BOOL)enabled {
    [self.metalView setZoomModeEnabled:enabled];
    [self updateZoomIndicatorVisibility:enabled];
    [self refreshMoreMenu];
}

- (void)updateZoomIndicatorVisibility:(BOOL)visible {
    if (!_zoomIndicatorBar) return;
    if (visible) {
        _zoomIndicatorBar.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{
            self->_zoomIndicatorBar.alpha = 1.0;
        }];
    } else {
        [UIView animateWithDuration:0.2 animations:^{
            self->_zoomIndicatorBar.alpha = 0.0;
        } completion:^(BOOL finished) {
            if (!self.metalView.zoomModeEnabled) {
                self->_zoomIndicatorBar.hidden = YES;
            }
        }];
    }
}

- (void)pullNotificationCenter {
    if ((!_runtime && !_isAndroidMode) || !_isEmulating) return;

    // Send a smooth edge-swipe gesture downwards from top edge (y=0.005 to y=0.55)
    // using dedicated touch ID 999999 so it never collides with user touches.
    int touchId = 999999;
    float startX = 0.5f;
    float startY = 0.005f;
    float endY = 0.55f;
    int steps = 10;

    [self handleTouchId:touchId phase:0 x:startX y:startY];

    for (int i = 1; i <= steps; i++) {
        float progress = (float)i / (float)steps;
        float t = sinf(progress * (float)M_PI_2);
        float curY = startY + (endY - startY) * t;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * i * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (!self->_isEmulating) return;
            if (i < steps) {
                [self handleTouchId:touchId phase:1 x:startX y:curY];
            } else {
                [self handleTouchId:touchId phase:2 x:startX y:curY];
            }
        });
    }
}

- (void)pullControlCenter {
    if (!_runtime || !_isEmulating) return;

    // Send a smooth edge-swipe gesture upwards from bottom edge (y=0.995 to y=0.45)
    // using dedicated touch ID 999998 so it never collides with user touches.
    int touchId = 999998;
    float startX = 0.5f;
    float startY = 0.995f;
    float endY = 0.45f;
    int steps = 10;

    [self handleTouchId:touchId phase:0 x:startX y:startY];

    for (int i = 1; i <= steps; i++) {
        float progress = (float)i / (float)steps;
        float t = sinf(progress * (float)M_PI_2);
        float curY = startY + (endY - startY) * t;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * i * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (!self->_isEmulating) return;
            if (i < steps) {
                [self handleTouchId:touchId phase:1 x:startX y:curY];
            } else {
                [self handleTouchId:touchId phase:2 x:startX y:curY];
            }
        });
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updateMetalDisplayRotation];
    if (_isWinRTMode && ![self.winrtKeyInputView isFirstResponder]) {
        [self becomeFirstResponder];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self updateMetalDisplayRotation];
        [self clampHardwareBarToSafeArea];
        self->_lastMotionNs = 0;
        [self forwardMotionSample];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self updateMetalDisplayRotation];
        [self clampHardwareBarToSafeArea];
        self->_lastMotionNs = 0;
        [self forwardMotionSample];
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.modalInPresentation = YES;
    self.view.backgroundColor = [UIColor blackColor];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];

    _isChromeOSMode = [self.platform isEqualToString:@"chromeos"] ||
                      [self.baseDirPath.lastPathComponent hasPrefix:@"chromeos-"];
    _isUbuntuTouchVirtMode = [self.platform isEqualToString:@"ubuntutouch"] ||
                             [self.baseDirPath.lastPathComponent hasPrefix:@"ut-virt-"];
    _isWinRTMode = _isChromeOSMode || _isUbuntuTouchVirtMode ||
                   [self.platform isEqualToString:@"winrt"] ||
                   [self.baseDirPath.lastPathComponent hasPrefix:@"winrt-"];
    _isAndroidMode = !_isWinRTMode &&
                     [[NSFileManager defaultManager] fileExistsAtPath:[self.baseDirPath stringByAppendingPathComponent:@"kernel-qemu"]];
    for (int i = 0; i < 5; i++) {
        _androidTouchSlots[i] = -1;
        _winrtActiveTouches[i] = -1;
    }
    for (int i = 0; i < 10; i++) {
        _utTouchSlots[i] = -1;
    }
    _winrtCursorX = 0.5f;
    _winrtCursorY = 0.5f;
    if (_isUbuntuTouchVirtMode && (_screenWidth <= 0 || _screenHeight <= 0 || (_screenWidth == 320 && _screenHeight == 480))) {
        _screenWidth = 432;
        _screenHeight = 768;
    } else if (_isWinRTMode && (_screenWidth <= 0 || _screenHeight <= 0 || (_screenWidth == 320 && _screenHeight == 480))) {
        _screenWidth = 1024;
        _screenHeight = 768;
    } else if (_isAndroidMode && (_screenWidth <= 0 || _screenHeight <= 0)) {
        _screenWidth = 750;
        _screenHeight = 1334;
    }

    // Metal rendering view (use FrameMailbox + MetalDisplay for Goldfish & WinRT; keep IOSMetalView untouched for iOS)
    if (_isAndroidMode || _isWinRTMode) {
        _androidMetalView = [[AndroidMetalView alloc] initWithFrame:self.view.bounds];
        self.metalView = _androidMetalView;
    } else {
        _iosMetalView = [[IOSMetalView alloc] initWithFrame:self.view.bounds];
        self.metalView = _iosMetalView;
    }
    self.metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.metalView];

    // Multitouch forwarding
    __weak typeof(self) weakSelf = self;
    self.metalView.onTouchEvent = ^(int touchId, int phase, float x, float y) {
        [weakSelf handleTouchId:touchId phase:phase x:x y:y];
    };
    self.metalView.onZoomChanged = ^(CGFloat scale, CGPoint offset) {
        // ズーム変更時の通知
    };

    // Zoom indicator bar
    [self setupZoomIndicatorBar];

    // Hardware buttons floating bar
    [self setupHardwareControls];
    [self updateMetalDisplayRotation];

    // Telemetry HUD overlay
    [self setupTelemetryHUD];

    // Non-blocking IPA install HUD overlay (allows tapping guest "Trust" alert)
    [self setupIpaProgressHUD];

    // Audio bridge reference (started in startEmulation after _isEmulating becomes YES)
    self.audioBridge = [IOSAudioBridge sharedBridge];

    // Motion manager (runs on dedicated CoreMotion queue)
    self.motionManager = [IOSMotionManager sharedManager];
    self.motionManager.delegate = self;
    [self.motionManager startMonitoringAtInterval:1.0 / 30.0];

    // JIT protection init (already probed by MainViewController; worker thread refreshes authoritative status)
    ios_jit_init_protection();
    self.cachedJitAvailable = YES;

    // Start emulation worker
    [self startEmulation];
}

static UIVisualEffect *ClassicCreateGlassEffect(UIBlurEffectStyle fallbackStyle, BOOL interactive, BOOL *outIsGlass) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (glassClass) {
        SEL sel = NSSelectorFromString(@"effectWithStyle:");
        if ([glassClass respondsToSelector:sel]) {
            UIVisualEffect *(*fn)(id, SEL, NSInteger) = (UIVisualEffect *(*)(id, SEL, NSInteger))[glassClass methodForSelector:sel];
            UIVisualEffect *glass = fn(glassClass, sel, 0);
            if (glass) {
                if (interactive) {
                    SEL interSel = NSSelectorFromString(@"setInteractive:");
                    if ([glass respondsToSelector:interSel]) {
                        void (*setInter)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[glass methodForSelector:interSel];
                        setInter(glass, interSel, YES);
                    }
                }
                if (outIsGlass) *outIsGlass = YES;
                return glass;
            }
        }
    }
    if (outIsGlass) *outIsGlass = NO;
    return [UIBlurEffect effectWithStyle:fallbackStyle];
}

static UIImage *ClassicHardwareSymbolImage(NSString *symbolName, UIImageSymbolConfiguration *symCfg) {
    UIImage *img = [UIImage systemImageNamed:symbolName withConfiguration:symCfg];
    if (img) {
        return img;
    }
    BOOL isVolUp = [symbolName isEqualToString:@"speaker.plus.fill"];
    BOOL isVolDown = [symbolName isEqualToString:@"speaker.minus.fill"];
    if (!isVolUp && !isVolDown) {
        return nil;
    }

    /* speaker.plus.fill / speaker.minus.fill require SF Symbols 5 (iOS 17+);
     * compose native vector speaker + plus/minus SF Symbols cleanly on iOS 15/16. */
    UIImageSymbolConfiguration *speakerCfg = [UIImageSymbolConfiguration configurationWithPointSize:11.5
                                                                                             weight:UIImageSymbolWeightSemibold];
    UIImageSymbolConfiguration *badgeCfg = [UIImageSymbolConfiguration configurationWithPointSize:8.5
                                                                                           weight:UIImageSymbolWeightBold];
    UIImage *speaker = [[UIImage systemImageNamed:@"speaker.fill" withConfiguration:speakerCfg]
                        imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *badge = [[UIImage systemImageNamed:(isVolUp ? @"plus" : @"minus") withConfiguration:badgeCfg]
                      imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!speaker) {
        return [UIImage systemImageNamed:(isVolUp ? @"speaker.wave.2.fill" : @"speaker.wave.1.fill")
                       withConfiguration:symCfg];
    }
    CGSize spSz = speaker.size;
    CGSize bgSz = badge ? badge.size : CGSizeZero;
    CGFloat w = MAX(19.0, ceil(spSz.width + (badge ? bgSz.width + 1.5 : 0.0) + 1.0));
    CGFloat h = MAX(16.0, ceil(MAX(spSz.height, bgSz.height)));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, h) format:fmt];
    UIImage *composed = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [speaker drawInRect:CGRectMake(0.5, (h - spSz.height) * 0.5, spSz.width, spSz.height)];
        if (badge) {
            [badge drawInRect:CGRectMake(spSz.width + 1.5, (h - bgSz.height) * 0.5, bgSz.width, bgSz.height)];
        }
    }];
    return [composed imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIButton *)createCompactHardwareButton:(NSString *)symbolName
                                    title:(nullable NSString *)title
                                 minWidth:(CGFloat)minWidth
                                   action:(SEL)downAction
                                 upAction:(nullable SEL)upAction {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;

    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:(title ? 12.0 : 13.0)
                                                                                         weight:UIImageSymbolWeightSemibold];
    cfg.image = ClassicHardwareSymbolImage(symbolName, symCfg);
    cfg.baseForegroundColor = [UIColor colorWithWhite:1.0 alpha:0.94];
    cfg.contentInsets = title ? NSDirectionalEdgeInsetsMake(4.0, 6.0, 4.0, 6.0)
                              : NSDirectionalEdgeInsetsMake(4.0, 5.0, 4.0, 5.0);
    cfg.imagePadding = title ? 3.0 : 0.0;
    cfg.titleLineBreakMode = NSLineBreakByClipping;
    if (title) {
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByClipping;
        ps.alignment = NSTextAlignmentCenter;
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:title
                                                                   attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold],
            NSParagraphStyleAttributeName: ps
        }];
        cfg.attributedTitle = attr;
    }
    btn.configuration = cfg;
    btn.tintColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    btn.layer.cornerRadius = 13.0;
    btn.layer.masksToBounds = YES;
    btn.titleLabel.numberOfLines = 1;
    btn.titleLabel.lineBreakMode = NSLineBreakByClipping;
    [btn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [btn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithObject:[btn.heightAnchor constraintEqualToConstant:26.0]];
    if (minWidth > 0.0) {
        [constraints addObject:[btn.widthAnchor constraintGreaterThanOrEqualToConstant:minWidth]];
    }
    [NSLayoutConstraint activateConstraints:constraints];

    if (downAction) {
        [btn addTarget:self action:downAction forControlEvents:UIControlEventTouchDown];
    }
    if (upAction) {
        [btn addTarget:self action:upAction forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    } else if (downAction) {
        [btn removeTarget:self action:downAction forControlEvents:UIControlEventTouchDown];
        [btn addTarget:self action:downAction forControlEvents:UIControlEventTouchUpInside];
    }
    return btn;
}

- (UIMenu *)buildHardwareMoreMenu {
    __weak typeof(self) weakSelf = self;

    // --- 画面操作・ジェスチャメニュー ---
    NSMutableArray<UIMenuElement *> *displayActions = [NSMutableArray array];

    if (!_isWinRTMode) {
        // 1. 通知センターを開く（ホスト iPadOS と競合せず確実に開く）
        UIAction *notifAct = [UIAction actionWithTitle:L(@"menu_pull_notif")
                                                 image:[UIImage systemImageNamed:@"bell.badge"]
                                            identifier:nil
                                               handler:^(__kindof UIAction *action) {
            [weakSelf pullNotificationCenter];
        }];
        [displayActions addObject:notifAct];

        // 2. コントロールセンターを開く（ホストのホームバー/Dockと競合せず確実に開く）
        if (!_isAndroidMode) {
            UIAction *ccAct = [UIAction actionWithTitle:L(@"menu_pull_control_center")
                                                  image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                             identifier:nil
                                                handler:^(__kindof UIAction *action) {
                [weakSelf pullControlCenter];
            }];
            [displayActions addObject:ccAct];
        }
    }

    // 3. 拡大モード (UTMスタイルのピンチ＆パンズーム)
    BOOL zoomActive = self.metalView.zoomModeEnabled;
    UIAction *zoomToggle = [UIAction actionWithTitle:L(@"menu_zoom_mode")
                                               image:[UIImage systemImageNamed:zoomActive ? @"checkmark.circle.fill" : @"arrow.up.left.and.down.right.magnifyingglass"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s toggleZoomMode];
    }];
    zoomToggle.state = zoomActive ? UIMenuElementStateOn : UIMenuElementStateOff;
    [displayActions addObject:zoomToggle];

    // 4. iPad 専用: 横画面時の向き切り替え (iPhoneの操作とは明確に区別)
    if (!_isWinRTMode && UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        BOOL rotEnabled = self.iPadLandscapeRotationEnabled;
        UIAction *oriLock = [UIAction actionWithTitle:L(@"menu_ipad_orientation_lock_portrait")
                                                image:[UIImage systemImageNamed:@"lock.rotation"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *action) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s setIPadLandscapeRotationEnabled:NO];
        }];
        oriLock.state = (!rotEnabled) ? UIMenuElementStateOn : UIMenuElementStateOff;

        UIAction *oriRotate = [UIAction actionWithTitle:L(@"menu_ipad_orientation_rotate_landscape")
                                                  image:[UIImage systemImageNamed:@"rotate.right"]
                                             identifier:nil
                                                handler:^(__kindof UIAction *action) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s setIPadLandscapeRotationEnabled:YES];
        }];
        oriRotate.state = rotEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;

        UIMenu *orientationSubmenu = [UIMenu menuWithTitle:L(@"menu_ipad_orientation_title")
                                                     image:[UIImage systemImageNamed:@"ipad.landscape"]
                                                identifier:nil
                                                   options:0
                                                  children:@[oriLock, oriRotate]];
        [displayActions addObject:orientationSubmenu];
    }

    UIMenu *displayMenu = [UIMenu menuWithTitle:@""
                                          image:nil
                                     identifier:nil
                                        options:UIMenuOptionsDisplayInline
                                       children:displayActions];

    // --- メニューバー配置・一時非表示 ---
    UIAction *posBottom = [UIAction actionWithTitle:L(@"menu_pos_bottom")
                                              image:[UIImage systemImageNamed:@"arrow.down.to.line"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s.userMovedBarManually = NO;
        s.hasSavedCollapsedLeading = NO;
        s.collapseButtonOnTrailing = NO;
        if (s.hardwareStack.arrangedSubviews.firstObject != s.collapseButton) {
            [s.hardwareStack removeArrangedSubview:s.collapseButton];
            [s.hardwareStack insertArrangedSubview:s.collapseButton atIndex:0];
        }
        if (!s.barCollapsed) {
            UIButtonConfiguration *c = s.collapseButton.configuration;
            c.image = [UIImage systemImageNamed:@"chevron.left" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightSemibold]];
            s.collapseButton.configuration = c;
        }
        s.menuPositionMode = ClassicMenuPositionAutoBottom;
        [s applyPreferredBarPositionAnimated:YES];
        [s refreshMoreMenu];
    }];
    posBottom.state = (self.menuPositionMode == ClassicMenuPositionAutoBottom) ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *posTop = [UIAction actionWithTitle:L(@"menu_pos_top")
                                           image:[UIImage systemImageNamed:@"arrow.up.to.line"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s.userMovedBarManually = NO;
        s.hasSavedCollapsedLeading = NO;
        s.collapseButtonOnTrailing = NO;
        if (s.hardwareStack.arrangedSubviews.firstObject != s.collapseButton) {
            [s.hardwareStack removeArrangedSubview:s.collapseButton];
            [s.hardwareStack insertArrangedSubview:s.collapseButton atIndex:0];
        }
        if (!s.barCollapsed) {
            UIButtonConfiguration *c = s.collapseButton.configuration;
            c.image = [UIImage systemImageNamed:@"chevron.left" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightSemibold]];
            s.collapseButton.configuration = c;
        }
        s.menuPositionMode = ClassicMenuPositionAutoTop;
        [s applyPreferredBarPositionAnimated:YES];
        [s refreshMoreMenu];
    }];
    posTop.state = (self.menuPositionMode == ClassicMenuPositionAutoTop) ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *hideTemp = [UIAction actionWithTitle:L(@"menu_hide_temp")
                                             image:[UIImage systemImageNamed:@"eye.slash"]
                                        identifier:nil
                                           handler:^(__kindof UIAction *action) {
        [weakSelf hideHardwareBarTemporarilyForSeconds:5.0];
    }];

    UIMenu *layoutMenu = [UIMenu menuWithTitle:@""
                                         image:nil
                                    identifier:nil
                                       options:UIMenuOptionsDisplayInline
                                      children:@[posBottom, posTop, hideTemp]];

    UIAction *clipSyncAct = [UIAction actionWithTitle:L(@"menu_clipboard_sync")
                                                image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s setClipboardSyncEnabled:!s.clipboardSyncEnabled];
    }];
    clipSyncAct.state = self.clipboardSyncEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *pasteToGuestAct = [UIAction actionWithTitle:L(@"menu_paste_to_guest")
                                                    image:[UIImage systemImageNamed:@"arrow.right.doc.on.clipboard"]
                                               identifier:nil
                                                  handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        NSString *clipStr = [UIPasteboard generalPasteboard].string;
        if (clipStr.length > 0) {
            [s sendHostPasteboardToGuest:clipStr showToast:YES];
        } else {
            [s showToastBannerWithText:L(@"toast_clipboard_empty") icon:@"exclamationmark.circle"];
        }
    }];

    BOOL hudVisible = (self.telemetryCard && !self.telemetryCard.hidden);
    UIAction *hudAct = [UIAction actionWithTitle:L(@"menu_toggle_hud")
                                           image:[UIImage systemImageNamed:@"waveform.path.ecg"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s toggleHUD:nil];
        [s refreshMoreMenu];
    }];
    hudAct.state = hudVisible ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *installIpaAct = [UIAction actionWithTitle:L(@"menu_install_ipa")
                                                   image:[UIImage systemImageNamed:@"arrow.down.app"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
        [weakSelf installIPATapped:nil];
    }];

    UIAction *androidBackAct = [UIAction actionWithTitle:@"Back"
                                                   image:[UIImage systemImageNamed:@"chevron.backward"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s->_pfnAndroidButton) return;
        s->_pfnAndroidButton(158 /* KEY_BACK */, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (s->_pfnAndroidButton) s->_pfnAndroidButton(158 /* KEY_BACK */, 0);
        });
    }];

    UIAction *androidHomeAct = [UIAction actionWithTitle:L(@"menu_btn_home")
                                                   image:[UIImage systemImageNamed:@"circle.inset.filled"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s->_pfnAndroidButton) return;
        s->_pfnAndroidButton(102 /* KEY_HOME */, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (s->_pfnAndroidButton) s->_pfnAndroidButton(102 /* KEY_HOME */, 0);
        });
    }];

    UIAction *androidMenuAct = [UIAction actionWithTitle:@"Menu"
                                                   image:[UIImage systemImageNamed:@"line.3.horizontal"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s->_pfnAndroidButton) return;
        s->_pfnAndroidButton(139 /* KEY_MENU */, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (s->_pfnAndroidButton) s->_pfnAndroidButton(139 /* KEY_MENU */, 0);
        });
    }];

    UIAction *installApkAct = [UIAction actionWithTitle:L(@"menu_install_apk")
                                                  image:[UIImage systemImageNamed:@"shippingbox"]
                                             identifier:nil
                                                handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s) [s installAPKTapped:nil];
    }];

    UIAction *winrtCadAct = [UIAction actionWithTitle:L(@"winrt_send_cad")
                                                image:[UIImage systemImageNamed:@"keyboard.chevron.compact.down"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_pfnWinrtSendCad) {
            s->_pfnWinrtSendCad();
            [s showToastBannerWithText:@"Ctrl + Alt + Del" icon:@"keyboard"];
        }
    }];

    UIAction *winrtResetUsbAct = [UIAction actionWithTitle:L(@"winrt_reset_usb")
                                                     image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                                identifier:nil
                                                   handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s) [s resetWinRTUSBInputTapped:nil];
    }];

    UIAction *winrtInputModeAct = [UIAction actionWithTitle:_winrtMouseMode ? L(@"winrt_input_mode_touch") : L(@"winrt_input_mode_mouse")
                                                       image:[UIImage systemImageNamed:_winrtMouseMode ? @"hand.tap" : @"computermouse.fill"]
                                                  identifier:nil
                                                     handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s) [s toggleWinRTInputModeTapped:nil];
    }];

    BOOL isFirefoxOS = [self.baseDirPath.lastPathComponent hasPrefix:@"fxos-"];
    NSArray *toolChildren = nil;
    if (_isUbuntuTouchVirtMode) {
        toolChildren = @[hudAct];
    } else if (_isChromeOSMode) {
        toolChildren = @[hudAct, winrtInputModeAct];
    } else if (_isWinRTMode) {
        toolChildren = @[hudAct, winrtInputModeAct, winrtCadAct, winrtResetUsbAct];
    } else if (_isAndroidMode) {
        toolChildren = isFirefoxOS
            ? @[androidBackAct, androidHomeAct, androidMenuAct, hudAct]
            : @[androidBackAct, androidHomeAct, androidMenuAct, hudAct, installApkAct];
    } else {
        toolChildren = @[clipSyncAct, pasteToGuestAct, hudAct, installIpaAct];
    }
    UIMenu *toolsMenu = [UIMenu menuWithTitle:@""
                                        image:nil
                                   identifier:nil
                                      options:UIMenuOptionsDisplayInline
                                     children:toolChildren];

    UIAction *restartAct = [UIAction actionWithTitle:L(@"force_restart_title")
                                               image:[UIImage systemImageNamed:@"arrow.clockwise.circle"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *action) {
        [weakSelf forceRestartTapped:nil];
    }];

    UIAction *exitAct = [UIAction actionWithTitle:L(@"menu_exit_vm")
                                            image:[UIImage systemImageNamed:@"xmark.circle"]
                                       identifier:nil
                                          handler:^(__kindof UIAction *action) {
        [weakSelf exitTapped:nil];
    }];
    exitAct.attributes = UIMenuElementAttributesDestructive;

    UIMenu *powerMenu = [UIMenu menuWithTitle:@""
                                        image:nil
                                   identifier:nil
                                      options:UIMenuOptionsDisplayInline
                                     children:(_isAndroidMode || _isWinRTMode) ? @[exitAct] : @[restartAct, exitAct]];

    return [UIMenu menuWithTitle:@"" children:@[displayMenu, layoutMenu, toolsMenu, powerMenu]];
}

- (void)refreshMoreMenu {
    if (self.moreMenuButton) {
        self.moreMenuButton.menu = [self buildHardwareMoreMenu];
    }
}

- (void)hideHardwareBarTemporarilyForSeconds:(NSTimeInterval)seconds {
    self.tempHideToken += 1;
    NSUInteger token = self.tempHideToken;
    self.hardwareBar.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.18 animations:^{
        self.hardwareBar.alpha = 0.0;
    }];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.tempHideToken != token) return;
        s.hardwareBar.userInteractionEnabled = YES;
        [UIView animateWithDuration:0.25 animations:^{
            s.hardwareBar.alpha = 1.0;
        }];
    });
}

- (CGRect)guestScreenRectInView {
    CGRect active = [self.metalView activeScreenRect];
    CGRect bounds = self.metalView.bounds;
    if (!CGRectIsEmpty(active) && !CGRectEqualToRect(active, bounds)) {
        return [self.view convertRect:active fromView:self.metalView];
    }
    if (bounds.size.width <= 0 || bounds.size.height <= 0 || self.screenWidth <= 0 || self.screenHeight <= 0) {
        return bounds;
    }
    NSInteger rot = self.metalView.displayRotationDegrees;
    BOOL swapped = (rot == 90 || rot == 270);
    CGFloat dispW = swapped ? (CGFloat)self.screenHeight : (CGFloat)self.screenWidth;
    CGFloat dispH = swapped ? (CGFloat)self.screenWidth : (CGFloat)self.screenHeight;
    CGFloat guestAspect = dispW / dispH;
    CGFloat viewAspect = bounds.size.width / bounds.size.height;
    CGRect fit = bounds;
    if (viewAspect > guestAspect) {
        CGFloat w = bounds.size.height * guestAspect;
        fit = CGRectMake((bounds.size.width - w) * 0.5, 0.0, w, bounds.size.height);
    } else {
        CGFloat h = bounds.size.width / guestAspect;
        fit = CGRectMake(0.0, (bounds.size.height - h) * 0.5, bounds.size.width, h);
    }
    return [self.view convertRect:fit fromView:self.metalView];
}

- (void)setupHardwareControls {
    self.menuPositionMode = ClassicMenuPositionAutoBottom;
    self.hardwareBar = [[UIView alloc] init];
    self.hardwareBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.hardwareBar.backgroundColor = [UIColor clearColor];
    self.hardwareBar.layer.cornerRadius = 18.0;
    self.hardwareBar.layer.shadowColor = [UIColor blackColor].CGColor;
    self.hardwareBar.layer.shadowOpacity = 0.20;
    self.hardwareBar.layer.shadowRadius = 14.0;
    self.hardwareBar.layer.shadowOffset = CGSizeMake(0, 4);
    [self.view addSubview:self.hardwareBar];

    BOOL isGlass = NO;
    UIVisualEffect *effect = ClassicCreateGlassEffect(UIBlurEffectStyleSystemUltraThinMaterialDark, YES, &isGlass);
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
    blurView.frame = self.hardwareBar.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.layer.cornerRadius = 18.0;
    blurView.layer.masksToBounds = YES;
    blurView.alpha = 1.0;
    blurView.layer.borderWidth = 0.5;
    blurView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:(isGlass ? 0.20 : 0.25)].CGColor;
    self.barBlurView = blurView;
    [self.hardwareBar insertSubview:blurView atIndex:0];

    self.collapseButton = [self createCompactHardwareButton:@"chevron.left" title:nil minWidth:24.0 action:@selector(toggleHardwareBar:) upAction:nil];
    self.collapseButton.backgroundColor = [UIColor clearColor];
    self.collapseWidthConstraint = [self.collapseButton.widthAnchor constraintEqualToConstant:24.0];
    self.collapseWidthConstraint.active = YES;

    self.backButton = [self createCompactHardwareButton:@"chevron.backward" title:nil minWidth:28.0 action:@selector(backButtonDown:) upAction:@selector(backButtonUp:)];
    self.homeButton = [self createCompactHardwareButton:@"circle.inset.filled" title:(_isAndroidMode ? nil : L(@"menu_btn_home")) minWidth:(_isAndroidMode ? 28.0 : 0.0) action:@selector(homeButtonDown:) upAction:@selector(homeButtonUp:)];
    [self.homeButton removeTarget:self action:@selector(homeButtonUp:) forControlEvents:UIControlEventTouchCancel];
    [self.homeButton addTarget:self action:@selector(homeButtonCancel:) forControlEvents:UIControlEventTouchCancel];
    self.menuButton = [self createCompactHardwareButton:@"line.3.horizontal" title:nil minWidth:28.0 action:@selector(menuButtonDown:) upAction:@selector(menuButtonUp:)];
    self.powerButton = [self createCompactHardwareButton:@"power" title:(_isAndroidMode ? nil : L(@"menu_btn_power")) minWidth:(_isAndroidMode ? 28.0 : 0.0) action:@selector(powerButtonDown:) upAction:@selector(powerButtonUp:)];
    self.volDownButton = [self createCompactHardwareButton:@"speaker.minus.fill" title:nil minWidth:28.0 action:@selector(volDownButtonDown:) upAction:@selector(volDownButtonUp:)];
    self.volUpButton = [self createCompactHardwareButton:@"speaker.plus.fill" title:nil minWidth:28.0 action:@selector(volUpButtonDown:) upAction:@selector(volUpButtonUp:)];

    self.moreMenuButton = [self createCompactHardwareButton:@"ellipsis.circle" title:L(@"menu_btn_more") minWidth:0.0 action:nil upAction:nil];
    self.moreMenuButton.showsMenuAsPrimaryAction = YES;
    self.moreMenuButton.accessibilityLabel = L(@"menu_btn_more");
    [self refreshMoreMenu];

    if (_isWinRTMode) {
        self.winrtInputModeButton = [self createCompactHardwareButton:@"hand.tap" title:nil minWidth:30.0 action:@selector(toggleWinRTInputModeTapped:) upAction:nil];
        self.winrtDragButton = [self createCompactHardwareButton:@"hand.draw" title:nil minWidth:30.0 action:@selector(toggleWinRTDragLockTapped:) upAction:nil];
        self.winrtDragButton.hidden = YES;
        self.winrtKeyboardButton = [self createCompactHardwareButton:@"keyboard" title:nil minWidth:32.0 action:@selector(toggleWinRTKeyboardTapped:) upAction:nil];
        self.winrtQuickKeysButton = [self createCompactHardwareButton:@"command" title:nil minWidth:32.0 action:nil upAction:nil];
        self.winrtQuickKeysButton.showsMenuAsPrimaryAction = YES;
        self.winrtResetUsbButton = [self createCompactHardwareButton:@"arrow.triangle.2.circlepath" title:nil minWidth:30.0 action:@selector(resetWinRTUSBInputTapped:) upAction:nil];

        ClassicWinRTKeyInputView *keyView = [[ClassicWinRTKeyInputView alloc] initWithFrame:CGRectZero];
        keyView.hidden = YES;
        __weak typeof(self) weakSelf = self;
        keyView.onKeyQcode = ^(int qcode, int down) {
            __strong typeof(weakSelf) s = weakSelf;
            if (s && s->_pfnWinrtKeyQcode) {
                s->_pfnWinrtKeyQcode(qcode, down);
            }
        };
        keyView.onAfterNonModifierKey = ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) [s releaseWinRTStickyModifiers];
        };
        keyView.customInputAccessoryView = [self buildWinRTInputAccessoryBar];
        [self.view addSubview:keyView];
        self.winrtKeyInputView = keyView;
        [self syncWinRTModifierUI];
    }

    NSArray *stackItems = nil;
    if (_isUbuntuTouchVirtMode) {
        stackItems = @[self.collapseButton, self.winrtKeyboardButton, self.winrtQuickKeysButton, self.moreMenuButton];
        self.winrtInputModeButton.hidden = YES;
        self.winrtDragButton.hidden = YES;
        self.winrtResetUsbButton.hidden = YES;
        self.backButton.hidden = YES;
        self.homeButton.hidden = YES;
        self.menuButton.hidden = YES;
        self.powerButton.hidden = YES;
        self.volDownButton.hidden = YES;
        self.volUpButton.hidden = YES;
    } else if (_isChromeOSMode) {
        stackItems = @[self.collapseButton, self.winrtInputModeButton, self.winrtDragButton, self.winrtKeyboardButton, self.winrtQuickKeysButton, self.moreMenuButton];
        self.winrtResetUsbButton.hidden = YES;
        self.backButton.hidden = YES;
        self.homeButton.hidden = YES;
        self.menuButton.hidden = YES;
        self.powerButton.hidden = YES;
        self.volDownButton.hidden = YES;
        self.volUpButton.hidden = YES;
    } else if (_isWinRTMode) {
        stackItems = @[self.collapseButton, self.winrtInputModeButton, self.winrtDragButton, self.winrtKeyboardButton, self.winrtQuickKeysButton, self.winrtResetUsbButton, self.moreMenuButton];
        self.backButton.hidden = YES;
        self.homeButton.hidden = YES;
        self.menuButton.hidden = YES;
        self.powerButton.hidden = YES;
        self.volDownButton.hidden = YES;
        self.volUpButton.hidden = YES;
    } else {
        stackItems = _isAndroidMode
            ? @[self.collapseButton, self.backButton, self.homeButton, self.menuButton, self.powerButton, self.volDownButton, self.volUpButton, self.moreMenuButton]
            : @[self.collapseButton, self.homeButton, self.powerButton, self.volDownButton, self.volUpButton, self.moreMenuButton];
        self.backButton.hidden = !_isAndroidMode;
        self.menuButton.hidden = !_isAndroidMode;
        self.homeButton.hidden = NO;
    }
    self.hardwareStack = [[UIStackView alloc] initWithArrangedSubviews:stackItems];
    self.hardwareStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.hardwareStack.axis = UILayoutConstraintAxisHorizontal;
    self.hardwareStack.distribution = UIStackViewDistributionFill;
    self.hardwareStack.alignment = UIStackViewAlignmentCenter;
    self.hardwareStack.spacing = 4.0;
    [self.hardwareBar addSubview:self.hardwareStack];

    self.barLeadingConstraint = [self.hardwareBar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16.0];
    self.barBottomConstraint = [self.hardwareBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8.0];
    self.barHeightConstraint = [self.hardwareBar.heightAnchor constraintEqualToConstant:36.0];
    self.stackLeadingConstraint = [self.hardwareStack.leadingAnchor constraintEqualToAnchor:self.hardwareBar.leadingAnchor constant:7.0];
    self.stackTrailingConstraint = [self.hardwareStack.trailingAnchor constraintEqualToAnchor:self.hardwareBar.trailingAnchor constant:-7.0];

    [NSLayoutConstraint activateConstraints:@[
        self.barLeadingConstraint,
        self.barBottomConstraint,
        self.barHeightConstraint,
        self.stackLeadingConstraint,
        self.stackTrailingConstraint,
        [self.hardwareStack.centerYAnchor constraintEqualToAnchor:self.hardwareBar.centerYAnchor]
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuPan:)];
    pan.delaysTouchesBegan = NO;
    pan.cancelsTouchesInView = NO;
    [self.hardwareBar addGestureRecognizer:pan];
}

- (void)applyPreferredBarPositionAnimated:(BOOL)animated {
    CGRect safe = self.view.safeAreaLayoutGuide.layoutFrame;
    if (safe.size.width <= 0 || safe.size.height <= 0) return;

    [self.view layoutIfNeeded];
    CGFloat barW = self.hardwareBar.bounds.size.width;
    CGFloat barH = self.barHeightConstraint.constant;
    if (barW <= 0) return;

    CGRect guest = [self guestScreenRectInView];
    CGFloat bottomMargin = CGRectGetMaxY(safe) - CGRectGetMaxY(guest);
    CGFloat topMargin = CGRectGetMinY(guest) - CGRectGetMinY(safe);

    CGFloat targetLeading = self.barCollapsed
        ? self.barLeadingConstraint.constant
        : MAX(8.0, (safe.size.width - barW) * 0.5);
    CGFloat targetBottom = self.barBottomConstraint.constant;

    if (self.menuPositionMode == ClassicMenuPositionAutoBottom) {
        if (bottomMargin >= barH + 4.0) {
            targetBottom = -MAX(4.0, (bottomMargin - barH) * 0.5);
        } else if (topMargin >= barH + 4.0) {
            targetBottom = -(safe.size.height - MAX(4.0, (topMargin - barH) * 0.5) - barH);
        } else {
            targetBottom = -8.0;
        }
    } else if (self.menuPositionMode == ClassicMenuPositionAutoTop) {
        if (topMargin >= barH + 4.0) {
            targetBottom = -(safe.size.height - MAX(4.0, (topMargin - barH) * 0.5) - barH);
        } else if (bottomMargin >= barH + 4.0) {
            targetBottom = -MAX(4.0, (bottomMargin - barH) * 0.5);
        } else {
            targetBottom = -(safe.size.height - barH - 8.0);
        }
    } else {
        targetLeading = self.barLeadingConstraint.constant;
    }

    void (^applyBlock)(void) = ^{
        self.barLeadingConstraint.constant = targetLeading;
        self.barBottomConstraint.constant = targetBottom;
        [self clampHardwareBarToSafeArea];
        [self.view layoutIfNeeded];
    };

    if (animated) {
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:applyBlock completion:nil];
    } else {
        applyBlock();
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize currentSize = self.view.bounds.size;
    UIEdgeInsets currentSafe = self.view.safeAreaInsets;
    BOOL geometryChanged = !self.hasLastLayoutGeometry ||
        !CGSizeEqualToSize(self.lastLayoutViewSize, currentSize) ||
        !UIEdgeInsetsEqualToEdgeInsets(self.lastLayoutSafeInsets, currentSafe);

    if (!self.hasInitializedBarPosition && self.hardwareBar.bounds.size.width > 0) {
        self.hasInitializedBarPosition = YES;
        self.lastLayoutViewSize = currentSize;
        self.lastLayoutSafeInsets = currentSafe;
        self.hasLastLayoutGeometry = YES;
        [self applyPreferredBarPositionAnimated:NO];
    } else if (geometryChanged && self.hardwareBar.bounds.size.width > 0) {
        self.lastLayoutViewSize = currentSize;
        self.lastLayoutSafeInsets = currentSafe;
        self.hasLastLayoutGeometry = YES;
        [self updateMetalDisplayRotation];
        if (!self.userMovedBarManually && self.menuPositionMode != ClassicMenuPositionCustom) {
            [self applyPreferredBarPositionAnimated:NO];
        } else {
            [self clampHardwareBarToSafeArea];
        }
    } else if (self.hardwareBar.bounds.size.width > 0) {
        [self clampHardwareBarToSafeArea];
    }
}

- (void)clampHardwareBarToSafeArea {
    CGRect safe = self.view.safeAreaLayoutGuide.layoutFrame;
    if (safe.size.width <= 0 || safe.size.height <= 0) return;
    CGFloat barW = self.hardwareBar.bounds.size.width;
    CGFloat barH = self.barHeightConstraint.constant;
    CGFloat maxLeading = MAX(8.0, safe.size.width - barW - 8.0);
    if (self.barLeadingConstraint.constant < 8.0) self.barLeadingConstraint.constant = 8.0;
    if (self.barLeadingConstraint.constant > maxLeading) self.barLeadingConstraint.constant = maxLeading;

    CGFloat minBottom = -(safe.size.height - barH - 6.0);
    CGFloat maxBottom = -6.0;
    if (self.barBottomConstraint.constant < minBottom) self.barBottomConstraint.constant = minBottom;
    if (self.barBottomConstraint.constant > maxBottom) self.barBottomConstraint.constant = maxBottom;
}

- (void)handleMenuPan:(UIPanGestureRecognizer *)pan {
    CGPoint tr = [pan translationInView:self.view];
    [pan setTranslation:CGPointZero inView:self.view];

    self.hasInitializedBarPosition = YES;
    self.userMovedBarManually = YES;
    self.hasSavedCollapsedLeading = NO;
    self.menuPositionMode = ClassicMenuPositionCustom;

    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        self.barLeadingConstraint.constant += tr.x;
        self.barBottomConstraint.constant += tr.y;
        [self clampHardwareBarToSafeArea];
        [self.view layoutIfNeeded];
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        [self clampHardwareBarToSafeArea];
        [self.view layoutIfNeeded];
        [self refreshMoreMenu];
    }
}

- (void)toggleHardwareBar:(id)sender {
    [_haptic impactOccurred];
    [self.view layoutIfNeeded];

    CGRect safe = self.view.safeAreaLayoutGuide.layoutFrame;
    CGFloat oldLeading = self.barLeadingConstraint.constant;
    CGFloat oldWidth = (self.hardwareBar.bounds.size.width > 0.0) ? self.hardwareBar.bounds.size.width : 32.0;

    self.barCollapsed = !self.barCollapsed;
    NSArray *items = nil;
    if (_isWinRTMode) {
        items = @[self.winrtInputModeButton, self.winrtKeyboardButton, self.winrtQuickKeysButton, self.winrtResetUsbButton, self.moreMenuButton];
    } else {
        items = _isAndroidMode
            ? @[self.backButton, self.homeButton, self.menuButton, self.powerButton, self.volDownButton, self.volUpButton, self.moreMenuButton]
            : @[self.homeButton, self.powerButton, self.volDownButton, self.volUpButton, self.moreMenuButton];
    }
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:(self.barCollapsed ? 14.0 : 12.0) weight:UIImageSymbolWeightSemibold];

    CGFloat targetLeading = oldLeading;
    CGFloat targetBottom = self.barBottomConstraint.constant + (self.barCollapsed ? -2.0 : 2.0);
    NSString *iconName = @"ellipsis";

    if (self.barCollapsed) {
        BOOL wasTrailing = self.collapseButtonOnTrailing;
        if (self.hasSavedCollapsedLeading) {
            targetLeading = self.savedCollapsedLeading;
            self.hasSavedCollapsedLeading = NO;
        } else if (wasTrailing) {
            targetLeading = oldLeading + oldWidth - 32.0;
        }
        iconName = @"ellipsis";
    } else {
        self.savedCollapsedLeading = oldLeading;
        self.hasSavedCollapsedLeading = YES;
        BOOL onRightHalf = (safe.size.width > 0.0) && ((oldLeading + oldWidth * 0.5) > (safe.size.width * 0.5));
        self.collapseButtonOnTrailing = onRightHalf;
        [self.hardwareStack removeArrangedSubview:self.collapseButton];
        if (onRightHalf) {
            [self.hardwareStack addArrangedSubview:self.collapseButton];
            iconName = @"chevron.right";
        } else {
            [self.hardwareStack insertArrangedSubview:self.collapseButton atIndex:0];
            iconName = @"chevron.left";
        }
    }

    UIButtonConfiguration *cfg = self.collapseButton.configuration;
    cfg.image = [UIImage systemImageNamed:iconName withConfiguration:config];
    self.collapseButton.configuration = cfg;

    for (UIView *v in items) {
        v.hidden = self.barCollapsed;
    }
    self.collapseWidthConstraint.constant = self.barCollapsed ? 28.0 : 24.0;
    self.barHeightConstraint.constant = self.barCollapsed ? 32.0 : 36.0;
    self.stackLeadingConstraint.constant = self.barCollapsed ? 2.0 : 7.0;
    self.stackTrailingConstraint.constant = self.barCollapsed ? -2.0 : -7.0;
    CGFloat radius = self.barCollapsed ? 16.0 : 18.0;
    self.hardwareBar.layer.cornerRadius = radius;
    self.barBlurView.layer.cornerRadius = radius;

    if (!self.barCollapsed) {
        CGFloat expandedWidth = [self.hardwareBar systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].width;
        if (self.collapseButtonOnTrailing) {
            targetLeading = (oldLeading + oldWidth) - expandedWidth;
        }
    }

    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        for (UIView *v in items) {
            v.alpha = self.barCollapsed ? 0.0 : 1.0;
        }
        self.barLeadingConstraint.constant = targetLeading;
        self.barBottomConstraint.constant = targetBottom;
        [self.view layoutIfNeeded];
        [self clampHardwareBarToSafeArea];
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (BOOL)canBecomeFirstResponder {
    return _isWinRTMode || [super canBecomeFirstResponder];
}

- (BOOL)hasActiveWinRTStickyModifier {
    return _winrtModCtrl || _winrtModAlt || _winrtModShift || _winrtModWin;
}

- (void)syncWinRTModifierUI {
    if (!_isWinRTMode) return;
    BOOL anyMod = [self hasActiveWinRTStickyModifier];
    self.winrtQuickKeysButton.tintColor = anyMod ? [UIColor systemCyanColor] : [UIColor whiteColor];
    self.winrtQuickKeysButton.menu = [self buildWinRTQuickKeysMenu];

    if ([self.winrtKeyInputView isKindOfClass:[ClassicWinRTKeyInputView class]]) {
        ((ClassicWinRTKeyInputView *)self.winrtKeyInputView).externalShiftHeld = _winrtModShift;
    }

    NSDictionary<NSNumber *, NSNumber *> *stateMap = @{
        @5: @(_winrtModCtrl),
        @3: @(_winrtModAlt),
        @1: @(_winrtModShift),
        @117: @(_winrtModWin),
    };
    for (NSNumber *qKey in self.winrtAccessoryModButtons) {
        UIButton *btn = self.winrtAccessoryModButtons[qKey];
        BOOL active = stateMap[qKey].boolValue;
        btn.backgroundColor = active
            ? [UIColor systemCyanColor]
            : [UIColor colorWithWhite:0.26 alpha:1.0];
        [btn setTitleColor:(active ? [UIColor blackColor] : [UIColor whiteColor])
                  forState:UIControlStateNormal];
    }
}

- (void)toggleWinRTStickyModifierQCode:(int)qcode {
    if (!_isWinRTMode || !_pfnWinrtKeyQcode) return;
    BOOL *flag = NULL;
    if (qcode == 5) flag = &_winrtModCtrl;
    else if (qcode == 3) flag = &_winrtModAlt;
    else if (qcode == 1) flag = &_winrtModShift;
    else if (qcode == 117) flag = &_winrtModWin;
    if (!flag) return;

    *flag = !(*flag);
    _pfnWinrtKeyQcode(qcode, *flag ? 1 : 0);
    [self syncWinRTModifierUI];
}

- (void)releaseWinRTStickyModifiers {
    if (!_isWinRTMode) return;
    BOOL changed = NO;
    if (_winrtModCtrl)  { _winrtModCtrl = NO;  if (_pfnWinrtKeyQcode) _pfnWinrtKeyQcode(5, 0);   changed = YES; }
    if (_winrtModAlt)   { _winrtModAlt = NO;   if (_pfnWinrtKeyQcode) _pfnWinrtKeyQcode(3, 0);   changed = YES; }
    if (_winrtModShift) { _winrtModShift = NO; if (_pfnWinrtKeyQcode) _pfnWinrtKeyQcode(1, 0);   changed = YES; }
    if (_winrtModWin)   { _winrtModWin = NO;   if (_pfnWinrtKeyQcode) _pfnWinrtKeyQcode(117, 0); changed = YES; }
    if (changed) {
        [self syncWinRTModifierUI];
    }
}

- (void)sendWinRTQuickQCode:(int)qcode {
    if (!_pfnWinrtKeyQcode || qcode <= 0) return;
    _pfnWinrtKeyQcode(qcode, 1);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_pfnWinrtKeyQcode) {
            s->_pfnWinrtKeyQcode(qcode, 0);
        }
        if (s) {
            [s releaseWinRTStickyModifiers];
        }
    });
}

- (void)sendWinRTComboQCodes:(const int *)qcodes count:(size_t)count {
    if (!_isWinRTMode || !_pfnWinrtKeyQcode || !qcodes || count == 0) return;
    NSMutableArray<NSNumber *> *seq = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        int q = qcodes[i];
        if (q > 0) {
            _pfnWinrtKeyQcode(q, 1);
            [seq addObject:@(q)];
        }
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(55 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_pfnWinrtKeyQcode) {
            for (NSInteger i = (NSInteger)seq.count - 1; i >= 0; i--) {
                s->_pfnWinrtKeyQcode(seq[(NSUInteger)i].intValue, 0);
            }
        }
        if (s) {
            [s releaseWinRTStickyModifiers];
        }
    });
}

- (void)winrtAccessoryKeyTapped:(UIButton *)sender {
    [_haptic impactOccurred];
    int tag = (int)sender.tag;
    if (tag == -1) {
        [self toggleWinRTKeyboardTapped:sender];
        return;
    }
    if (tag == 5 || tag == 3 || tag == 1 || tag == 117) {
        [self toggleWinRTStickyModifierQCode:tag];
    } else if (tag > 0) {
        [self sendWinRTQuickQCode:tag];
    }
}

- (UIView *)buildWinRTInputAccessoryBar {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, 42.0)];
    bar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    [bar addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 6.0;
    stack.alignment = UIStackViewAlignmentCenter;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-8.0],
        [stack.topAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.bottomAnchor],
    ]];

    struct { NSString *title; int qcode; BOOL isMod; } keys[] = {
        { @"Esc", 8, NO },
        { @"Tab", 22, NO },
        { @"Ctrl", 5, YES },
        { @"Alt", 3, YES },
        { @"Shift", 1, YES },
        { @"Win", 117, YES },
        { @"↑", 100, NO },
        { @"↓", 101, NO },
        { @"←", 99, NO },
        { @"→", 102, NO },
        { @"Del", 104, NO },
        { @"Home", 95, NO },
        { @"End", 98, NO },
        { @"PgUp", 96, NO },
        { @"PgDn", 97, NO },
        { @"Ins", 103, NO },
        { @"F1", 62, NO }, { @"F2", 63, NO }, { @"F3", 64, NO }, { @"F4", 65, NO },
        { @"F5", 66, NO }, { @"F6", 67, NO }, { @"F7", 68, NO }, { @"F8", 69, NO },
        { @"F9", 70, NO }, { @"F10", 71, NO }, { @"F11", 92, NO }, { @"F12", 93, NO },
        { @"▼", -1, NO },
    };
    NSMutableDictionary<NSNumber *, UIButton *> *modBtns = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.tag = keys[i].qcode;
        [btn setTitle:keys[i].title forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        btn.backgroundColor = [UIColor colorWithWhite:0.26 alpha:1.0];
        btn.layer.cornerRadius = 6.0;
        btn.contentEdgeInsets = UIEdgeInsetsMake(5.0, 10.0, 5.0, 10.0);
        [btn addTarget:self action:@selector(winrtAccessoryKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:btn];
        if (keys[i].isMod) {
            modBtns[@(keys[i].qcode)] = btn;
        }
    }
    self.winrtAccessoryModButtons = [modBtns copy];
    return bar;
}

- (UIMenu *)buildWinRTQuickKeysMenu {
    __weak typeof(self) weakSelf = self;

    UIAction * (^makeModAction)(NSString *, int, BOOL) = ^UIAction *(NSString *title, int qcode, BOOL active) {
        UIAction *act = [UIAction actionWithTitle:title
                                            image:[UIImage systemImageNamed:(active ? @"checkmark.circle.fill" : @"circle")]
                                       identifier:nil
                                          handler:^(__kindof UIAction *action) {
            [weakSelf toggleWinRTStickyModifierQCode:qcode];
        }];
        act.state = active ? UIMenuElementStateOn : UIMenuElementStateOff;
        return act;
    };

    NSMutableArray<UIMenuElement *> *modItems = [NSMutableArray arrayWithArray:@[
        makeModAction(@"Ctrl", 5, _winrtModCtrl),
        makeModAction(@"Alt", 3, _winrtModAlt),
        makeModAction(@"Shift", 1, _winrtModShift),
        makeModAction(@"Win", 117, _winrtModWin),
    ]];
    if ([self hasActiveWinRTStickyModifier]) {
        [modItems addObject:[UIAction actionWithTitle:L(@"winrt_sticky_clear")
                                                image:[UIImage systemImageNamed:@"xmark.circle"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *action) {
            [weakSelf releaseWinRTStickyModifiers];
        }]];
    }
    UIMenu *modsMenu = [UIMenu menuWithTitle:L(@"winrt_sticky_mods_section")
                                       image:[UIImage systemImageNamed:@"command.square"]
                                  identifier:nil
                                     options:0
                                    children:modItems];

    UIAction *winAct = [UIAction actionWithTitle:@"Win" image:[UIImage systemImageNamed:@"window.casement"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf sendWinRTQuickQCode:117];
    }];
    UIAction *winXAct = [UIAction actionWithTitle:@"Win + X" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        const int c[] = { 117, 50 };
        [weakSelf sendWinRTComboQCodes:c count:2];
    }];
    UIAction *winRAct = [UIAction actionWithTitle:@"Win + R" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        const int c[] = { 117, 26 };
        [weakSelf sendWinRTComboQCodes:c count:2];
    }];
    UIAction *winEAct = [UIAction actionWithTitle:@"Win + E" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        const int c[] = { 117, 25 };
        [weakSelf sendWinRTComboQCodes:c count:2];
    }];
    UIAction *winDAct = [UIAction actionWithTitle:@"Win + D" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        const int c[] = { 117, 38 };
        [weakSelf sendWinRTComboQCodes:c count:2];
    }];
    UIAction *altTabAct = [UIAction actionWithTitle:@"Alt + Tab" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        const int c[] = { 3, 22 };
        [weakSelf sendWinRTComboQCodes:c count:2];
    }];
    UIAction *altF4Act = [UIAction actionWithTitle:@"Alt + F4" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        const int c[] = { 3, 65 };
        [weakSelf sendWinRTComboQCodes:c count:2];
    }];
    UIAction *ctrlShiftEscAct = [UIAction actionWithTitle:@"Ctrl + Shift + Esc" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        const int c[] = { 5, 1, 8 };
        [weakSelf sendWinRTComboQCodes:c count:3];
    }];
    UIAction *cadAct = [UIAction actionWithTitle:@"Ctrl + Alt + Del" image:[UIImage systemImageNamed:@"keyboard.chevron.compact.down"] identifier:nil handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_pfnWinrtSendCad) {
            [s releaseWinRTStickyModifiers];
            s->_pfnWinrtSendCad();
            [s showToastBannerWithText:@"Ctrl + Alt + Del" icon:@"keyboard"];
        }
    }];
    UIAction *rightClickAct = [UIAction actionWithTitle:L(@"winrt_right_click_action")
                                                  image:[UIImage systemImageNamed:@"contextualmenu.and.cursorarrow"]
                                             identifier:nil
                                                handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_pfnWinrtPointerAbs) {
            int ax = (int)lroundf(s->_winrtCursorX * 32767.0f);
            int ay = (int)lroundf(s->_winrtCursorY * 32767.0f);
            s->_pfnWinrtPointerAbs(ax, ay, 2);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s2 = weakSelf;
                if (s2 && s2->_pfnWinrtPointerAbs && __atomic_load_n(&s2->_isEmulating, __ATOMIC_ACQUIRE)) {
                    s2->_pfnWinrtPointerAbs(ax, ay, 0);
                }
                if (s2) [s2 releaseWinRTStickyModifiers];
            });
        }
    }];

    struct { NSString *title; int qcode; } navKeys[] = {
        { @"Esc", 8 }, { @"Tab", 22 }, { @"Enter", 35 }, { @"Backspace", 21 },
        { @"Delete", 104 }, { @"Insert", 103 }, { @"Home", 95 }, { @"End", 98 },
        { @"Page Up", 96 }, { @"Page Down", 97 }, { @"PrtSc", 94 }, { @"Pause", 120 },
        { @"↑", 100 }, { @"↓", 101 }, { @"←", 99 }, { @"→", 102 },
    };
    NSMutableArray<UIAction *> *navActs = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(navKeys) / sizeof(navKeys[0]); i++) {
        int qcode = navKeys[i].qcode;
        [navActs addObject:[UIAction actionWithTitle:navKeys[i].title image:nil identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf sendWinRTQuickQCode:qcode];
        }]];
    }
    UIMenu *navMenu = [UIMenu menuWithTitle:L(@"winrt_special_nav_menu")
                                      image:[UIImage systemImageNamed:@"arrow.up.arrow.down.square"]
                                 identifier:nil
                                    options:0
                                   children:navActs];

    struct { NSString *title; int qcode; } fnKeys[] = {
        { @"F1", 62 }, { @"F2", 63 }, { @"F3", 64 }, { @"F4", 65 },
        { @"F5", 66 }, { @"F6", 67 }, { @"F7", 68 }, { @"F8", 69 },
        { @"F9", 70 }, { @"F10", 71 }, { @"F11", 92 }, { @"F12", 93 },
    };
    NSMutableArray<UIAction *> *fnActs = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(fnKeys) / sizeof(fnKeys[0]); i++) {
        int qcode = fnKeys[i].qcode;
        [fnActs addObject:[UIAction actionWithTitle:fnKeys[i].title image:nil identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf sendWinRTQuickQCode:qcode];
        }]];
    }
    UIMenu *fnMenu = [UIMenu menuWithTitle:L(@"winrt_fn_keys_menu")
                                     image:[UIImage systemImageNamed:@"fn"]
                                identifier:nil
                                   options:0
                                  children:fnActs];

    NSArray<UIMenuElement *> *shortcutChildren = _isUbuntuTouchVirtMode
        ? @[winAct, altTabAct]
        : @[winAct, winXAct, winRAct, winEAct, winDAct, altTabAct, altF4Act, ctrlShiftEscAct, cadAct, rightClickAct];
    UIMenu *shortcutGroup = [UIMenu menuWithTitle:@""
                                            image:nil
                                       identifier:nil
                                          options:UIMenuOptionsDisplayInline
                                         children:shortcutChildren];
    return [UIMenu menuWithTitle:L(@"winrt_quick_keys") children:@[modsMenu, shortcutGroup, navMenu, fnMenu]];
}

- (void)toggleWinRTInputModeTapped:(id)sender {
    [_haptic impactOccurred];
    if (!_isWinRTMode) return;
    _winrtMouseMode = !_winrtMouseMode;
    _winrtTrackGen++;
    _winrtTrackLeftDrag = NO;
    _winrtMouseDragLock = NO;
    _winrtTrackRightSent = NO;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
    UIImage *icon = [UIImage systemImageNamed:(_winrtMouseMode ? @"computermouse.fill" : @"hand.tap") withConfiguration:cfg];
    [self.winrtInputModeButton setImage:icon forState:UIControlStateNormal];
    self.winrtInputModeButton.tintColor = _winrtMouseMode ? [UIColor systemCyanColor] : [UIColor whiteColor];
    self.winrtDragButton.hidden = !_winrtMouseMode;
    self.winrtDragButton.tintColor = [UIColor whiteColor];
    if (_pfnWinrtPointerAbs) {
        int ax = (int)lroundf(_winrtCursorX * 32767.0f);
        int ay = (int)lroundf(_winrtCursorY * 32767.0f);
        _pfnWinrtPointerAbs(ax, ay, 0);
    }
    [self refreshMoreMenu];
    [self showToastBannerWithText:(_winrtMouseMode ? L(@"winrt_mode_mouse_toast") : L(@"winrt_mode_touch_toast"))
                             icon:(_winrtMouseMode ? @"computermouse.fill" : @"hand.tap")];
}

- (void)toggleWinRTDragLockTapped:(id)sender {
    [_haptic impactOccurred];
    if (!_isWinRTMode || !_winrtMouseMode) return;
    _winrtMouseDragLock = !_winrtMouseDragLock;
    _winrtTrackGen++;
    _winrtTrackLeftDrag = NO;
    self.winrtDragButton.tintColor = _winrtMouseDragLock ? [UIColor systemCyanColor] : [UIColor whiteColor];
    if (_pfnWinrtPointerAbs) {
        int ax = (int)lroundf(_winrtCursorX * 32767.0f);
        int ay = (int)lroundf(_winrtCursorY * 32767.0f);
        _pfnWinrtPointerAbs(ax, ay, _winrtMouseDragLock ? 1 : 0);
    }
    [self showToastBannerWithText:(_winrtMouseDragLock ? @"ドラッグ固定 ON（左ボタン押下中）" : @"ドラッグ固定 OFF")
                             icon:@"hand.draw"];
}

- (void)toggleWinRTKeyboardTapped:(id)sender {
    [_haptic impactOccurred];
    if (!self.winrtKeyInputView) return;
    if ([self.winrtKeyInputView isFirstResponder]) {
        [self.winrtKeyInputView resignFirstResponder];
        [self becomeFirstResponder];
    } else {
        [self.winrtKeyInputView becomeFirstResponder];
    }
}

- (void)resetWinRTUSBInputTapped:(id)sender {
    [_haptic impactOccurred];
    [self releaseWinRTStickyModifiers];
    if (_pfnWinrtResetUsb) {
        _pfnWinrtResetUsb();
    }
    [self showToastBannerWithText:L(@"winrt_usb_reset_toast") icon:@"arrow.triangle.2.circlepath"];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    if (_isWinRTMode && _pfnWinrtKeyQcode) {
        for (UIPress *press in presses) {
            if (!press.key) continue;
            int qcode = ClassicWinRTQCodeForHIDUsage(press.key.keyCode);
            if (qcode > 0) {
                _pfnWinrtKeyQcode(qcode, 1);
                handled = YES;
            }
        }
    }
    if (!handled) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    BOOL releasedNonMod = NO;
    if (_isWinRTMode && _pfnWinrtKeyQcode) {
        for (UIPress *press in presses) {
            if (!press.key) continue;
            int qcode = ClassicWinRTQCodeForHIDUsage(press.key.keyCode);
            if (qcode > 0) {
                _pfnWinrtKeyQcode(qcode, 0);
                handled = YES;
                if (qcode != 1 && qcode != 2 && qcode != 3 && qcode != 4 &&
                    qcode != 5 && qcode != 6 && qcode != 117 && qcode != 118) {
                    releasedNonMod = YES;
                }
            }
        }
    }
    if (releasedNonMod) {
        [self releaseWinRTStickyModifiers];
    }
    if (!handled) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (_isWinRTMode && _pfnWinrtKeyQcode) {
        for (UIPress *press in presses) {
            if (!press.key) continue;
            int qcode = ClassicWinRTQCodeForHIDUsage(press.key.keyCode);
            if (qcode > 0) {
                _pfnWinrtKeyQcode(qcode, 0);
            }
        }
    }
    [super pressesCancelled:presses withEvent:event];
}

- (UIButton *)createHardwareButton:(NSString *)symbolName action:(SEL)downAction upAction:(nullable SEL)upAction {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:symbolName withConfiguration:config];
    [btn setImage:img forState:UIControlStateNormal];
    btn.tintColor = [UIColor whiteColor];

    if (downAction) {
        [btn addTarget:self action:downAction forControlEvents:UIControlEventTouchDown];
    }
    if (upAction) {
        [btn addTarget:self action:upAction forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    } else if (downAction) {
        [btn removeTarget:self action:downAction forControlEvents:UIControlEventTouchDown];
        [btn addTarget:self action:downAction forControlEvents:UIControlEventTouchUpInside];
    }
    return btn;
}

- (void)setupTelemetryHUD {
    BOOL isGlass = NO;
    UIVisualEffect *effect = ClassicCreateGlassEffect(UIBlurEffectStyleSystemUltraThinMaterialDark, NO, &isGlass);
    self.telemetryCard = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.telemetryCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.telemetryCard.layer.cornerRadius = 14.0;
    self.telemetryCard.layer.masksToBounds = YES;
    if (!isGlass) {
        self.telemetryCard.layer.borderWidth = 0.5;
        self.telemetryCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;
    }
    self.telemetryCard.hidden = YES;
    self.telemetryCard.userInteractionEnabled = NO;
    [self.view addSubview:self.telemetryCard];
    if (self.hardwareBar) {
        [self.view bringSubviewToFront:self.hardwareBar];
    }

    self.telemetryLabel = [[UILabel alloc] init];
    self.telemetryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.telemetryLabel.backgroundColor = [UIColor clearColor];
    self.telemetryLabel.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.55 alpha:1.0];
    self.telemetryLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightMedium];
    self.telemetryLabel.numberOfLines = 0;
    [self.telemetryCard.contentView addSubview:self.telemetryLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.telemetryCard.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12.0],
        [self.telemetryCard.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
        [self.telemetryCard.widthAnchor constraintLessThanOrEqualToConstant:310.0],
        [self.telemetryLabel.topAnchor constraintEqualToAnchor:self.telemetryCard.contentView.topAnchor constant:8.0],
        [self.telemetryLabel.bottomAnchor constraintEqualToAnchor:self.telemetryCard.contentView.bottomAnchor constant:-8.0],
        [self.telemetryLabel.leadingAnchor constraintEqualToAnchor:self.telemetryCard.contentView.leadingAnchor constant:10.0],
        [self.telemetryLabel.trailingAnchor constraintEqualToAnchor:self.telemetryCard.contentView.trailingAnchor constant:-10.0]
    ]];

    self.telemetryTimer = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateTelemetry)];
    self.telemetryTimer.preferredFramesPerSecond = ([NSProcessInfo processInfo].physicalMemory <= 2684354560ULL) ? 2 : 4;
    self.telemetryTimer.paused = self.telemetryCard.hidden;
    [self.telemetryTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)toggleHUD:(id)sender {
    [_haptic impactOccurred];
    self.telemetryCard.hidden = !self.telemetryCard.hidden;
    self.telemetryTimer.paused = self.telemetryCard.hidden;
    if (!self.telemetryCard.hidden) {
        [self updateTelemetry];
    }
}

#pragma mark - IPA Install

- (void)setupIpaProgressHUD {
    BOOL isGlass = NO;
    UIVisualEffect *effect = ClassicCreateGlassEffect(UIBlurEffectStyleSystemUltraThinMaterialDark, NO, &isGlass);
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:effect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 14.0;
    card.layer.masksToBounds = YES;
    if (!isGlass) {
        card.layer.borderWidth = 0.5;
        card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;
    }
    card.hidden = YES;
    [self.view addSubview:card];
    if (self.hardwareBar) {
        [self.view bringSubviewToFront:self.hardwareBar];
    }
    self.ipaProgressCard = card;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    lbl.numberOfLines = 2;
    [card.contentView addSubview:lbl];
    self.ipaProgressLabel = lbl;

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
    [cancelBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:symCfg] forState:UIControlStateNormal];
    cancelBtn.tintColor = [UIColor colorWithWhite:1.0 alpha:0.78];
    [cancelBtn addTarget:self action:@selector(cancelIpaInstallTapped:) forControlEvents:UIControlEventTouchUpInside];
    [card.contentView addSubview:cancelBtn];
    self.ipaCancelButton = cancelBtn;

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.progressTintColor = [UIColor systemBlueColor];
    bar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    [card.contentView addSubview:bar];
    self.ipaProgressBar = bar;

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10.0],
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
        [card.widthAnchor constraintLessThanOrEqualToConstant:320.0],

        [lbl.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:10.0],
        [lbl.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:12.0],
        [lbl.trailingAnchor constraintEqualToAnchor:cancelBtn.leadingAnchor constant:-8.0],

        [cancelBtn.centerYAnchor constraintEqualToAnchor:lbl.centerYAnchor],
        [cancelBtn.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-10.0],
        [cancelBtn.widthAnchor constraintEqualToConstant:26.0],
        [cancelBtn.heightAnchor constraintEqualToConstant:26.0],

        [bar.topAnchor constraintEqualToAnchor:lbl.bottomAnchor constant:8.0],
        [bar.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:12.0],
        [bar.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-12.0],
        [bar.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-10.0]
    ]];
}

- (void)cancelIpaInstallTapped:(id)sender {
    [_haptic impactOccurred];
    self.ipaInstallCancelRequested = YES;
    self.ipaCancelButton.enabled = NO;
    self.ipaProgressLabel.text = L(@"ipa_cancelling");
    if (_isAndroidMode && self.androidAdbClient) {
        [self.androidAdbClient cancelInstall];
    }
}

- (void)installAPKTapped:(id)sender {
    [_haptic impactOccurred];
    if (self.ipaInstallInFlight) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"menu_install_apk")
                                                                       message:L(@"apk_install_in_progress")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    AEADBClient *adb = self.androidAdbClient;
    if (!adb || !adb.ready) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"menu_install_apk")
                                                                       message:L(@"apk_install_not_ready")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSMutableArray<UTType *> *types = [NSMutableArray array];
    UTType *apkType = [UTType typeWithFilenameExtension:@"apk"];
    if (apkType) [types addObject:apkType];
    [types addObject:UTTypeData];

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)handlePickedAPKURL:(NSURL *)pickedURL {
    if (![[pickedURL.pathExtension lowercaseString] isEqualToString:@"apk"]) {
        [[NSFileManager defaultManager] removeItemAtURL:pickedURL error:nil];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"apk_install_failed_title")
                                                                       message:L(@"apk_invalid_extension")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    AEADBClient *adb = self.androidAdbClient;
    if (!adb || !adb.ready) {
        [[NSFileManager defaultManager] removeItemAtURL:pickedURL error:nil];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"apk_install_failed_title")
                                                                       message:L(@"apk_install_not_ready")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.ipaInstallInFlight = YES;
    self.ipaInstallCancelRequested = NO;
    self.ipaCancelButton.enabled = YES;
    self.ipaCancelButton.hidden = NO;
    self.ipaProgressBar.progress = 0.0f;
    self.ipaProgressLabel.text = L(@"apk_preparing");
    self.ipaProgressCard.hidden = NO;
    if (self.hardwareBar) {
        [self.view bringSubviewToFront:self.hardwareBar];
    }

    __weak typeof(self) weakSelf = self;
    [adb installAPKAtURL:pickedURL
                progress:^(NSString *statusText, float progress) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s.ipaProgressLabel.text = statusText;
        s.ipaProgressBar.progress = progress;
    }
              completion:^(BOOL success, NSString *message) {
        __strong typeof(weakSelf) s = weakSelf;
        [[NSFileManager defaultManager] removeItemAtURL:pickedURL error:nil];
        if (!s) return;
        s.ipaInstallInFlight = NO;
        s.ipaProgressCard.hidden = YES;

        NSString *title = success ? L(@"apk_install_success_title") : L(@"apk_install_failed_title");
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [s presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)installIPATapped:(id)sender {
    [_haptic impactOccurred];
    if (self.ipaInstallInFlight) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"menu_install_ipa")
                                                                       message:L(@"ipa_install_in_progress")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    IOSUsbMuxBridge *bridge = self.usbBridge;
    if (!bridge || !bridge.deviceAttached) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"menu_install_ipa")
                                                                       message:L(@"ipa_install_not_ready")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSMutableArray<UTType *> *types = [NSMutableArray array];
    UTType *ipaType = [UTType typeWithFilenameExtension:@"ipa"];
    if (ipaType) [types addObject:ipaType];
    [types addObject:UTTypeZIP];
    [types addObject:UTTypeData];

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *pickedURL = urls.firstObject;
    if (!pickedURL) return;

    if (_isAndroidMode) {
        [self handlePickedAPKURL:pickedURL];
        return;
    }

    if (![[pickedURL.pathExtension lowercaseString] isEqualToString:@"ipa"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"ipa_install_failed_title")
                                                                       message:L(@"ipa_invalid_extension")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    IOSUsbMuxBridge *bridge = self.usbBridge;
    if (!bridge || !bridge.deviceAttached) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"ipa_install_failed_title")
                                                                       message:L(@"ipa_install_not_ready")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.ipaInstallInFlight = YES;
    self.ipaInstallCancelRequested = NO;
    self.ipaCancelButton.enabled = YES;
    self.ipaCancelButton.hidden = NO;
    self.ipaProgressBar.progress = 0.0f;
    self.ipaProgressLabel.text = L(@"ipa_preparing");
    self.ipaProgressCard.hidden = NO;
    if (self.hardwareBar) {
        [self.view bringSubviewToFront:self.hardwareBar];
    }

    __weak typeof(self) weakSelf = self;
    [IOSIpaInstaller installIPAFromURL:pickedURL
                                bridge:bridge
                          stateDirPath:self.stateDirPath
                              progress:^BOOL(IOSIpaInstallStage stage, NSString *statusText, float progress) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return NO;
        s.ipaProgressLabel.text = statusText;
        if (progress >= 0.0f) {
            s.ipaProgressBar.progress = MIN(1.0f, MAX(0.0f, progress));
        }
        BOOL canCancel = (stage < IOSIpaInstallStageSubmitted);
        s.ipaCancelButton.hidden = !canCancel;
        return !canCancel || !s.ipaInstallCancelRequested;
    }
                            completion:^(IOSIpaInfo * _Nullable info, NSError * _Nullable error) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s.ipaInstallInFlight = NO;
        s.ipaProgressCard.hidden = YES;
        [[NSFileManager defaultManager] removeItemAtURL:pickedURL error:nil];

        if (error) {
            if (error.code == 102) {
                return; // user cancelled
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"ipa_install_failed_title")
                                                                           message:error.localizedDescription
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
            [s presentViewController:alert animated:YES completion:nil];
            return;
        }

        NSString *ver = info.shortVersion.length ? info.shortVersion : (info.version ?: @"?");
        NSString *msg = [NSString stringWithFormat:L(@"ipa_install_success_msg_fmt"), info.name, ver, info.bundleId];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"ipa_install_success_title")
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [s presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)showShutdownOverlay {
    if (_shutdownOverlay) return;
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.96];
    card.layer.cornerRadius = 16.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
    [overlay addSubview:card];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = [UIColor whiteColor];
    [spinner startAnimating];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = L(@"shutting_down_title");
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;

    UILabel *msgLabel = [[UILabel alloc] init];
    msgLabel.translatesAutoresizingMaskIntoConstraints = NO;
    msgLabel.text = L(@"shutting_down_msg");
    msgLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    msgLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    msgLabel.textAlignment = NSTextAlignmentCenter;
    msgLabel.numberOfLines = 0;

    UIButton *forceBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    forceBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [forceBtn setTitle:L(@"force_stop_vm") forState:UIControlStateNormal];
    [forceBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    forceBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    forceBtn.hidden = YES;
    [forceBtn addTarget:self action:@selector(forceStopTapped:) forControlEvents:UIControlEventTouchUpInside];

    [card addSubview:spinner];
    [card addSubview:titleLabel];
    [card addSubview:msgLabel];
    [card addSubview:forceBtn];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToConstant:300.0],
        [card.widthAnchor constraintGreaterThanOrEqualToConstant:240.0],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:24.0],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-24.0],

        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:22.0],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [titleLabel.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],

        [msgLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8.0],
        [msgLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [msgLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],

        [forceBtn.topAnchor constraintEqualToAnchor:msgLabel.bottomAnchor constant:12.0],
        [forceBtn.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [forceBtn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16.0],
    ]];

    [self.view addSubview:overlay];
    _shutdownOverlay = overlay;
    _forceStopButton = forceBtn;
}

- (void)forceStopTapped:(id)sender {
    __atomic_store_n(&_forceStopRequested, YES, __ATOMIC_RELEASE);
    _forceStopButton.enabled = NO;
}

- (void)shutdownAndPerform:(void (^)(void))completion {
    if (__atomic_load_n(&_threadExited, __ATOMIC_ACQUIRE)) {
        [self stopEmulation];
        if (completion) completion();
        return;
    }
    _isStopping = YES;
    [self showShutdownOverlay];
    __weak typeof(self) weakSelf = self;
    _shutdownCompletion = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_isStopping = NO;
        if (completion) completion();
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_isStopping && strongSelf->_forceStopButton) {
            strongSelf->_forceStopButton.hidden = NO;
        }
    });
    [self stopEmulation];
}

- (void)forceRestartTapped:(id)sender {
    if (_isStopping) return;
    [_haptic impactOccurred];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"force_restart_title")
                                                                   message:L(@"force_restart_msg")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"force_restart_title") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        typedef void (*qemu_force_reset_fn)(void);
        qemu_force_reset_fn reset_fn = (qemu_force_reset_fn)dlsym(RTLD_DEFAULT, "qemu_ios_force_reset");
        if (reset_fn) {
            NSLog(@"[EmulatorVC] Triggering in-process QEMU cold reset via qemu_ios_force_reset");
            reset_fn();
        } else {
            NSLog(@"[EmulatorVC] qemu_ios_force_reset symbol not found");
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exitTapped:(id)sender {
    if (_isStopping) return;
    [_haptic impactOccurred];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"exit_confirm_title")
                                                                   message:L(@"exit_confirm_msg")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"stop_vm") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        __weak typeof(self) weakSelf = self;
        [self shutdownAndPerform:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.presentingViewController) {
                [strongSelf.presentingViewController dismissViewControllerAnimated:YES completion:nil];
            } else {
                [strongSelf dismissViewControllerAnimated:YES completion:nil];
            }
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateTelemetry {
    if (self.telemetryCard.hidden) return;

    double hostFps = self.metalView.fps;
    NSUInteger frameCount = self.metalView.totalFramesRendered;

    NSString *text = [NSString stringWithFormat:L(@"hud_format"),
        self.machineName, (unsigned long)self.screenWidth, (unsigned long)self.screenHeight,
        hostFps, (unsigned long)frameCount,
        self.cachedJitAvailable ? L(@"jit_active") : L(@"jit_inactive")
    ];
    self.telemetryLabel.text = text;
}

#pragma mark - Button Actions

- (void)homeButtonDown:(id)sender {
    [_haptic impactOccurred];
    _homePressActive = YES;
    _homeLongPressSent = NO;
    _homePressGen++;
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(102 /* KEY_HOME */, 1);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 0, 1, &err);
    }
}

- (void)homeButtonUp:(id)sender {
    if (!_homePressActive) return;
    _homePressActive = NO;
    _homeLongPressSent = NO;
    _homePressGen++;
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(102 /* KEY_HOME */, 0);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 0, 0, &err);
    }
}

- (void)homeButtonCancel:(id)sender {
    if (!_homePressActive) return;
    _homePressActive = NO;
    _homeLongPressSent = NO;
    _homePressGen++;
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(102 /* KEY_HOME */, 0);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 0, 0, &err);
    }
}

- (void)backButtonDown:(id)sender {
    [_haptic impactOccurred];
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(158 /* KEY_BACK */, 1);
    }
}

- (void)backButtonUp:(id)sender {
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(158 /* KEY_BACK */, 0);
    }
}

- (void)menuButtonDown:(id)sender {
    [_haptic impactOccurred];
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(139 /* KEY_MENU */, 1);
    }
}

- (void)menuButtonUp:(id)sender {
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(139 /* KEY_MENU */, 0);
    }
}

- (void)powerButtonDown:(id)sender {
    [_haptic impactOccurred];
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(116 /* KEY_POWER */, 1);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 1, 1, &err);
    }
}

- (void)powerButtonUp:(id)sender {
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(116 /* KEY_POWER */, 0);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 1, 0, &err);
    }
}

- (void)volUpButtonDown:(id)sender {
    [_haptic impactOccurred];
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(115 /* KEY_VOLUMEUP */, 1);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 2, 1, &err);
    }
}

- (void)volUpButtonUp:(id)sender {
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(115 /* KEY_VOLUMEUP */, 0);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 2, 0, &err);
    }
}

- (void)volDownButtonDown:(id)sender {
    [_haptic impactOccurred];
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(114 /* KEY_VOLUMEDOWN */, 1);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 3, 1, &err);
    }
}

- (void)volDownButtonUp:(id)sender {
    if (_isAndroidMode && _pfnAndroidButton) {
        _pfnAndroidButton(114 /* KEY_VOLUMEDOWN */, 0);
        return;
    }
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 3, 0, &err);
    }
}

#pragma mark - Touch Dispatch

- (void)handleWinRTTouchId:(int)touchId phase:(int)phase x:(float)x y:(float)y {
    float cx = fminf(fmaxf(x, 0.0f), 1.0f);
    float cy = fminf(fmaxf(y, 0.0f), 1.0f);

    int prevActive = 0;
    for (int i = 0; i < 5; i++) {
        if (_winrtActiveTouches[i] != -1) {
            prevActive++;
        }
    }

    int slot = -1;
    for (int i = 0; i < 5; i++) {
        if (_winrtActiveTouches[i] == touchId) {
            slot = i;
            break;
        }
    }
    if (slot < 0 && (phase == 0 || phase == 1)) {
        for (int i = 0; i < 5; i++) {
            if (_winrtActiveTouches[i] == -1) {
                slot = i;
                _winrtActiveTouches[i] = touchId;
                break;
            }
        }
    }
    if (slot >= 0) {
        _winrtTouchX[slot] = cx;
        _winrtTouchY[slot] = cy;
    }

    // Compute midpoint across active touches before removing a lifting finger (needed for 2-finger right-click)
    float preLiftSumX = 0.0f, preLiftSumY = 0.0f;
    int preLiftCount = 0;
    for (int i = 0; i < 5; i++) {
        if (_winrtActiveTouches[i] != -1) {
            preLiftSumX += _winrtTouchX[i];
            preLiftSumY += _winrtTouchY[i];
            preLiftCount++;
        }
    }

    BOOL isUp = (phase == 2 || phase == 3);
    if (isUp && slot >= 0) {
        _winrtActiveTouches[slot] = -1;
    }

    int activeCount = 0;
    float sumX = 0.0f, sumY = 0.0f;
    for (int i = 0; i < 5; i++) {
        if (_winrtActiveTouches[i] != -1) {
            sumX += _winrtTouchX[i];
            sumY += _winrtTouchY[i];
            activeCount++;
        }
    }

    if (activeCount >= 2) {
        _winrtTrackGen++;
        float avgX = sumX / (float)activeCount;
        float avgY = sumY / (float)activeCount;
        int ptrX = (int)lroundf((_winrtMouseMode ? _winrtCursorX : avgX) * 32767.0f);
        int ptrY = (int)lroundf((_winrtMouseMode ? _winrtCursorY : avgY) * 32767.0f);

        if (prevActive < 2) {
            if (!_winrtMouseMode) {
                _winrtCursorX = avgX;
                _winrtCursorY = avgY;
            }
            _pfnWinrtPointerAbs(ptrX, ptrY, 0);
            _winrtTwoFingerStartTime = CACurrentMediaTime();
            _winrtTwoFingerLastY = avgY;
            _winrtTwoFingerScrolled = NO;
        } else if (phase == 1 && _pfnWinrtScroll) {
            float dy = avgY - _winrtTwoFingerLastY;
            if (fabsf(dy) >= 0.03f) {
                int steps = (int)(dy / 0.03f);
                if (steps > 5) steps = 5;
                if (steps < -5) steps = -5;
                if (steps != 0) {
                    _pfnWinrtScroll(steps);
                    _winrtTwoFingerLastY += (float)steps * 0.03f;
                    _winrtTwoFingerScrolled = YES;
                }
            }
        }
        return;
    }

    if (prevActive >= 2 && isUp) {
        if (!_winrtTwoFingerScrolled &&
            _winrtTwoFingerStartTime > 0 &&
            (CACurrentMediaTime() - _winrtTwoFingerStartTime) < 0.35 &&
            preLiftCount > 0) {
            int midX = (int)lroundf((_winrtMouseMode ? _winrtCursorX : (preLiftSumX / (float)preLiftCount)) * 32767.0f);
            int midY = (int)lroundf((_winrtMouseMode ? _winrtCursorY : (preLiftSumY / (float)preLiftCount)) * 32767.0f);
            _pfnWinrtPointerAbs(midX, midY, 2);
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (s && s->_pfnWinrtPointerAbs && __atomic_load_n(&s->_isEmulating, __ATOMIC_ACQUIRE)) {
                    s->_pfnWinrtPointerAbs(midX, midY, 0);
                }
                if (s) [s releaseWinRTStickyModifiers];
            });
            _winrtTwoFingerScrolled = YES;
        }
        if (activeCount == 0) {
            _winrtTwoFingerStartTime = 0;
            _winrtTwoFingerScrolled = NO;
        }
        return;
    }

    if (_winrtMouseMode) {
        if (isUp) {
            if (activeCount == 0) {
                uint64_t clickGen = ++_winrtTrackGen;
                int curAx = (int)lroundf(_winrtCursorX * 32767.0f);
                int curAy = (int)lroundf(_winrtCursorY * 32767.0f);
                if (_winrtMouseDragLock) {
                    // Keep left button held while drag lock is active so the user can reposition finger mid-drag
                    _pfnWinrtPointerAbs(curAx, curAy, 1);
                } else if (_winrtTrackLeftDrag) {
                    _pfnWinrtPointerAbs(curAx, curAy, 0);
                    _winrtTrackLeftDrag = NO;
                    [self releaseWinRTStickyModifiers];
                } else if (!_winrtTrackMoved && !_winrtTrackRightSent &&
                           _winrtTrackStartTime > 0 &&
                           (CACurrentMediaTime() - _winrtTrackStartTime) < 0.45 &&
                           _winrtTwoFingerStartTime == 0) {
                    _pfnWinrtPointerAbs(curAx, curAy, 1);
                    __weak typeof(self) weakSelf = self;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) s = weakSelf;
                        if (s && s->_pfnWinrtPointerAbs && __atomic_load_n(&s->_isEmulating, __ATOMIC_ACQUIRE) &&
                            s->_winrtTrackGen == clickGen && !s->_winrtTrackLeftDrag && !s->_winrtMouseDragLock) {
                            s->_pfnWinrtPointerAbs(curAx, curAy, 0);
                        }
                        if (s && s->_winrtTrackGen == clickGen) [s releaseWinRTStickyModifiers];
                    });
                    _winrtLastTapUpTime = CACurrentMediaTime();
                }
                _winrtTrackRightSent = NO;
                _winrtTrackMoved = NO;
                _winrtTwoFingerStartTime = 0;
                _winrtTwoFingerScrolled = NO;
            }
            return;
        }

        if (activeCount == 1 && _winrtTwoFingerStartTime == 0) {
            if (phase == 0 && prevActive == 0) {
                _winrtTrackStartX = cx;
                _winrtTrackStartY = cy;
                _winrtTrackLastX = cx;
                _winrtTrackLastY = cy;
                _winrtTrackStartTime = CACurrentMediaTime();
                _winrtTrackMoved = NO;
                _winrtTrackRightSent = NO;
                uint64_t gen = ++_winrtTrackGen;
                int curAx = (int)lroundf(_winrtCursorX * 32767.0f);
                int curAy = (int)lroundf(_winrtCursorY * 32767.0f);

                if (_winrtMouseDragLock) {
                    _winrtTrackLeftDrag = YES;
                    _pfnWinrtPointerAbs(curAx, curAy, 1);
                } else if ((_winrtTrackStartTime - _winrtLastTapUpTime) < 0.38) {
                    _winrtTrackLeftDrag = YES;
                    [_haptic impactOccurred];
                    _pfnWinrtPointerAbs(curAx, curAy, 1);
                } else {
                    _winrtTrackLeftDrag = NO;
                    __weak typeof(self) weakSelf = self;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(480 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) s = weakSelf;
                        if (!s || !s->_winrtMouseMode || s->_winrtTrackGen != gen ||
                            s->_winrtTrackMoved || s->_winrtTrackLeftDrag || s->_winrtMouseDragLock ||
                            !s->_pfnWinrtPointerAbs || !__atomic_load_n(&s->_isEmulating, __ATOMIC_ACQUIRE)) {
                            return;
                        }
                        s->_winrtTrackRightSent = YES;
                        [s->_haptic impactOccurred];
                        int rx = (int)lroundf(s->_winrtCursorX * 32767.0f);
                        int ry = (int)lroundf(s->_winrtCursorY * 32767.0f);
                        s->_pfnWinrtPointerAbs(rx, ry, 2);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                            __strong typeof(weakSelf) s2 = weakSelf;
                            if (s2 && s2->_pfnWinrtPointerAbs && __atomic_load_n(&s2->_isEmulating, __ATOMIC_ACQUIRE)) {
                                s2->_pfnWinrtPointerAbs(rx, ry, 0);
                            }
                            if (s2) [s2 releaseWinRTStickyModifiers];
                        });
                    });
                }
            } else if (phase == 1) {
                float dx = cx - _winrtTrackLastX;
                float dy = cy - _winrtTrackLastY;
                _winrtTrackLastX = cx;
                _winrtTrackLastY = cy;
                if (!_winrtTrackMoved && hypotf(cx - _winrtTrackStartX, cy - _winrtTrackStartY) > 0.012f) {
                    _winrtTrackMoved = YES;
                }
                _winrtCursorX = fminf(fmaxf(_winrtCursorX + dx * 1.35f, 0.0f), 1.0f);
                _winrtCursorY = fminf(fmaxf(_winrtCursorY + dy * 1.35f, 0.0f), 1.0f);
                int curAx = (int)lroundf(_winrtCursorX * 32767.0f);
                int curAy = (int)lroundf(_winrtCursorY * 32767.0f);
                _pfnWinrtPointerAbs(curAx, curAy, (_winrtTrackLeftDrag || _winrtMouseDragLock) ? 1 : 0);
            }
        }
        return;
    }

    _winrtCursorX = cx;
    _winrtCursorY = cy;
    int ax = (int)lroundf(cx * 32767.0f);
    int ay = (int)lroundf(cy * 32767.0f);
    if (isUp) {
        if (activeCount == 0) {
            _pfnWinrtPointerAbs(ax, ay, 0);
            if (_winrtTwoFingerStartTime == 0) {
                [self releaseWinRTStickyModifiers];
            }
            _winrtTwoFingerStartTime = 0;
            _winrtTwoFingerScrolled = NO;
        }
    } else if (activeCount == 1) {
        int btn = (_winrtTwoFingerStartTime > 0) ? 0 : 1;
        _pfnWinrtPointerAbs(ax, ay, btn);
    }
}

- (void)handleUbuntuTouchVirtTouchId:(int)touchId phase:(int)phase x:(float)x y:(float)y {
    int slot = -1;
    for (int i = 0; i < 10; i++) {
        if (_utTouchSlots[i] == touchId) {
            slot = i;
            break;
        }
    }
    if (slot < 0 && (phase == 0 || phase == 1)) {
        for (int i = 0; i < 10; i++) {
            if (_utTouchSlots[i] == -1) {
                _utTouchSlots[i] = touchId;
                slot = i;
                break;
            }
        }
    }
    if (slot < 0) return;

    float cx = fminf(fmaxf(x, 0.0f), 1.0f);
    float cy = fminf(fmaxf(y, 0.0f), 1.0f);
    int ax = (int)lroundf(cx * 32767.0f);
    int ay = (int)lroundf(cy * 32767.0f);
    _pfnWinrtTouch(slot, ax, ay, phase);
    if (phase == 2 || phase == 3) {
        _utTouchSlots[slot] = -1;
    }
}

- (void)handleTouchId:(int)touchId phase:(int)phase x:(float)x y:(float)y {
    if (_isUbuntuTouchVirtMode && _pfnWinrtTouch) {
        [self handleUbuntuTouchVirtTouchId:touchId phase:phase x:x y:y];
        return;
    }
    if (_isWinRTMode && _pfnWinrtPointerAbs) {
        [self handleWinRTTouchId:touchId phase:phase x:x y:y];
        return;
    }
    if (_isAndroidMode && _pfnAndroidTouch) {
        int slot = -1;
        for (int i = 0; i < 5; i++) {
            if (_androidTouchSlots[i] == touchId) {
                slot = i;
                break;
            }
        }
        if (slot < 0) {
            for (int i = 0; i < 5; i++) {
                if (_androidTouchSlots[i] == -1) {
                    _androidTouchSlots[i] = touchId;
                    slot = i;
                    break;
                }
            }
        }
        if (slot < 0) slot = abs(touchId) % 5;

        int w = (int)(_screenWidth > 0 ? _screenWidth : 640);
        int h = (int)(_screenHeight > 0 ? _screenHeight : 1136);
        int px = (int)lroundf(fminf(fmaxf(x, 0.0f), 1.0f) * (float)(w - 1));
        int py = (int)lroundf(fminf(fmaxf(y, 0.0f), 1.0f) * (float)(h - 1));
        int down = (phase == 0 || phase == 1) ? 1 : 0;
        _pfnAndroidTouch(slot, px, py, down);
        if (!down) {
            _androidTouchSlots[slot] = -1;
        }
        return;
    }
    if (!_runtime) return;

    lt_touch_batch batch = LT_INIT(lt_touch_batch);
    batch.count = 1;
    batch.contacts[0].size = sizeof(lt_contact);
    batch.contacts[0].version = LT_ABI_VERSION;
    batch.contacts[0].id = (uint32_t)touchId;
    batch.contacts[0].phase = (uint32_t)phase;
    batch.contacts[0].x = (double)x;
    batch.contacts[0].y = (double)y;
    struct timespec rt = {0, 0};
    clock_gettime(CLOCK_REALTIME, &rt);
    batch.timestamp_ns = (uint64_t)rt.tv_sec * 1000000000ULL + (uint64_t)rt.tv_nsec;

    lt_error err = LT_INIT(lt_error);
    lt_runtime_touch(_runtime, &batch, &err);
}

#pragma mark - IOSMotionManagerDelegate

- (void)didUpdateAccelerationX:(double)x y:(double)y z:(double)z {
    _accelX = x;
    _accelY = y;
    _accelZ = z;
    [self forwardMotionSample];
}

- (void)didUpdateGyroscopeX:(double)x y:(double)y z:(double)z {
    _gyroX = x;
    _gyroY = y;
    _gyroZ = z;
    [self forwardMotionSample];
}

- (void)forwardMotionSample {
    if (!__atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) return;
    if (!_runtime && !_isAndroidMode) return;
    if (!_isAndroidMode && !__atomic_load_n(&_boardSupportsAccel, __ATOMIC_ACQUIRE)) return;

    struct timespec ts = {0, 0};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t nowNs = (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
    if (_lastMotionNs != 0 && (nowNs <= _lastMotionNs || nowNs - _lastMotionNs < 40000000ULL)) {
        return;
    }

    // CoreMotion CMAcceleration reports gravity vector ((0, -1, 0) upright), whereas QEMU lis302dl
    // negates host_acceleration expecting upward proper acceleration ((0, +9.80665, 0) upright).
    double rawAx = -_accelX * 9.80665;
    double rawAy = -_accelY * 9.80665;
    double az = -_accelZ * 9.80665;
    double rawGx = fabs(_gyroX) < 0.025 ? 0.0 : _gyroX;
    double rawGy = fabs(_gyroY) < 0.025 ? 0.0 : _gyroY;
    double gz = fabs(_gyroZ) < 0.025 ? 0.0 : _gyroZ;

    BOOL isPad = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
    UIInterfaceOrientation hostOri = (UIInterfaceOrientation)__atomic_load_n(&_hostInterfaceOrientation, __ATOMIC_ACQUIRE);
    double ax = rawAx, ay = rawAy;
    double gx = rawGx, gy = rawGy;

    if (isPad && !self.iPadLandscapeRotationEnabled) {
        // iPad で横画面回転が無効 (縦固定・標準) の場合:
        // iPad を横向きに置いても仮想マシン側が意図せず横回転しないよう、センサー軸を Portrait に打ち消す
        if (hostOri == UIInterfaceOrientationPortraitUpsideDown) {
            ax = -rawAx; ay = -rawAy;
            gx = -rawGx; gy = -rawGy;
        } else if (hostOri == UIInterfaceOrientationLandscapeLeft) {
            ax = rawAy;  ay = -rawAx;
            gx = rawGy;  gy = -rawGx;
        } else if (hostOri == UIInterfaceOrientationLandscapeRight) {
            ax = -rawAy; ay = rawAx;
            gx = -rawGy; gy = rawGx;
        }
        _effectiveMotionOri = UIInterfaceOrientationPortrait;
    } else {
        // iPhone、または iPad で横画面回転が有効の場合:
        // ホスト端末の向きを確実に仮想マシンへ反映する（傾斜・平置き・メニュー切替時も含め軸支配を維持）
        NSInteger targetOri = (NSInteger)hostOri;
        if (targetOri < UIInterfaceOrientationPortrait || targetOri > UIInterfaceOrientationLandscapeRight) {
            targetOri = UIInterfaceOrientationPortrait;
        }
        if (isPad && _effectiveMotionOri != 0 && _effectiveMotionOri != targetOri) {
            // CoreMotion sensor fusion on gyro-equipped guests needs an angular velocity sweep when switching stationary orientations
            _gyroPulseUntilNs = nowNs + 350000000ULL;
            _gyroPulseDirZ = (targetOri == UIInterfaceOrientationLandscapeLeft) ? 1.0 : -1.0;
        }
        _effectiveMotionOri = targetOri;

        if (hostOri == UIInterfaceOrientationLandscapeLeft) {
            if (fabs(ax) < 7.5 || fabs(ay) > fabs(ax) * 0.6) {
                ax = -9.80665;
                ay = 0.0;
                if (fabs(az) > 7.5) az = -1.5;
            }
        } else if (hostOri == UIInterfaceOrientationLandscapeRight) {
            if (fabs(ax) < 7.5 || fabs(ay) > fabs(ax) * 0.6) {
                ax = 9.80665;
                ay = 0.0;
                if (fabs(az) > 7.5) az = -1.5;
            }
        } else if (hostOri == UIInterfaceOrientationPortraitUpsideDown) {
            if (fabs(ay) < 7.5 || fabs(ax) > fabs(ay) * 0.6) {
                ax = 0.0;
                ay = -9.80665;
                if (fabs(az) > 7.5) az = -1.5;
            }
        } else {
            if (fabs(ay) < 7.5 || fabs(ax) > fabs(ay) * 0.6) {
                ax = 0.0;
                ay = 9.80665;
                if (fabs(az) > 7.5) az = -1.5;
            }
        }
        if (_gyroPulseUntilNs > nowNs && fabs(gz) < 1.0) {
            gz = _gyroPulseDirZ * 4.5;
        }
    }

    // Keep sending steady-state samples every 100ms because lis302dl expires host motion after 250ms virtual time,
    // but when inside the deadband, re-send the exact previous gravity vector so SpringBoard's UIMotionEffect
    // parallax and CABackdropLayer blurs settle to 0% idle load on iOS 7-10 instead of restarting every 100ms.
    if (_hasSentMotion) {
        double da = fmax(fabs(ax - _lastSentAccelX), fmax(fabs(ay - _lastSentAccelY), fabs(az - _lastSentAccelZ)));
        double dg = fmax(fabs(gx - _lastSentGyroX), fmax(fabs(gy - _lastSentGyroY), fabs(gz - _lastSentGyroZ)));
        if (da < 0.08 && dg < 0.025 && gx == 0.0 && gy == 0.0 && gz == 0.0) {
            if ((nowNs - _lastMotionNs) < 100000000ULL) {
                return;
            }
            ax = _lastSentAccelX;
            ay = _lastSentAccelY;
            az = _lastSentAccelZ;
        } else {
            _lastSentAccelX = ax;
            _lastSentAccelY = ay;
            _lastSentAccelZ = az;
            _lastSentGyroX = gx;
            _lastSentGyroY = gy;
            _lastSentGyroZ = gz;
        }
    } else {
        _lastSentAccelX = ax;
        _lastSentAccelY = ay;
        _lastSentAccelZ = az;
        _lastSentGyroX = gx;
        _lastSentGyroY = gy;
        _lastSentGyroZ = gz;
        _hasSentMotion = YES;
    }

    _lastMotionNs = nowNs;

    if (_isAndroidMode && _pfnAndroidAccel) {
        _pfnAndroidAccel((float)ax, (float)ay, (float)az);
        return;
    }

    lt_motion mot = LT_INIT(lt_motion);
    mot.timestamp_ns = nowNs;
    mot.kinds = __atomic_load_n(&_boardSupportsGyro, __ATOMIC_ACQUIRE) ? 3u : 1u; // accel (+ gyro if board supports it)
    mot.acceleration[0] = ax;
    mot.acceleration[1] = ay;
    mot.acceleration[2] = az;
    mot.angular_velocity[0] = gx;
    mot.angular_velocity[1] = gy;
    mot.angular_velocity[2] = gz;

    lt_error err = LT_INIT(lt_error);
    lt_runtime_motion(_runtime, &mot, &err);
}

#pragma mark - Frame Rendering Callback

static void s_frame_pixel_listener(void *opaque, const lt_frame_info *info, const void *pixels) {
    EmulatorViewController *vc = (__bridge EmulatorViewController *)opaque;
    if (!vc || !__atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE) || !info || !pixels) return;
    [vc renderPublishedFrame:info pixels:pixels];
}

static void s_direct_iosurface_listener(void *opaque, void *iosurface_ref, int w, int h) {
    EmulatorViewController *vc = (__bridge EmulatorViewController *)opaque;
    if (!vc || !__atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE) || !iosurface_ref || w <= 0 || h <= 0) return;
    NSInteger fw = (NSInteger)w;
    NSInteger fh = (NSInteger)h;
    BOOL dimsChanged = (vc->_screenWidth != fw || vc->_screenHeight != fh);
    vc->_screenWidth = fw;
    vc->_screenHeight = fh;
    [vc->_iosMetalView updateFrameIOSurface:iosurface_ref width:w height:h];
    if (dimsChanged) {
        __weak typeof(vc) weakSelf = vc;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.screenWidth = fw;
            s.screenHeight = fh;
            [s updateMetalDisplayRotation];
            if (!s.userMovedBarManually && s.menuPositionMode != ClassicMenuPositionCustom) {
                [s applyPreferredBarPositionAnimated:YES];
            }
        });
    }
}

- (void)renderPublishedFrame:(const lt_frame_info *)info pixels:(const void *)pixels {
    _lastFrameSeq = info->sequence;
    NSInteger fw = (NSInteger)info->width;
    NSInteger fh = (NSInteger)info->height;
    BOOL dimsChanged = (_screenWidth != fw || _screenHeight != fh);
    _screenWidth = fw;
    _screenHeight = fh;

    [self.metalView updateFramePixels:pixels
                                width:(int)info->width
                               height:(int)info->height
                               stride:(int)info->stride];

    if (dimsChanged) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.screenWidth = fw;
            s.screenHeight = fh;
            [s updateMetalDisplayRotation];
            if (!s.userMovedBarManually && s.menuPositionMode != ClassicMenuPositionCustom) {
                [s applyPreferredBarPositionAnimated:YES];
            }
        });
    }
}

#pragma mark - Emulation Thread Lifecycle

static void emulator_finish_thread_ui(EmulatorViewController *vc, NSString * _Nullable unexpectedErrorMsg) {
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *flagPath = [docDir stringByAppendingPathComponent:@"boot_in_progress.flag"];
    [[NSFileManager defaultManager] removeItemAtPath:flagPath error:nil];

    __atomic_store_n(&vc->_threadExited, YES, __ATOMIC_RELEASE);
    __atomic_store_n(&vc->_isEmulating, NO, __ATOMIC_RELEASE);
    dispatch_async(dispatch_get_main_queue(), ^{
        vc.metalView.paused = YES;
        [vc.audioBridge stop];
        [vc.motionManager stopMonitoring];
        [vc.telemetryTimer invalidate];
        vc.telemetryTimer = nil;
        [vc stopClipboardSyncTimer];
        [vc->_shutdownOverlay removeFromSuperview];
        vc->_shutdownOverlay = nil;
        vc->_forceStopButton = nil;
        vc->_isStopping = NO;
        if (vc->_shutdownCompletion) {
            void (^done)(void) = vc->_shutdownCompletion;
            vc->_shutdownCompletion = nil;
            done();
        } else if (unexpectedErrorMsg.length > 0 && !vc.isBeingDismissed) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"emulation_error")
                                                                           message:unexpectedErrorMsg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                if (vc.presentingViewController) {
                    [vc.presentingViewController dismissViewControllerAnimated:YES completion:nil];
                } else {
                    [vc dismissViewControllerAnimated:YES completion:nil];
                }
            }]];
            [vc presentViewController:alert animated:YES completion:nil];
        }
    });
}

typedef struct {
    NSInteger stage; // 0=wait agent, 1=upload ittrust, 2=upload itproxy, 3=upload cert, 4=run ittrust add, 5=run itproxy on, 6=done
    uint64_t pendingRequestId;
    NSUInteger uploadOffset;
    NSUInteger pendingChunkLen;
    NSInteger retryCount;
    NSInteger pollErrorCount;
    CFAbsoluteTime retryAfterTime;
    NSData *ittrustData;
    NSData *itproxyData;
    NSData *certDER;
    NSString *fingerprint;
    NSString *markerPath;
} ClassicGuestTrustContext;

static void ClassicGuestNetworkTrustStep(lt_runtime *runtime, ClassicGuestTrustContext *ctx) {
    if (!runtime || ctx->stage >= 6) return;
    if (!ctx->certDER.length || !ctx->ittrustData.length || !ctx->itproxyData.length) {
        ctx->stage = 6;
        return;
    }

    lt_error gerr = LT_INIT(lt_error);
    if (ctx->pendingRequestId != 0) {
        lt_guest_result res = LT_INIT(lt_guest_result);
        lt_status pst = lt_runtime_guest_poll(runtime, ctx->pendingRequestId, &res, &gerr);
        if (pst != LT_OK) {
            ctx->pollErrorCount++;
            if (ctx->pollErrorCount < 5) {
                NSLog(@"[EmulatorVC] Proxy trust poll transient error (%d: %s, attempt %ld/5)", pst, gerr.message, (long)ctx->pollErrorCount);
                ctx->retryAfterTime = CFAbsoluteTimeGetCurrent() + 1.0;
                return;
            }
            NSLog(@"[EmulatorVC] Proxy trust poll failed (%d: %s)", pst, gerr.message);
            ctx->pendingRequestId = 0;
            ctx->stage = 6;
            return;
        }
        ctx->pollErrorCount = 0;
        if (res.state == 1) {
            return; // still pending
        }
        ctx->pendingRequestId = 0;
        if (res.state != 2 || res.guest_status != 0) {
            // If the guest rebooted mid-transfer, /tmp helpers are wiped: restart from stage 1!
            if (((ctx->stage == 2 || ctx->stage == 3) && res.state == 5) ||
                ((ctx->stage == 4 || ctx->stage == 5) && res.guest_status == -2)) {
                if (ctx->retryCount < 10) {
                    ctx->retryCount++;
                    NSLog(@"[EmulatorVC] Guest restarted or /tmp cleared during proxy setup stage=%ld (state=%u guest_status=%d); resetting to stage 1 in 2.0s (attempt %ld/10)...",
                          (long)ctx->stage, res.state, res.guest_status, (long)ctx->retryCount);
                    ctx->stage = 1;
                    ctx->uploadOffset = 0;
                    ctx->pendingChunkLen = 0;
                    ctx->retryAfterTime = CFAbsoluteTimeGetCurrent() + 2.0;
                    return;
                }
            }
            // Stage-specific retry handling
            if (ctx->stage == 1 || ctx->stage == 2) {
                // it_agent discards .it-agent-part on any error; resend MUST start from offset 0!
                if (ctx->retryCount < 8) {
                    ctx->retryCount++;
                    NSLog(@"[EmulatorVC] Proxy helper upload stage=%ld failed (state=%u guest_status=%d offset=%lu). Resetting to offset 0 and retrying in 2.0s (attempt %ld/8)...",
                          (long)ctx->stage, res.state, res.guest_status, (unsigned long)ctx->uploadOffset, (long)ctx->retryCount);
                    ctx->uploadOffset = 0;
                    ctx->pendingChunkLen = 0;
                    ctx->retryAfterTime = CFAbsoluteTimeGetCurrent() + 2.0;
                    return;
                }
            } else if (ctx->stage == 3) {
                if (ctx->retryCount < 5) {
                    ctx->retryCount++;
                    NSLog(@"[EmulatorVC] Proxy cert upload failed (state=%u guest_status=%d). Retrying in 2.0s (attempt %ld/5)...",
                          res.state, res.guest_status, (long)ctx->retryCount);
                    ctx->pendingChunkLen = 0;
                    ctx->retryAfterTime = CFAbsoluteTimeGetCurrent() + 2.0;
                    return;
                }
            } else if (ctx->stage == 4) {
                if (strstr(res.output, "-25308") != NULL && ctx->retryCount < 30) {
                    // errSecInteractionNotAllowed (-25308): guest Keychain is locked while on Lock Screen; retry after unlock.
                    ctx->retryCount++;
                    ctx->retryAfterTime = CFAbsoluteTimeGetCurrent() + 3.0;
                    if (ctx->retryCount == 1) {
                        NSLog(@"[EmulatorVC] Proxy trust deferred until guest screen is unlocked (-25308)");
                    }
                    return;
                }
                if (ctx->retryCount < 10) {
                    ctx->retryCount++;
                    NSLog(@"[EmulatorVC] Proxy trust add (ittrust) failed (state=%u guest_status=%d out=%s). Retrying in 2.0s (attempt %ld/10)...",
                          res.state, res.guest_status, res.output, (long)ctx->retryCount);
                    ctx->retryAfterTime = CFAbsoluteTimeGetCurrent() + 2.0;
                    return;
                }
            } else if (ctx->stage == 5) {
                if (ctx->retryCount < 20) {
                    ctx->retryCount++;
                    NSLog(@"[EmulatorVC] Proxy route (itproxy) failed (state=%u guest_status=%d out=%s). Retrying in 2.5s (attempt %ld/20)...",
                          res.state, res.guest_status, res.output, (long)ctx->retryCount);
                    ctx->retryAfterTime = CFAbsoluteTimeGetCurrent() + 2.5;
                    return;
                }
            }

            NSLog(@"[EmulatorVC] Proxy trust step stage=%ld failed permanently (state=%u guest_status=%d out=%s)",
                  (long)ctx->stage, res.state, res.guest_status, res.output);
            if (ctx->stage == 4 && ctx->markerPath.length && ctx->fingerprint.length) {
                NSString *savedFp = [NSString stringWithContentsOfFile:ctx->markerPath encoding:NSUTF8StringEncoding error:nil];
                if ([savedFp isEqualToString:ctx->fingerprint]) {
                    ctx->retryCount = 0;
                    ctx->retryAfterTime = 0;
                    ctx->stage = 5;
                    return;
                }
            }
            ctx->stage = 6;
            return;
        }

        // Successfully completed chunk / operation
        if (ctx->stage == 1) {
            ctx->uploadOffset += ctx->pendingChunkLen;
            ctx->pendingChunkLen = 0;
            ctx->retryCount = 0;
            if (ctx->uploadOffset >= ctx->ittrustData.length) {
                NSLog(@"[EmulatorVC] ittrust helper uploaded successfully (%lu bytes)", (unsigned long)ctx->ittrustData.length);
                ctx->stage = 2;
                ctx->uploadOffset = 0;
            }
        } else if (ctx->stage == 2) {
            ctx->uploadOffset += ctx->pendingChunkLen;
            ctx->pendingChunkLen = 0;
            ctx->retryCount = 0;
            if (ctx->uploadOffset >= ctx->itproxyData.length) {
                NSLog(@"[EmulatorVC] itproxy helper uploaded successfully (%lu bytes)", (unsigned long)ctx->itproxyData.length);
                ctx->stage = 3;
            }
        } else if (ctx->stage == 3) {
            NSLog(@"[EmulatorVC] Certificate uploaded to guest successfully");
            ctx->retryCount = 0;
            ctx->stage = 4;
        } else if (ctx->stage == 4) {
            if (ctx->markerPath.length && ctx->fingerprint.length) {
                [ctx->fingerprint writeToFile:ctx->markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            NSLog(@"[EmulatorVC] Guest proxy CA trusted (%@), enabling proxy routing...", ctx->fingerprint);
            ctx->retryCount = 0;
            ctx->retryAfterTime = 0;
            ctx->stage = 5;
        } else if (ctx->stage == 5) {
            NSLog(@"[EmulatorVC] Guest proxy routing enabled (10.0.2.100:3128)");
            ctx->stage = 6;
            return;
        }
    }

    if ((ctx->stage == 1 || ctx->stage == 2 || ctx->stage == 3 || ctx->stage == 4 || ctx->stage == 5) &&
        ctx->retryAfterTime > 0 && CFAbsoluteTimeGetCurrent() < ctx->retryAfterTime) {
        return;
    }

    uint32_t agentStatus = 0;
    if (lt_runtime_guest_status(runtime, &agentStatus, &gerr) != LT_OK || agentStatus != 1) {
        return; // wait until guest it_agent is ready
    }

    if (ctx->stage == 0) {
        ctx->stage = 1;
        ctx->uploadOffset = 0;
    }

    lt_guest_request req = LT_INIT(lt_guest_request);
    NSString *argStr = nil;
    NSUInteger chunkLen = 0;
    if (ctx->stage == 1) {
        const NSUInteger kChunkSize = 1500;
        NSUInteger remaining = ctx->ittrustData.length - ctx->uploadOffset;
        chunkLen = MIN(kChunkSize, remaining);
        BOOL isLast = (ctx->uploadOffset + chunkLen >= ctx->ittrustData.length);
        NSData *slice = [ctx->ittrustData subdataWithRange:NSMakeRange(ctx->uploadOffset, chunkLen)];
        NSString *b64 = [slice base64EncodedStringWithOptions:0];
        argStr = [NSString stringWithFormat:@"%lu %d %@", (unsigned long)ctx->uploadOffset, isLast ? 1 : 0, b64];
        req.operation = LT_GUEST_NETWORK_TRUST_CHUNK;
        req.timeout_ms = 20000;
        req.argument = [argStr UTF8String];
    } else if (ctx->stage == 2) {
        const NSUInteger kChunkSize = 1500;
        NSUInteger remaining = ctx->itproxyData.length - ctx->uploadOffset;
        chunkLen = MIN(kChunkSize, remaining);
        BOOL isLast = (ctx->uploadOffset + chunkLen >= ctx->itproxyData.length);
        NSData *slice = [ctx->itproxyData subdataWithRange:NSMakeRange(ctx->uploadOffset, chunkLen)];
        NSString *b64 = [slice base64EncodedStringWithOptions:0];
        argStr = [NSString stringWithFormat:@"%lu %d %@", (unsigned long)ctx->uploadOffset, isLast ? 1 : 0, b64];
        req.operation = LT_GUEST_NETWORK_ROUTE_CHUNK;
        req.timeout_ms = 20000;
        req.argument = [argStr UTF8String];
    } else if (ctx->stage == 3) {
        argStr = [ctx->certDER base64EncodedStringWithOptions:0];
        req.operation = LT_GUEST_NETWORK_CERTIFICATE;
        req.timeout_ms = 20000;
        req.argument = [argStr UTF8String];
    } else if (ctx->stage == 4) {
        req.operation = LT_GUEST_NETWORK_TRUST;
        req.timeout_ms = 20000;
        req.argument = NULL;
    } else if (ctx->stage == 5) {
        req.operation = LT_GUEST_NETWORK_ROUTE;
        req.timeout_ms = 20000;
        req.argument = NULL;
    } else {
        ctx->stage = 6;
        return;
    }

    uint64_t reqId = 0;
    lt_status rst = lt_runtime_guest_request(runtime, &req, &reqId, &gerr);
    if (rst == LT_AGAIN || rst == LT_BUSY) {
        return;
    }
    if (rst != LT_OK) {
        ctx->retryCount++;
        if (ctx->retryCount < 5) {
            NSLog(@"[EmulatorVC] Proxy trust request stage=%ld rejected (%d: %s). Retrying in 1.5s...", (long)ctx->stage, rst, gerr.message);
            ctx->retryAfterTime = CFAbsoluteTimeGetCurrent() + 1.5;
            return;
        }
        NSLog(@"[EmulatorVC] Proxy trust request stage=%ld failed permanently (%d: %s)", (long)ctx->stage, rst, gerr.message);
        ctx->stage = 6;
        return;
    }
    if (ctx->stage == 1 || ctx->stage == 2) {
        ctx->pendingChunkLen = chunkLen;
    } else {
        ctx->pendingChunkLen = 0;
    }
    ctx->pendingRequestId = reqId;
}

static void ClassicApplyCarrierNameIfConfigured(void) {
    NSString *carrier = [[NSUserDefaults standardUserDefaults] stringForKey:@"ClassicTouch_CarrierName"];
    if (!carrier || carrier.length == 0) {
        carrier = @"ClassicTouch";
    }

    // 1. Modem property setter (qemu_ios_ui_modem_set)
    typedef bool (*qemu_modem_set_fn)(const char *prop, const char *val);
    static qemu_modem_set_fn s_modem_set = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_modem_set = (qemu_modem_set_fn)dlsym(RTLD_DEFAULT, "qemu_ios_ui_modem_set");
        if (!s_modem_set) {
            s_modem_set = (qemu_modem_set_fn)dlsym(RTLD_DEFAULT, "_qemu_ios_ui_modem_set");
        }
    });

    if (s_modem_set) {
        bool ok = s_modem_set("carrier", [carrier UTF8String]);
        if (ok) {
            NSLog(@"[EmulatorVC] Applied carrier name '%@' via modem emulation", carrier);
        }
    }

    // 2. it_agent defaults write
    typedef bool (*qemu_agent_req_fn)(const char *req);
    static qemu_agent_req_fn s_agent_req = NULL;
    static dispatch_once_t onceToken2;
    dispatch_once(&onceToken2, ^{
        s_agent_req = (qemu_agent_req_fn)dlsym(RTLD_DEFAULT, "qemu_ios_agent_request");
        if (!s_agent_req) {
            s_agent_req = (qemu_agent_req_fn)dlsym(RTLD_DEFAULT, "_qemu_ios_agent_request");
        }
    });

    if (s_agent_req) {
        NSString *cmd = [NSString stringWithFormat:@"exec defaults write com.apple.springboard SBCarrierName \"%@\"\n", carrier];
        s_agent_req([cmd UTF8String]);
    }
}

static void emulator_android_notify_dims_changed(EmulatorViewController *vc, NSInteger fw, NSInteger fh) {
    __weak typeof(vc) weakSelf = vc;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s.screenWidth = fw;
        s.screenHeight = fh;
        [s updateMetalDisplayRotation];
        if (!s.userMovedBarManually && s.menuPositionMode != ClassicMenuPositionCustom) {
            [s applyPreferredBarPositionAnimated:YES];
        }
    });
}

static void emulator_android_frame_cb(void *opaque, int width, int height,
                                      int stride_bytes, const void *pixels) {
    EmulatorViewController *vc = (__bridge EmulatorViewController *)opaque;
    if (!vc || !pixels || width <= 0 || height <= 0 || stride_bytes <= 0) return;

    NSInteger fw = (NSInteger)width;
    NSInteger fh = (NSInteger)height;
    BOOL dimsChanged = (vc->_screenWidth != fw || vc->_screenHeight != fh);
    vc->_screenWidth = fw;
    vc->_screenHeight = fh;

    [vc.metalView updateFramePixels:pixels width:width height:height stride:stride_bytes];

    if (dimsChanged) {
        emulator_android_notify_dims_changed(vc, fw, fh);
    }
}

static void emulator_android_dirty_frame_cb(void *opaque, int full_w, int full_h,
                                            int x, int y, int width, int height,
                                            int stride_bytes, const void *pixels) {
    EmulatorViewController *vc = (__bridge EmulatorViewController *)opaque;
    if (!vc || !pixels || full_w <= 0 || full_h <= 0 || width <= 0 || height <= 0 || stride_bytes <= 0) return;

    NSInteger fw = (NSInteger)full_w;
    NSInteger fh = (NSInteger)full_h;
    BOOL dimsChanged = (vc->_screenWidth != fw || vc->_screenHeight != fh);
    vc->_screenWidth = fw;
    vc->_screenHeight = fh;

    if (vc->_androidMetalView) {
        [vc->_androidMetalView updateDirtyPixels:pixels
                                               x:x
                                               y:y
                                           width:width
                                          height:height
                                          stride:stride_bytes
                                       fullWidth:full_w
                                      fullHeight:full_h];
    } else {
        [vc.metalView updateFramePixels:pixels width:full_w height:full_h stride:stride_bytes];
    }

    if (dimsChanged) {
        emulator_android_notify_dims_changed(vc, fw, fh);
    }
}

static void emulator_android_serial_cb(void *opaque, const char *text, size_t len) {
    EmulatorViewController *vc = (__bridge EmulatorViewController *)opaque;
    if (!vc || !text || len == 0) return;
    FILE *f = vc->_androidSerialFile;
    if (f) {
        fwrite(text, 1, len, f);
        if (memchr(text, '\n', len) != NULL) {
            fflush(f);
        }
    }
}

typedef struct {
    int (*main_fn)(int, char **);
    int argc;
    char **argv;
    EmulatorViewController *vc;
} AndroidQemuRunArgs;

static void *emulator_android_qemu_thread(void *arg) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    AndroidQemuRunArgs *run = (AndroidQemuRunArgs *)arg;
    EmulatorViewController *vc = run->vc;
    @autoreleasepool {
        if (run->main_fn) {
            run->main_fn(run->argc, run->argv);
        }
    }
    for (int i = 0; i < run->argc; i++) {
        free(run->argv[i]);
    }
    free(run->argv);
    free(run);
    __c11_atomic_store(&vc->_androidQemuExited, YES, __ATOMIC_RELEASE);
    return NULL;
}

static BOOL ClassicCopySparseFile(NSString *srcPath, NSString *dstPath);

static void *emulator_android_worker(EmulatorViewController *vc) {
    NSLog(@"[EmulatorVC] Starting Android worker for %@", vc.machineId);
    __atomic_store_n(&vc->_boardSupportsAccel, YES, __ATOMIC_RELEASE);
    __atomic_store_n(&vc->_boardSupportsGyro, NO, __ATOMIC_RELEASE);
    __c11_atomic_init(&vc->_androidQemuExited, NO);

    bool jitTimedOut = false;
    bool jitReady = ios_jit_is_available_detailed(1200, &jitTimedOut);
    vc.cachedJitAvailable = jitReady;
    if (!jitReady) {
        NSLog(@"[EmulatorVC] JIT unavailable for Android (%d); aborting", (int)jitTimedOut);
        NSString *jitLostMsg = jitTimedOut ? L(@"jit_stikdebug_timeout_msg") : L(@"jit_disconnected_before_start_msg");
        emulator_finish_thread_ui(vc, jitLostMsg);
        return NULL;
    }

    NSString *enginePath = [vc locateAndroidEngineLibrary];
    void *handle = dlopen([enginePath UTF8String], RTLD_LOCAL | RTLD_NOW);
    if (!handle) {
        const char *dlerr = dlerror();
        NSString *msg = [NSString stringWithFormat:@"Failed to load libqemu-android.dylib (%s)", dlerr ? dlerr : "unknown error"];
        NSLog(@"[EmulatorVC] %@", msg);
        emulator_finish_thread_ui(vc, msg);
        return NULL;
    }

    vc->_androidEngineHandle = handle;
    vc.androidAdbClient = [[AEADBClient alloc] initWithEngineHandle:handle];
    vc->_pfnAndroidMain = (int (*)(int, char **))dlsym(handle, "qemu_android_main");
    vc->_pfnAndroidConfigureImages = (void (*)(const char *, const char *, const char *))dlsym(handle, "qemu_android_ui_configure_images");
    vc->_pfnAndroidConfigureDisplay = (void (*)(int, int, int))dlsym(handle, "qemu_android_ui_configure_display");
    vc->_pfnAndroidAddProp = (void (*)(const char *, const char *))dlsym(handle, "qemu_android_ui_add_boot_property");
    vc->_pfnAndroidSetFrameCb = (void (*)(void (*)(void *, int, int, int, const void *), void *))dlsym(handle, "qemu_android_ui_set_frame_callback");
    vc->_pfnAndroidSetDirtyFrameCb = (void (*)(void (*)(void *, int, int, int, int, int, int, int, const void *), void *))dlsym(handle, "qemu_android_ui_set_dirty_frame_callback");
    vc->_pfnAndroidSetLogCb = (void (*)(void (*)(void *, const char *, size_t), void *))dlsym(handle, "qemu_android_ui_set_serial_log_callback");
    vc->_pfnAndroidTouch = (void (*)(int, int, int, int))dlsym(handle, "qemu_android_ui_touch");
    vc->_pfnAndroidButton = (void (*)(int, int))dlsym(handle, "qemu_android_ui_button");
    vc->_pfnAndroidAccel = (void (*)(float, float, float))dlsym(handle, "qemu_android_ui_accel");
    vc->_pfnAndroidAudioPull = (int (*)(int16_t *, int, int *, int *))dlsym(handle, "qemu_android_ui_audio_pull");
    vc->_pfnAndroidSync = (void (*)(void))dlsym(handle, "qemu_android_ui_sync");
    vc->_pfnAndroidQuit = (void (*)(void))dlsym(handle, "qemu_android_ui_quit");

    if (!vc->_pfnAndroidMain || !vc->_pfnAndroidConfigureImages ||
        !vc->_pfnAndroidSetFrameCb || !vc->_pfnAndroidQuit) {
        NSLog(@"[EmulatorVC] Missing symbols in libqemu-android.dylib");
        emulator_finish_thread_ui(vc, @"Invalid libqemu-android.dylib symbol table.");
        return NULL;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:vc.stateDirPath withIntermediateDirectories:YES attributes:nil error:nil];

    NSInteger ramMB = 512;
    NSInteger apiLevel = 0;
    NSInteger lcdW = 750;
    NSInteger lcdH = 1334;
    NSInteger metaDpi = 0;
    NSInteger dpi = (vc.androidLcdDensity >= 160) ? vc.androidLcdDensity : 320;
    BOOL gpuEnabled = (vc.androidGpuMode >= 0);
    NSString *cpuModel = @"cortex-a8";
    NSString *cmdline = @"qemu=1 console=ttyS0 androidboot.console=ttyS0 androidboot.hardware=goldfish android.qemud=1";
    NSString *metaPath = [vc.baseDirPath stringByAppendingPathComponent:@"android-metadata.json"];
    NSData *metaData = [NSData dataWithContentsOfFile:metaPath];
    NSDictionary *meta = nil;
    if (metaData) {
        id parsed = [NSJSONSerialization JSONObjectWithData:metaData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            meta = parsed;
            NSNumber *ramNum = meta[@"ram_mb"];
            if ([ramNum isKindOfClass:[NSNumber class]] && ramNum.integerValue >= 256) {
                ramMB = ramNum.integerValue;
            }
            NSNumber *apiNum = meta[@"api_level"];
            if ([apiNum isKindOfClass:[NSNumber class]] && apiNum.integerValue > 0) {
                apiLevel = apiNum.integerValue;
            }
            NSNumber *wNum = meta[@"width"];
            NSNumber *hNum = meta[@"height"];
            if ([wNum isKindOfClass:[NSNumber class]] && wNum.integerValue > 0 &&
                [hNum isKindOfClass:[NSNumber class]] && hNum.integerValue > 0) {
                NSInteger mw = wNum.integerValue;
                NSInteger mh = hNum.integerValue;
                if ((mw == 640 && mh == 1136) || (mw == 540 && mh == 960)) {
                    lcdW = 750;
                    lcdH = 1334;
                } else {
                    lcdW = mw;
                    lcdH = mh;
                }
            }
            NSNumber *dpiNum = meta[@"dpi"];
            if ([dpiNum isKindOfClass:[NSNumber class]] && dpiNum.integerValue >= 120) {
                metaDpi = dpiNum.integerValue;
            }
            NSString *metaCpu = meta[@"cpu"];
            if ([metaCpu isKindOfClass:[NSString class]] && metaCpu.length > 0) {
                cpuModel = metaCpu;
            }
            NSString *cmd = meta[@"cmdline"];
            if ([cmd isKindOfClass:[NSString class]] && cmd.length > 0) {
                cmdline = cmd;
            }
        }
    }
    if (apiLevel <= 0) {
        NSString *ident = [meta[@"entryId"] isKindOfClass:[NSString class]] ? meta[@"entryId"] : nil;
        if (ident.length == 0) ident = vc.baseDirPath.lastPathComponent;
        if ([ident hasPrefix:@"android-"]) {
            NSArray<NSString *> *parts = [ident componentsSeparatedByString:@"-"];
            if (parts.count >= 2 && parts[1].integerValue > 0) {
                apiLevel = parts[1].integerValue;
            }
        }
    }
    if (vc.androidLcdDensity < 160 && metaDpi >= 120) {
        dpi = metaDpi;
    }
    BOOL isFirefoxOS = ([vc.platform isEqualToString:@"firefoxos"] ||
                        [meta[@"platform"] isEqualToString:@"firefoxos"] ||
                        [vc.baseDirPath.lastPathComponent hasPrefix:@"fxos-"]);
    BOOL isFirefoxOS26 = ([vc.baseDirPath.lastPathComponent hasPrefix:@"fxos-2.6"] ||
                          [meta[@"entryId"] isEqualToString:@"fxos-2.6"]);
    if (vc.androidRamMB >= 256) {
        ramMB = vc.androidRamMB;
    }
    if (apiLevel >= 19 && ramMB < 760 && vc.androidRamMB <= 512) {
        if ([NSProcessInfo processInfo].physicalMemory >= (3ULL * 1024ULL * 1024ULL * 1024ULL)) {
            ramMB = 760;
        }
    }
    if (ramMB > 760 && [NSProcessInfo processInfo].physicalMemory < (3ULL * 1024ULL * 1024ULL * 1024ULL)) {
        ramMB = 760;
    }
    if (isFirefoxOS26 && ramMB > 760) {
        ramMB = 760;
    }
    if (ramMB < 128) ramMB = 128;
    if (ramMB > 4080) ramMB = 4080; // android51 MMIO starts at 0xff000000
    // Prepare kernel cmdline; let android51.c append qemu.gles=1/0 from actual GPU readiness.
    NSMutableArray<NSString *> *cmdTokens = [NSMutableArray array];
    BOOL hasHardwareProp = NO;
    BOOL hasBootConsoleProp = NO;
    BOOL hasSelinuxProp = NO;
    for (NSString *tok in [cmdline componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (tok.length == 0) continue;
        if ([tok hasPrefix:@"qemu.gles="] || [tok hasPrefix:@"qemu.sf.lcd_density="] ||
            [tok hasPrefix:@"qemu.hw.mainkeys="] || [tok hasPrefix:@"android.checkjni="] ||
            [tok hasPrefix:@"android.qemud="] || [tok hasPrefix:@"ndns="]) {
            continue;
        }
        if ([tok hasPrefix:@"androidboot.hardware="]) {
            hasHardwareProp = YES;
        } else if ([tok hasPrefix:@"androidboot.console="]) {
            hasBootConsoleProp = YES;
        } else if ([tok hasPrefix:@"androidboot.selinux="]) {
            hasSelinuxProp = YES;
        }
        [cmdTokens addObject:tok];
    }
    if (!hasHardwareProp) {
        [cmdTokens addObject:@"androidboot.hardware=goldfish"];
    }
    if (!hasBootConsoleProp) {
        [cmdTokens addObject:@"androidboot.console=ttyS0"];
    }
    if (isFirefoxOS && !hasSelinuxProp) {
        [cmdTokens addObject:@"androidboot.selinux=permissive"];
    }
    [cmdTokens addObject:@"android.qemud=1"];
    if (!gpuEnabled) {
        [cmdTokens addObject:@"qemu.gles=0"];
    }
    cmdline = [cmdTokens componentsJoinedByString:@" "];

    NSString *kernelPath = [vc.baseDirPath stringByAppendingPathComponent:@"kernel-qemu"];
    NSString *ramdiskPath = [vc.baseDirPath stringByAppendingPathComponent:@"ramdisk.img"];
    NSString *systemPath = [vc.baseDirPath stringByAppendingPathComponent:@"system.img"];
    if (![fm fileExistsAtPath:kernelPath] || ![fm fileExistsAtPath:ramdiskPath] || ![fm fileExistsAtPath:systemPath]) {
        emulator_finish_thread_ui(vc, @"Missing Android base firmware images (kernel-qemu / ramdisk.img / system.img).");
        return NULL;
    }
    if (!isFirefoxOS26 && apiLevel >= 14 && ramMB > 760) {
        NSString *highmemPath = [[NSBundle mainBundle] pathForResource:@"goldfish-highmem" ofType:@"zImage"];
        if (highmemPath.length == 0 || ![fm fileExistsAtPath:highmemPath]) {
            NSString *basesRoot = [vc.baseDirPath stringByDeletingLastPathComponent];
            for (NSString *cand in @[@"android-24-aosp/kernel-qemu", @"android-25-gapps/kernel-qemu"]) {
                NSString *p = [basesRoot stringByAppendingPathComponent:cand];
                if ([fm fileExistsAtPath:p]) {
                    highmemPath = p;
                    break;
                }
            }
        }
        if (highmemPath.length > 0 && [fm fileExistsAtPath:highmemPath]) {
            kernelPath = highmemPath;
            NSLog(@"[EmulatorVC] Using CONFIG_HIGHMEM Goldfish 3.4.67 kernel for %ld MB RAM: %@", (long)ramMB, kernelPath);
        } else {
            NSLog(@"[EmulatorVC] Clamping Android RAM from %ld MB to 760 MB (stock goldfish kernel lowmem limit)", (long)ramMB);
            ramMB = 760;
        }
    }

    // Isolate mutable userdata/cache per container under stateDirPath without clobbering existing images.
    for (NSString *imgName in @[@"userdata.img", @"cache.img"]) {
        NSString *dst = [vc.stateDirPath stringByAppendingPathComponent:imgName];
        if (![fm fileExistsAtPath:dst]) {
            NSString *src = [vc.baseDirPath stringByAppendingPathComponent:imgName];
            if ([fm fileExistsAtPath:src]) {
                NSError *copyErr = nil;
                if (![fm copyItemAtPath:src toPath:dst error:&copyErr]) {
                    NSLog(@"[EmulatorVC] Failed copying %@ to state: %@", imgName, copyErr);
                }
            }
        }
    }
    NSString *userdataPath = [vc.stateDirPath stringByAppendingPathComponent:@"userdata.img"];
    NSString *cachePath = [vc.stateDirPath stringByAppendingPathComponent:@"cache.img"];
    int cacheRc = lighttouch_android_ensure_cache([cachePath UTF8String], [systemPath UTF8String]);
    if (cacheRc != 0 && ![fm fileExistsAtPath:cachePath]) {
        int cfd = open([cachePath UTF8String], O_CREAT | O_RDWR, 0644);
        if (cfd >= 0) {
            (void)ftruncate(cfd, 64 * 1024 * 1024);
            close(cfd);
        }
    }

    NSString *serialPath = [vc.stateDirPath stringByAppendingPathComponent:@"serial.log"];
    vc->_androidSerialFile = fopen([serialPath UTF8String], "w");

    vc->_pfnAndroidConfigureImages([systemPath UTF8String],
                                   [userdataPath UTF8String],
                                   [cachePath UTF8String]);
    if (vc->_pfnAndroidConfigureDisplay) {
        vc->_pfnAndroidConfigureDisplay((int)lcdW, (int)lcdH, (int)dpi);
    }
    vc->_screenWidth = lcdW;
    vc->_screenHeight = lcdH;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc updateMetalDisplayRotation];
        if (!vc.userMovedBarManually && vc.menuPositionMode != ClassicMenuPositionCustom) {
            [vc applyPreferredBarPositionAnimated:YES];
        }
    });
    if (vc->_pfnAndroidAddProp) {
        char dpiBuf[16], wBuf[16], hBuf[16];
        snprintf(dpiBuf, sizeof(dpiBuf), "%ld", (long)dpi);
        snprintf(wBuf, sizeof(wBuf), "%ld", (long)lcdW);
        snprintf(hBuf, sizeof(hBuf), "%ld", (long)lcdH);
        vc->_pfnAndroidAddProp("qemu.sf.lcd_density", dpiBuf);
        vc->_pfnAndroidAddProp("qemu.sf.lcd_width", wBuf);
        vc->_pfnAndroidAddProp("qemu.sf.lcd_height", hBuf);
        vc->_pfnAndroidAddProp("qemu.sf.fake_camera", "none");
        vc->_pfnAndroidAddProp("qemu.hw.mainkeys", "0");
        if (apiLevel > 0 && apiLevel <= 19 && ramMB >= 512) {
            vc->_pfnAndroidAddProp("dalvik.vm.heapgrowthlimit", "128m");
            vc->_pfnAndroidAddProp("dalvik.vm.heapsize", "256m");
        }
        if (!gpuEnabled) {
            vc->_pfnAndroidAddProp("qemu.gles", "0");
        }
    }
    if (vc->_pfnAndroidSetDirtyFrameCb) {
        vc->_pfnAndroidSetDirtyFrameCb(emulator_android_dirty_frame_cb, (__bridge void *)vc);
    } else {
        vc->_pfnAndroidSetFrameCb(emulator_android_frame_cb, (__bridge void *)vc);
    }
    vc->_pfnAndroidSetLogCb(emulator_android_serial_cb, (__bridge void *)vc);

    NSString * (^escapeDrivePath)(NSString *) = ^NSString *(NSString *path) {
        return [path stringByReplacingOccurrencesOfString:@"," withString:@",,"];
    };
    NSString *machineArg = [NSString stringWithFormat:@"android51,audiodev=audio,width=%ld,height=%ld,density=%ld,gpu=%@",
                            (long)lcdW, (long)lcdH, (long)dpi, gpuEnabled ? @"on" : @"off"];
    NSMutableArray<NSString *> *argStrings = [@[
        @"qemu-system-arm",
        @"-M", machineArg,
        @"-cpu", cpuModel,
        @"-m", [NSString stringWithFormat:@"%ld", (long)ramMB],
        @"-smp", @"1",
        @"-accel", @"tcg",
        @"-nodefaults",
        @"-no-reboot",
        @"-display", @"none",
        @"-serial", @"null",
        @"-monitor", @"none",
        @"-audiodev", @"none,id=audio",
        @"-nic", @"user,model=smc91c111,ipv6=off,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15",
        @"-kernel", kernelPath,
        @"-initrd", ramdiskPath,
        @"-append", cmdline,
        @"-drive", [NSString stringWithFormat:@"if=none,id=system,format=raw,cache=writeback,file=%@,readonly=on", escapeDrivePath(systemPath)],
        @"-drive", [NSString stringWithFormat:@"if=none,id=userdata,format=raw,cache=writeback,file=%@,readonly=off", escapeDrivePath(userdataPath)],
        @"-drive", [NSString stringWithFormat:@"if=none,id=cache,format=raw,cache=writeback,file=%@,readonly=off", escapeDrivePath(cachePath)]
    ] mutableCopy];

    int argc = (int)argStrings.count;
    char **argv = calloc((size_t)(argc + 1), sizeof(char *));
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup([argStrings[i] UTF8String]);
    }

    if (vc.onEngineProcessConsumed) {
        void (^consumedBlock)(void) = vc.onEngineProcessConsumed;
        dispatch_async(dispatch_get_main_queue(), consumedBlock);
    }

    AndroidQemuRunArgs *runArgs = malloc(sizeof(AndroidQemuRunArgs));
    runArgs->main_fn = vc->_pfnAndroidMain;
    runArgs->argc = argc;
    runArgs->argv = argv;
    runArgs->vc = vc;

    pthread_t qemuThread;
    pthread_attr_t qAttr;
    pthread_attr_init(&qAttr);
    pthread_attr_setstacksize(&qAttr, 4 * 1024 * 1024);
    pthread_attr_set_qos_class_np(&qAttr, QOS_CLASS_USER_INTERACTIVE, 0);
    int qrc = pthread_create(&qemuThread, &qAttr, emulator_android_qemu_thread, runArgs);
    pthread_attr_destroy(&qAttr);
    if (qrc != 0) {
        for (int i = 0; i < argc; i++) free(argv[i]);
        free(argv);
        free(runArgs);
        if (vc->_androidSerialFile) {
            fclose(vc->_androidSerialFile);
            vc->_androidSerialFile = NULL;
        }
        emulator_finish_thread_ui(vc, @"Failed to spawn Android QEMU thread.");
        return NULL;
    }
    pthread_detach(qemuThread);

    int16_t pcmBuf[2048];
    BOOL loggedFirstPCM = NO;
    uint32_t syncTicks = 0;
    while (__atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE) &&
           !__c11_atomic_load(&vc->_androidQemuExited, __ATOMIC_ACQUIRE)) {
        BOOL drainedAudio = NO;
        if (vc->_pfnAndroidAudioPull && vc.audioBridge) {
            int rate = 44100;
            int ch = 2;
            int frames = vc->_pfnAndroidAudioPull(pcmBuf, 1024, &rate, &ch);
            if (frames > 0) {
                drainedAudio = YES;
                if (rate >= 8000 &&
                    ((int)vc.audioBridge.sampleRate != rate ||
                     (ch > 0 && (int)vc.audioBridge.channels != ch))) {
                    [vc.audioBridge startPlaybackWithSampleRate:(double)rate channels:(ch > 0 ? ch : 2)];
                }
                if (!loggedFirstPCM) {
                    loggedFirstPCM = YES;
                    NSLog(@"[EmulatorVC] First Android audio packet: %d frames @ %d Hz (%d ch)", frames, rate, ch);
                }
                [vc.audioBridge pushPCMData:pcmBuf count:(uint32_t)frames];
            }
        }
        if ((++syncTicks % 3000u) == 0u && vc->_pfnAndroidSync) {
            vc->_pfnAndroidSync();
        }
        usleep(drainedAudio ? 3000 : 10000);
    }

    NSString *unexpectedErrorMsg = nil;
    if (__c11_atomic_load(&vc->_androidQemuExited, __ATOMIC_ACQUIRE) &&
        __atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE) &&
        !vc->_isStopping) {
        unexpectedErrorMsg = L(@"vm_unexpected_stop_msg");
    }

    if (vc->_pfnAndroidQuit) {
        vc->_pfnAndroidQuit();
    }
    for (int i = 0; i < 300; i++) {
        if (__c11_atomic_load(&vc->_androidQemuExited, __ATOMIC_ACQUIRE) ||
            __atomic_load_n(&vc->_forceStopRequested, __ATOMIC_ACQUIRE)) {
            break;
        }
        usleep(10000);
    }

    if (vc->_pfnAndroidSync) {
        vc->_pfnAndroidSync();
    }

    vc->_pfnAndroidSetFrameCb(NULL, NULL);
    vc->_pfnAndroidSetLogCb(NULL, NULL);
    if (vc->_androidSerialFile) {
        FILE *f = vc->_androidSerialFile;
        vc->_androidSerialFile = NULL;
        fclose(f);
    }

    emulator_finish_thread_ui(vc, unexpectedErrorMsg);
    return NULL;
}

static void emulator_winrt_frame_cb(void *opaque, int width, int height,
                                    int stride_bytes, const void *pixels) {
    EmulatorViewController *vc = (__bridge EmulatorViewController *)opaque;
    if (!vc || !pixels || width <= 0 || height <= 0 || stride_bytes <= 0) return;

    NSInteger fw = (NSInteger)width;
    NSInteger fh = (NSInteger)height;
    BOOL dimsChanged = (vc->_screenWidth != fw || vc->_screenHeight != fh);
    vc->_screenWidth = fw;
    vc->_screenHeight = fh;

    [vc.metalView updateFramePixels:pixels width:width height:height stride:stride_bytes];

    if (dimsChanged) {
        emulator_android_notify_dims_changed(vc, fw, fh);
    }
}

static void emulator_winrt_dirty_frame_cb(void *opaque, int full_w, int full_h,
                                          int x, int y, int width, int height,
                                          int stride_bytes, const void *pixels) {
    EmulatorViewController *vc = (__bridge EmulatorViewController *)opaque;
    if (!vc || !pixels || full_w <= 0 || full_h <= 0 || width <= 0 || height <= 0 || stride_bytes <= 0) return;

    NSInteger fw = (NSInteger)full_w;
    NSInteger fh = (NSInteger)full_h;
    BOOL dimsChanged = (vc->_screenWidth != fw || vc->_screenHeight != fh);
    vc->_screenWidth = fw;
    vc->_screenHeight = fh;

    if (vc->_androidMetalView) {
        [vc->_androidMetalView updateDirtyPixels:pixels
                                               x:x
                                               y:y
                                           width:width
                                          height:height
                                          stride:stride_bytes
                                       fullWidth:full_w
                                      fullHeight:full_h];
    } else {
        [vc.metalView updateFramePixels:pixels width:full_w height:full_h stride:stride_bytes];
    }

    if (dimsChanged) {
        emulator_android_notify_dims_changed(vc, fw, fh);
    }
}

typedef struct {
    int (*main_fn)(int, char **);
    int argc;
    char **argv;
    EmulatorViewController *vc;
} WinRTQemuRunArgs;

static void *emulator_winrt_qemu_thread(void *arg) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    WinRTQemuRunArgs *run = (WinRTQemuRunArgs *)arg;
    EmulatorViewController *vc = run->vc;
    @autoreleasepool {
        if (run->main_fn) {
            run->main_fn(run->argc, run->argv);
        }
    }
    for (int i = 0; i < run->argc; i++) {
        free(run->argv[i]);
    }
    free(run->argv);
    free(run);
    __c11_atomic_store(&vc->_winrtQemuExited, YES, __ATOMIC_RELEASE);
    return NULL;
}

static NSString *ClassicEscapeQemuDrivePath(NSString *path) {
    return [path stringByReplacingOccurrencesOfString:@"," withString:@",,"];
}

static BOOL ClassicCopySparseFile(NSString *srcPath, NSString *dstPath) {
    if (srcPath.length == 0 || dstPath.length == 0) return NO;

    int srcFd = open([srcPath fileSystemRepresentation], O_RDONLY);
    if (srcFd < 0) return NO;

    struct stat st;
    if (fstat(srcFd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(srcFd);
        return NO;
    }

    NSString *tmpPath = [dstPath stringByAppendingString:@".tmp"];
    unlink([tmpPath fileSystemRepresentation]);
    int dstFd = open([tmpPath fileSystemRepresentation], O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (dstFd < 0) {
        close(srcFd);
        return NO;
    }

    const size_t kChunk = 65536;
    uint8_t *buf = (uint8_t *)malloc(kChunk);
    if (!buf) {
        close(srcFd);
        close(dstFd);
        unlink([tmpPath fileSystemRepresentation]);
        return NO;
    }

    BOOL ok = YES;
    ssize_t n = 0;
    while ((n = read(srcFd, buf, kChunk)) > 0) {
        BOOL allZero = YES;
        const uint8_t *p = buf;
        size_t len = (size_t)n;
        for (size_t i = 0; i < len; i++) {
            if (p[i] != 0) {
                allZero = NO;
                break;
            }
        }
        if (allZero) {
            if (lseek(dstFd, (off_t)len, SEEK_CUR) < 0) {
                ok = NO;
                break;
            }
        } else {
            size_t written = 0;
            while (written < len) {
                ssize_t w = write(dstFd, buf + written, len - written);
                if (w <= 0) {
                    ok = NO;
                    break;
                }
                written += (size_t)w;
            }
            if (!ok) break;
        }
    }
    if (n < 0) {
        ok = NO;
    }
    free(buf);
    close(srcFd);

    if (ok && ftruncate(dstFd, st.st_size) != 0) {
        ok = NO;
    }
    close(dstFd);

    if (!ok) {
        unlink([tmpPath fileSystemRepresentation]);
        return NO;
    }
    if (rename([tmpPath fileSystemRepresentation], [dstPath fileSystemRepresentation]) != 0) {
        unlink([tmpPath fileSystemRepresentation]);
        return NO;
    }
    return YES;
}

static BOOL ClassicLoadWinRTEngine(EmulatorViewController *vc, const char *tag) {
    bool jitTimedOut = false;
    bool jitReady = ios_jit_is_available_detailed(1200, &jitTimedOut);
    vc.cachedJitAvailable = jitReady;
    if (!jitReady) {
        NSLog(@"[EmulatorVC] JIT unavailable for %s (%d); aborting", tag, (int)jitTimedOut);
        NSString *jitLostMsg = jitTimedOut ? L(@"jit_stikdebug_timeout_msg") : L(@"jit_disconnected_before_start_msg");
        emulator_finish_thread_ui(vc, jitLostMsg);
        return NO;
    }

    NSString *enginePath = [vc locateWinRTEngineLibrary];
    void *handle = dlopen([enginePath UTF8String], RTLD_LOCAL | RTLD_NOW);
    if (!handle) {
        const char *dlerr = dlerror();
        NSString *msg = [NSString stringWithFormat:@"Failed to load libqemu-winrt.dylib (%s)", dlerr ? dlerr : "unknown error"];
        NSLog(@"[EmulatorVC] %@", msg);
        emulator_finish_thread_ui(vc, msg);
        return NO;
    }

    vc->_winrtEngineHandle = handle;
    vc->_pfnWinrtMain = (int (*)(int, char **))dlsym(handle, "qemu_winrt_main");
    vc->_pfnWinrtSetFrameCb = (void (*)(void (*)(void *, int, int, int, const void *), void *))dlsym(handle, "qemu_winrt_ui_set_frame_callback");
    vc->_pfnWinrtSetDirtyFrameCb = (void (*)(void (*)(void *, int, int, int, int, int, int, int, const void *), void *))dlsym(handle, "qemu_winrt_ui_set_dirty_frame_callback");
    vc->_pfnWinrtPointerAbs = (void (*)(int, int, int))dlsym(handle, "qemu_winrt_ui_pointer_abs");
    vc->_pfnWinrtTouch = (void (*)(int, int, int, int))dlsym(handle, "qemu_winrt_ui_touch");
    vc->_pfnWinrtScroll = (void (*)(int))dlsym(handle, "qemu_winrt_ui_scroll");
    vc->_pfnWinrtKeyQcode = (void (*)(int, int))dlsym(handle, "qemu_winrt_ui_key_qcode");
    vc->_pfnWinrtSendCad = (void (*)(void))dlsym(handle, "qemu_winrt_ui_send_cad");
    vc->_pfnWinrtResetUsb = (void (*)(void))dlsym(handle, "qemu_winrt_ui_reset_usb_input");
    vc->_pfnWinrtAudioPull = (int (*)(int16_t *, int, int *, int *))dlsym(handle, "qemu_winrt_ui_audio_pull");
    vc->_pfnWinrtSync = (void (*)(void))dlsym(handle, "qemu_winrt_ui_sync");
    vc->_pfnWinrtQuit = (void (*)(void))dlsym(handle, "qemu_winrt_ui_quit");

    if (!vc->_pfnWinrtMain || !vc->_pfnWinrtSetFrameCb ||
        !vc->_pfnWinrtPointerAbs || !vc->_pfnWinrtKeyQcode || !vc->_pfnWinrtQuit) {
        NSLog(@"[EmulatorVC] Missing symbols in libqemu-winrt.dylib");
        emulator_finish_thread_ui(vc, @"Invalid libqemu-winrt.dylib symbol table.");
        return NO;
    }
    return YES;
}

static void ClassicRunVirtQemuSession(EmulatorViewController *vc,
                                      NSArray<NSString *> *argStrings,
                                      BOOL enableAudio,
                                      NSString *spawnFailMsg) {
    if (vc->_pfnWinrtSetDirtyFrameCb) {
        vc->_pfnWinrtSetDirtyFrameCb(emulator_winrt_dirty_frame_cb, (__bridge void *)vc);
    } else {
        vc->_pfnWinrtSetFrameCb(emulator_winrt_frame_cb, (__bridge void *)vc);
    }

    int argc = (int)argStrings.count;
    char **argv = calloc((size_t)(argc + 1), sizeof(char *));
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup([argStrings[i] UTF8String]);
    }

    if (vc.onEngineProcessConsumed) {
        void (^consumedBlock)(void) = vc.onEngineProcessConsumed;
        dispatch_async(dispatch_get_main_queue(), consumedBlock);
    }

    WinRTQemuRunArgs *runArgs = malloc(sizeof(WinRTQemuRunArgs));
    runArgs->main_fn = vc->_pfnWinrtMain;
    runArgs->argc = argc;
    runArgs->argv = argv;
    runArgs->vc = vc;

    pthread_t qemuThread;
    pthread_attr_t qAttr;
    pthread_attr_init(&qAttr);
    pthread_attr_setstacksize(&qAttr, 4 * 1024 * 1024);
    pthread_attr_set_qos_class_np(&qAttr, QOS_CLASS_USER_INTERACTIVE, 0);
    int qrc = pthread_create(&qemuThread, &qAttr, emulator_winrt_qemu_thread, runArgs);
    pthread_attr_destroy(&qAttr);
    if (qrc != 0) {
        for (int i = 0; i < argc; i++) free(argv[i]);
        free(argv);
        free(runArgs);
        emulator_finish_thread_ui(vc, spawnFailMsg);
        return;
    }
    pthread_detach(qemuThread);

    int16_t pcmBuf[2048];
    BOOL loggedFirstPCM = NO;
    uint32_t syncTicks = 0;
    while (__atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE) &&
           !__c11_atomic_load(&vc->_winrtQemuExited, __ATOMIC_ACQUIRE)) {
        BOOL drainedAudio = NO;
        if (enableAudio && vc->_pfnWinrtAudioPull && vc.audioBridge) {
            int rate = 44100;
            int ch = 2;
            int frames = vc->_pfnWinrtAudioPull(pcmBuf, 1024, &rate, &ch);
            if (frames > 0) {
                drainedAudio = YES;
                if (rate >= 8000 &&
                    ((int)vc.audioBridge.sampleRate != rate ||
                     (ch > 0 && (int)vc.audioBridge.channels != ch))) {
                    [vc.audioBridge startPlaybackWithSampleRate:(double)rate channels:(ch > 0 ? ch : 2)];
                }
                if (!loggedFirstPCM) {
                    loggedFirstPCM = YES;
                    NSLog(@"[EmulatorVC] First VirtIO/WinRT audio packet: %d frames @ %d Hz (%d ch)", frames, rate, ch);
                }
                [vc.audioBridge pushPCMData:pcmBuf count:(uint32_t)frames];
            }
        }
        if ((++syncTicks % 3000u) == 0u && vc->_pfnWinrtSync) {
            vc->_pfnWinrtSync();
        }
        usleep(drainedAudio ? 3000 : 10000);
    }

    NSString *unexpectedErrorMsg = nil;
    if (__c11_atomic_load(&vc->_winrtQemuExited, __ATOMIC_ACQUIRE) &&
        __atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE) &&
        !vc->_isStopping) {
        unexpectedErrorMsg = L(@"vm_unexpected_stop_msg");
    }

    if (vc->_pfnWinrtQuit) {
        vc->_pfnWinrtQuit();
    }
    for (int i = 0; i < 300; i++) {
        if (__c11_atomic_load(&vc->_winrtQemuExited, __ATOMIC_ACQUIRE) ||
            __atomic_load_n(&vc->_forceStopRequested, __ATOMIC_ACQUIRE)) {
            break;
        }
        usleep(10000);
    }

    if (vc->_pfnWinrtSync) {
        vc->_pfnWinrtSync();
    }
    if (vc->_pfnWinrtSetDirtyFrameCb) {
        vc->_pfnWinrtSetDirtyFrameCb(NULL, NULL);
    }
    if (vc->_pfnWinrtSetFrameCb) {
        vc->_pfnWinrtSetFrameCb(NULL, NULL);
    }

    emulator_finish_thread_ui(vc, unexpectedErrorMsg);
}

static void *emulator_winrt_worker(EmulatorViewController *vc) {
    NSLog(@"[EmulatorVC] Starting ARM Virt worker for %@ (platform=%@)", vc.machineId, vc.platform ?: @"winrt");
    __atomic_store_n(&vc->_boardSupportsAccel, NO, __ATOMIC_RELEASE);
    __atomic_store_n(&vc->_boardSupportsGyro, NO, __ATOMIC_RELEASE);
    __c11_atomic_init(&vc->_winrtQemuExited, NO);

    const char *engineLabel = vc->_isChromeOSMode ? "ChromeOS" : (vc->_isUbuntuTouchVirtMode ? "UbuntuTouch" : "WinRT");
    if (!ClassicLoadWinRTEngine(vc, engineLabel)) {
        return NULL;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:vc.stateDirPath withIntermediateDirectories:YES attributes:nil error:nil];

    NSString * (^resolveWinRTPath)(NSString *) = ^NSString *(NSString *pathOrName) {
        if (pathOrName.length == 0) return @"";
        if ([pathOrName isAbsolutePath]) return pathOrName;
        return [vc.stateDirPath stringByAppendingPathComponent:pathOrName];
    };

    NSString *diskFull = resolveWinRTPath(vc.winrtDiskPath);
    if (diskFull.length == 0) {
        NSString *qcowFallback = [vc.stateDirPath stringByAppendingPathComponent:(vc->_isUbuntuTouchVirtMode ? @"userdata.qcow2" : @"sdcard.qcow2")];
        NSString *rawFallback = [vc.stateDirPath stringByAppendingPathComponent:@"sdcard.img"];
        if ([fm fileExistsAtPath:qcowFallback]) {
            diskFull = qcowFallback;
        } else if ([fm fileExistsAtPath:rawFallback]) {
            diskFull = rawFallback;
        }
    }
    NSString *isoFull = resolveWinRTPath(vc.winrtIsoPath);
    BOOL hasDisk = (diskFull.length > 0 && [fm fileExistsAtPath:diskFull]);
    BOOL hasIso = (isoFull.length > 0 && [fm fileExistsAtPath:isoFull]);

    NSInteger defaultRam = (vc->_isChromeOSMode || vc->_isUbuntuTouchVirtMode) ? 1536 : 2048;
    NSInteger ramMB = (vc.androidRamMB >= 512) ? vc.androidRamMB : defaultRam;
    if (ramMB < 512) ramMB = 512;
    if (ramMB > 2048) ramMB = 2048;
    uint64_t physMem = [NSProcessInfo processInfo].physicalMemory;
    if (physMem < (3ULL * 1024ULL * 1024ULL * 1024ULL) && ramMB > 768) {
        ramMB = 768;
    } else if (physMem < (4ULL * 1024ULL * 1024ULL * 1024ULL) && ramMB > 1536) {
        ramMB = 1536;
    }

    NSString * (^formatForImagePath)(NSString *) = ^NSString *(NSString *path) {
        NSString *ext = path.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"vhd"]) return @"vpc";
        if ([ext isEqualToString:@"vhdx"]) return @"vhdx";
        if ([ext isEqualToString:@"qcow2"]) return @"qcow2";
        return @"raw";
    };

    NSString *serialPath = [vc.stateDirPath stringByAppendingPathComponent:@"serial.log"];

    if (vc->_isChromeOSMode || vc->_isUbuntuTouchVirtMode) {
        NSString *kernelPath = [vc locateLinuxVirtKernel];
        NSString *initrdPath = [vc locateLinuxVirtInitrd];
        if (kernelPath.length == 0 || ![fm fileExistsAtPath:kernelPath] ||
            initrdPath.length == 0 || ![fm fileExistsAtPath:initrdPath]) {
            emulator_finish_thread_ui(vc, @"Missing bundled Linux Virt kernel/initrd (linux-virt/vmlinuz-virt-armhf).");
            return NULL;
        }

        NSUInteger hostCores = [NSProcessInfo processInfo].processorCount;
        NSInteger linuxVcpus = (hostCores >= 6) ? 4 : 2;
        NSString *linuxVcpusStr = [NSString stringWithFormat:@"%ld", (long)linuxVcpus];

        void (^appendCommonVirtTail)(NSMutableArray<NSString *> *) = ^(NSMutableArray<NSString *> *args) {
            if (vc.winrtEnableNet) {
                [args addObject:@"-netdev"];
                [args addObject:@"user,id=net0,ipv6=off,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15"];
                [args addObject:@"-device"];
                [args addObject:@"virtio-net-pci,netdev=net0,romfile="];
            }
            if (vc.winrtEnableAudio) {
                [args addObject:@"-device"];
                [args addObject:@"qemu-xhci,id=xhci"];
                [args addObject:@"-audiodev"];
                [args addObject:@"none,id=audio"];
                [args addObject:@"-device"];
                [args addObject:@"usb-audio,audiodev=audio,bus=xhci.0"];
            } else {
                [vc.audioBridge stop];
            }
            [args addObject:@"-rtc"];
            [args addObject:@"base=utc,clock=vm"];
        };

        if (vc->_isChromeOSMode) {
            if (!hasIso) {
                emulator_finish_thread_ui(vc, @"Chrome OS recovery image is missing. Download it from Container Settings.");
                return NULL;
            }
            NSMutableArray<NSString *> *crosArgs = [@[
                @"qemu-system-arm",
                @"-M", @"virt,highmem=false",
                @"-cpu", @"cortex-a15",
                @"-smp", linuxVcpusStr,
                @"-accel", @"tcg,thread=multi",
                @"-m", [NSString stringWithFormat:@"%ld", (long)ramMB],
                @"-kernel", kernelPath,
                @"-initrd", initrdPath,
                @"-append", @"console=ttyAMA0,115200 rw cros_debug ct_mode=chromeos ct_gfx=bochs video=1024x768-32",
                @"-nodefaults",
                @"-display", @"none",
                @"-monitor", @"none",
                @"-serial", [NSString stringWithFormat:@"file:%@", serialPath],
                @"-device", @"VGA,vgamem_mb=16,romfile=",
                @"-device", @"virtio-keyboard-pci",
                @"-device", @"virtio-tablet-pci",
                @"-device", @"virtio-rng-pci",
                @"-drive", [NSString stringWithFormat:@"id=hd0,if=none,format=raw,readonly=on,file.locking=off,file=%@",
                            ClassicEscapeQemuDrivePath(isoFull)],
                @"-device", @"virtio-blk-pci,drive=hd0"
            ] mutableCopy];
            if (hasDisk) {
                [crosArgs addObject:@"-drive"];
                [crosArgs addObject:[NSString stringWithFormat:@"id=hd1,if=none,format=%@,cache=writeback,file=%@",
                                     formatForImagePath(diskFull), ClassicEscapeQemuDrivePath(diskFull)]];
                [crosArgs addObject:@"-device"];
                [crosArgs addObject:@"virtio-blk-pci,drive=hd1"];
            }
            appendCommonVirtTail(crosArgs);
            ClassicRunVirtQemuSession(vc, crosArgs, vc.winrtEnableAudio, @"Failed to spawn Chrome OS ARM QEMU thread.");
            return NULL;
        }

        // Isolated Ubuntu Touch Virt (-M virt + virtio-gpu-pci, completely independent of Goldfish)
        NSString *rootfsPath = [vc.stateDirPath stringByAppendingPathComponent:@"rootfs.ext4"];
        if (![fm fileExistsAtPath:rootfsPath]) {
            NSString *baseRootfs = [vc.baseDirPath stringByAppendingPathComponent:@"rootfs.ext4"];
            if ([fm fileExistsAtPath:baseRootfs]) {
                NSError *cpErr = nil;
                [fm copyItemAtPath:baseRootfs toPath:rootfsPath error:&cpErr];
            }
        }
        if (![fm fileExistsAtPath:rootfsPath]) {
            emulator_finish_thread_ui(vc, @"Ubuntu Touch rootfs.ext4 is missing. Recreate the container from Settings.");
            return NULL;
        }
        NSString *userdataPath = hasDisk ? diskFull : [vc.stateDirPath stringByAppendingPathComponent:@"userdata.qcow2"];
        BOOL hasUserdata = (userdataPath.length > 0 && [fm fileExistsAtPath:userdataPath]);

        NSMutableArray<NSString *> *utArgs = [@[
            @"qemu-system-arm",
            @"-M", @"virt,highmem=false",
            @"-cpu", @"cortex-a15",
            @"-smp", linuxVcpusStr,
            @"-accel", @"tcg,thread=multi",
            @"-m", [NSString stringWithFormat:@"%ld", (long)ramMB],
            @"-kernel", kernelPath,
            @"-initrd", initrdPath,
            @"-append", @"console=ttyAMA0,115200 rw ct_mode=ubuntutouch ct_gfx=virtio",
            @"-nodefaults",
            @"-display", @"none",
            @"-monitor", @"none",
            @"-serial", [NSString stringWithFormat:@"file:%@", serialPath],
            @"-device", @"virtio-gpu-pci,xres=432,yres=768,romfile=",
            @"-device", @"virtio-keyboard-pci",
            @"-device", @"virtio-multitouch-pci",
            @"-device", @"virtio-rng-pci",
            @"-drive", [NSString stringWithFormat:@"id=hd0,if=none,format=raw,cache=writeback,file=%@",
                        ClassicEscapeQemuDrivePath(rootfsPath)],
            @"-device", @"virtio-blk-pci,drive=hd0"
        ] mutableCopy];
        if (hasUserdata) {
            [utArgs addObject:@"-drive"];
            [utArgs addObject:[NSString stringWithFormat:@"id=hd1,if=none,format=%@,cache=writeback,file=%@",
                                 formatForImagePath(userdataPath), ClassicEscapeQemuDrivePath(userdataPath)]];
            [utArgs addObject:@"-device"];
            [utArgs addObject:@"virtio-blk-pci,drive=hd1"];
        }
        appendCommonVirtTail(utArgs);
        ClassicRunVirtQemuSession(vc, utArgs, vc.winrtEnableAudio, @"Failed to spawn Ubuntu Touch Virt QEMU thread.");
        return NULL;
    }

    NSString *fwPath = [vc locateWinRTFirmware];
    if (fwPath.length == 0 || ![fm fileExistsAtPath:fwPath]) {
        emulator_finish_thread_ui(vc, @"Missing UEFI firmware (QEMU_EFI_1512_driver1998.fd).");
        return NULL;
    }

    if (!hasDisk && !hasIso) {
        emulator_finish_thread_ui(vc, L(@"winrt_missing_media_error"));
        return NULL;
    }

    if (hasDisk) {
        ClassicWinRTMediaInfo diskProbe = ClassicProbeWinRTMedia(diskFull);
        NSLog(@"[WinRT] SD disk probe: %@ (%llu bytes)", ClassicDescribeWinRTMedia(diskProbe), diskProbe.fileSize);
    }
    if (hasIso) {
        ClassicWinRTMediaInfo isoProbe = ClassicProbeWinRTMedia(isoFull);
        NSLog(@"[WinRT] USB/ISO probe: %@ (%llu bytes)", ClassicDescribeWinRTMedia(isoProbe), isoProbe.fileSize);
    }

    NSString *nvramPath = [vc.stateDirPath stringByAppendingPathComponent:@"nvram.bin"];
    const uint64_t kWinRTNvramBytes = 64ULL * 1024ULL * 1024ULL;
    NSDictionary *nvramAttrs = [fm attributesOfItemAtPath:nvramPath error:nil];
    if (!nvramAttrs || [nvramAttrs fileSize] != kWinRTNvramBytes) {
        int nfd = open([nvramPath UTF8String], O_CREAT | O_RDWR, 0644);
        if (nfd >= 0) {
            if (ftruncate(nfd, (off_t)kWinRTNvramBytes) != 0) {
                NSLog(@"[EmulatorVC] Warning: failed sizing WinRT NVRAM %@", nvramPath);
            }
            close(nfd);
        }
    }
    nvramAttrs = [fm attributesOfItemAtPath:nvramPath error:nil];
    BOOL hasNvram = (nvramAttrs && [nvramAttrs fileSize] == kWinRTNvramBytes);

    NSMutableArray<NSString *> *argStrings = [@[
        @"qemu-system-arm",
        @"-M", @"virt,winrt=on,highmem=false",
        @"-cpu", @"cortex-a15",
        @"-smp", @"1",
        @"-accel", @"tcg,thread=single",
        @"-m", [NSString stringWithFormat:@"%ld", (long)ramMB],
        @"-bios", fwPath,
        @"-nodefaults",
        @"-display", @"none",
        @"-monitor", @"none",
        @"-serial", [NSString stringWithFormat:@"file:%@", serialPath],
        @"-device", @"VGA,romfile=",
        @"-device", @"usb-kbd,id=kbd,bus=usb-bus.0",
        @"-device", @"usb-tablet,id=mice,bus=usb-bus.0"
    ] mutableCopy];
    if (hasNvram) {
        NSUInteger biosIdx = [argStrings indexOfObject:@"-bios"];
        NSUInteger insertIdx = (biosIdx != NSNotFound) ? (biosIdx + 2) : argStrings.count;
        [argStrings insertObject:[NSString stringWithFormat:@"if=pflash,format=raw,unit=1,file=%@", ClassicEscapeQemuDrivePath(nvramPath)]
                         atIndex:insertIdx];
        [argStrings insertObject:@"-drive" atIndex:insertIdx];
    }

    void (^appendSdCardArgs)(void) = ^{
        [argStrings addObject:@"-drive"];
        [argStrings addObject:[NSString stringWithFormat:@"id=mydrive,if=none,format=%@,cache=writeback,file=%@",
                               formatForImagePath(diskFull), ClassicEscapeQemuDrivePath(diskFull)]];
        [argStrings addObject:@"-device"];
        [argStrings addObject:@"sd-card,drive=mydrive"];
    };
    void (^appendUsbMediaArgs)(void) = ^{
        BOOL isIso = [isoFull.pathExtension.lowercaseString isEqualToString:@"iso"];
        NSString *bootProp = (vc.winrtBootFromIso || !hasDisk) ? @",bootindex=0" : @"";
        if (isIso) {
            [argStrings addObject:@"-drive"];
            [argStrings addObject:[NSString stringWithFormat:@"id=usbcdrom,if=none,media=cdrom,format=raw,readonly=on,file.locking=off,file=%@",
                                   ClassicEscapeQemuDrivePath(isoFull)]];
            [argStrings addObject:@"-device"];
            [argStrings addObject:[NSString stringWithFormat:@"usb-storage,drive=usbcdrom,bus=usb-bus.0%@", bootProp]];
        } else {
            [argStrings addObject:@"-drive"];
            [argStrings addObject:[NSString stringWithFormat:@"id=usbstick,if=none,format=%@,cache=writeback,file.locking=off,file=%@",
                                   formatForImagePath(isoFull), ClassicEscapeQemuDrivePath(isoFull)]];
            [argStrings addObject:@"-device"];
            [argStrings addObject:[NSString stringWithFormat:@"usb-storage,drive=usbstick,bus=usb-bus.0%@", bootProp]];
        }
    };

    if (vc.winrtBootFromIso && hasIso) {
        appendUsbMediaArgs();
        if (hasDisk) appendSdCardArgs();
    } else {
        if (hasDisk) appendSdCardArgs();
        if (hasIso) appendUsbMediaArgs();
    }

    if (vc.winrtEnableNet) {
        [argStrings addObject:@"-netdev"];
        [argStrings addObject:@"user,id=net0,ipv6=off,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15"];
        [argStrings addObject:@"-device"];
        [argStrings addObject:@"usb-net,netdev=net0,winrt-rndis=on,bus=usb-bus.0"];
    }
    if (vc.winrtEnableAudio) {
        [argStrings addObject:@"-audiodev"];
        [argStrings addObject:@"none,id=audio"];
        [argStrings addObject:@"-device"];
        [argStrings addObject:@"usb-audio,audiodev=audio,bus=usb-bus.1"];
    } else {
        [vc.audioBridge stop];
    }

    NSString *rtcDate = vc.winrtRtcDate;
    NSString *rtcArg = (rtcDate.length > 0 && ![rtcDate isEqualToString:@"today"] && ![rtcDate isEqualToString:@"utc"])
        ? [NSString stringWithFormat:@"base=%@,clock=vm", rtcDate]
        : @"base=utc,clock=vm";
    [argStrings addObject:@"-rtc"];
    [argStrings addObject:rtcArg];

    ClassicRunVirtQemuSession(vc, argStrings, vc.winrtEnableAudio, @"Failed to spawn Windows RT QEMU thread.");
    return NULL;
}

static void *emulator_worker_thread(void *arg) {
    // Keep supervisor slightly below QEMU vCPU USER_INTERACTIVE so A11 dual P-cores prioritize TCG execution.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    EmulatorViewController *vc = (__bridge_transfer EmulatorViewController *)arg;
    NSLog(@"[EmulatorVC] Starting emulator worker for %@", vc.machineId);

    if (vc->_isWinRTMode) {
        return emulator_winrt_worker(vc);
    }
    if (vc->_isAndroidMode) {
        return emulator_android_worker(vc);
    }

    // 1. Open Device
    lt_device_config dev_cfg = LT_INIT(lt_device_config);
    dev_cfg.base_path = [vc.baseDirPath UTF8String];
    dev_cfg.state_path = [vc.stateDirPath UTF8String];
    dev_cfg.allow_dirty = 1;

    lt_device *device = NULL;
    lt_error err = LT_INIT(lt_error);
    lt_status st = lt_device_open(&dev_cfg, &device, &err);
    if (st != LT_OK) {
        NSLog(@"[EmulatorVC] lt_device_open failed: %d (%s)", st, err.message);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"device_boot_error")
                                                                           message:[NSString stringWithUTF8String:err.message]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [vc dismissViewControllerAnimated:YES completion:nil];
            }]];
            [vc presentViewController:alert animated:YES completion:nil];
        });
        emulator_finish_thread_ui(vc, nil);
        return NULL;
    }
    vc->_device = device;

    // 2. Create Runtime (QEMU TCG manages its adaptive split-WX JIT buffer directly)
    NSString *enginePath = [vc locateEngineLibrary];
    lt_device_info devInfo = LT_INIT(lt_device_info);
    if (lt_device_describe(device, &devInfo, &err) != LT_OK) {
        NSLog(@"[EmulatorVC] lt_device_describe warning: %s", err.message);
    }
    lt_board_info boardInfo = LT_INIT(lt_board_info);
    lt_status boardStatus = lt_engine_board([enginePath UTF8String], devInfo.board, &boardInfo, &err);
    if (boardStatus != LT_OK) {
        NSLog(@"[EmulatorVC] lt_engine_board warning for '%s': %s", devInfo.board, err.message);
    }
    __atomic_store_n(&vc->_boardSupportsAccel, (boardStatus == LT_OK) ? ((boardInfo.capabilities & 1ULL) != 0) : YES, __ATOMIC_RELEASE);
    __atomic_store_n(&vc->_boardSupportsGyro, (boardStatus == LT_OK) && ((boardInfo.capabilities & 2ULL) != 0), __ATOMIC_RELEASE);
    NSString *ppnMarkerPath = [vc.stateDirPath stringByAppendingPathComponent:@".ppn_initialized"];
    NSFileManager *workerFm = [NSFileManager defaultManager];
    BOOL isN42PpnInitBoot = (strcmp(devInfo.board, "n42ap") == 0) &&
        [workerFm fileExistsAtPath:[vc.baseDirPath stringByAppendingPathComponent:@"kboot-restore.bin"]] &&
        [workerFm fileExistsAtPath:[vc.baseDirPath stringByAppendingPathComponent:@"initial.a6di"]] &&
        ![workerFm fileExistsAtPath:ppnMarkerPath];

    NSString *guestPackagePath = isN42PpnInitBoot ? nil : ClassicLocateGuestPackage(devInfo.board, devInfo.build);
    if (guestPackagePath) {
        NSLog(@"[EmulatorVC] Guest package for %s-%s: %@", devInfo.board, devInfo.build, guestPackagePath);
    } else if (!isN42PpnInitBoot) {
        NSLog(@"[EmulatorVC] Warning: no guest package (.itpack) found for %s-%s", devInfo.board, devInfo.build);
    }

    lt_runtime_config run_cfg = LT_INIT(lt_runtime_config);
    run_cfg.engine_library = [enginePath UTF8String];
    NSLog(@"[EmulatorVC] QEMU Engine configured: %@", enginePath);
    run_cfg.device = device;
    run_cfg.boot.size = sizeof(lt_boot_config);
    run_cfg.boot.version = LT_ABI_VERSION;
    run_cfg.boot.audio_enabled = 1;
    run_cfg.boot.headphones = (boardStatus == LT_OK && (boardInfo.capabilities & LT_BOARD_HEADPHONES)) ? 1 : 0;
    run_cfg.boot.network_mode = 1; // direct NAT

    NSString *proxyIdentityDir = [vc.stateDirPath stringByAppendingPathComponent:@"network-proxy"];
    NSString *tempDir = NSTemporaryDirectory();
    if ([tempDir hasPrefix:@"/private/var/"]) {
        tempDir = [@"/var/" stringByAppendingString:[tempDir substringFromIndex:@"/private/var/".length]];
    }
    NSString *proxySocketPath = [tempDir stringByAppendingPathComponent:@"p.sock"];
    if (proxySocketPath.length >= 103) {
        proxySocketPath = @"/tmp/p.sock";
    }
    NSString *proxyErrMsg = nil;
    IOSNetworkProxy *networkProxy = [IOSNetworkProxy startWithIdentityDirectory:proxyIdentityDir
                                                                    socketPath:proxySocketPath
                                                                  errorMessage:&proxyErrMsg];
    if (networkProxy) {
        run_cfg.boot.network_socket = [networkProxy.socketPath fileSystemRepresentation];
        NSLog(@"[EmulatorVC] Host HTTP/TLS proxy listening at %@", networkProxy.socketPath);
    } else {
        NSLog(@"[EmulatorVC] Host HTTP/TLS proxy unavailable (%@); falling back to direct SLIRP NAT", proxyErrMsg);
    }

    NSError *usbErr = nil;
    IOSUsbMuxBridge *usbBridge = isN42PpnInitBoot ? nil : [IOSUsbMuxBridge startWithError:&usbErr];
    if (usbBridge) {
        setenv("IT_USB_TCP", [usbBridge.tcpAddress UTF8String], 1);
        vc.usbBridge = usbBridge;
        NSLog(@"[EmulatorVC] USB mux bridge listening at %@", usbBridge.tcpAddress);
    } else {
        unsetenv("IT_USB_TCP");
        if (!isN42PpnInitBoot) {
            NSLog(@"[EmulatorVC] USB mux bridge unavailable (%@)", usbErr.localizedDescription);
        }
    }

    if (guestPackagePath) {
        run_cfg.boot.guest_package_path = [guestPackagePath UTF8String];
    }

    [NSTimeZone resetSystemTimeZone];
    NSString *tzName = [NSTimeZone localTimeZone].name;
    if (tzName.length > 0) {
        setenv("TZ", tzName.UTF8String, 1);
        tzset();
    }

    NSString *bootromPath = [vc locateBootromForMachine:devInfo.board];
    if (bootromPath) {
        run_cfg.boot.bootrom_path = [bootromPath UTF8String];
        NSLog(@"[EmulatorVC] BootROM configured: %@", bootromPath);
    }
    NSString *serialPath = [vc.stateDirPath stringByAppendingPathComponent:@"serial.log"];
    if (isN42PpnInitBoot) {
        [workerFm removeItemAtPath:serialPath error:nil];
    }
    run_cfg.boot.serial_path = [serialPath UTF8String];

    lt_runtime *runtime = NULL;
    st = lt_runtime_create(&run_cfg, &runtime, &err);
    (void)guestPackagePath.length;
    if (st != LT_OK) {
        NSLog(@"[EmulatorVC] lt_runtime_create failed: %d (%s)", st, err.message);
        if (st == LT_BUSY && vc.onEngineProcessConsumed) {
            void (^consumedBlock)(void) = vc.onEngineProcessConsumed;
            dispatch_async(dispatch_get_main_queue(), consumedBlock);
        }
        NSString *rawErr = [NSString stringWithUTF8String:err.message[0] ? err.message : "Runtime creation failed"];
        NSString *userMsg = rawErr;
        if ([rawErr containsString:@"boot ROM"]) {
            userMsg = [NSString stringWithFormat:L(@"bootrom_missing_detail_fmt"), rawErr];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"boot_error")
                                                                           message:userMsg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [vc dismissViewControllerAnimated:YES completion:nil];
            }]];
            [vc presentViewController:alert animated:YES completion:nil];
        });
        [networkProxy stop];
        vc.usbBridge = nil;
        [usbBridge stop];
        unsetenv("IT_USB_TCP");
        lt_device_close(device);
        vc->_device = NULL;
        emulator_finish_thread_ui(vc, nil);
        return NULL;
    }
    vc->_runtime = runtime;

    // 3. Final pre-flight JIT verification BEFORE consuming the process or starting QEMU
    if (!__atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE)) {
        lt_runtime_destroy(runtime, &err);
        [networkProxy stop];
        vc.usbBridge = nil;
        [usbBridge stop];
        unsetenv("IT_USB_TCP");
        lt_device_close(device);
        vc->_runtime = NULL;
        vc->_device = NULL;
        emulator_finish_thread_ui(vc, nil);
        return NULL;
    }
    bool jitTimedOut = false;
    bool jitReady = ios_jit_is_available_detailed(1200, &jitTimedOut);
    vc.cachedJitAvailable = jitReady;
    if (!jitReady) {
        NSLog(@"[EmulatorVC] JIT lost before runtime start (timedOut=%d); aborting cleanly without consuming process", (int)jitTimedOut);
        NSString *jitLostMsg = jitTimedOut ? L(@"jit_stikdebug_timeout_msg") : L(@"jit_disconnected_before_start_msg");
        lt_runtime_destroy(runtime, &err);
        [networkProxy stop];
        vc.usbBridge = nil;
        [usbBridge stop];
        unsetenv("IT_USB_TCP");
        lt_device_close(device);
        vc->_runtime = NULL;
        vc->_device = NULL;
        emulator_finish_thread_ui(vc, jitLostMsg);
        return NULL;
    }

    // 4. Attach direct pixel listener + zero-copy GPU IOSurface -> Metal callback
    lt_runtime_set_frame_pixel_listener(runtime, s_frame_pixel_listener, (__bridge void *)vc, &err);
    emulator_set_direct_iosurface_cb(s_direct_iosurface_listener, (__bridge void *)vc);

    if (vc.onEngineProcessConsumed) {
        void (^consumedBlock)(void) = vc.onEngineProcessConsumed;
        dispatch_async(dispatch_get_main_queue(), consumedBlock);
    }

    NSString *unexpectedErrorMsg = nil;
    ClassicGuestTrustContext trustCtx = {0};

    // 5. Start Runtime loop
    st = lt_runtime_start(runtime, &err);
    if (st != LT_OK) {
        NSLog(@"[EmulatorVC] lt_runtime_start returned %d (%s)", st, err.message);
        NSString *rawErr = [NSString stringWithUTF8String:err.message[0] ? err.message : "Runtime start failed"];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"emulation_error")
                                                                           message:rawErr
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [vc dismissViewControllerAnimated:YES completion:nil];
            }]];
            [vc presentViewController:alert animated:YES completion:nil];
        });
        goto cleanup;
    }

    // 6. Polling & Audio Pull Loop
    BOOL isOS1xBuild = (devInfo.build[0] == '1' && !isdigit((unsigned char)devInfo.build[1]));
    BOOL guestSupportsProxyTools = !isN42PpnInitBoot &&
        devInfo.build[0] != '\0' &&
        !isOS1xBuild &&
        devInfo.build[0] != '3' &&
        devInfo.build[0] != '4' &&
        devInfo.build[0] != '5' &&
        strncmp(devInfo.build, "7A", 2) != 0;
    if (networkProxy && guestSupportsProxyTools) {
        NSString *markerPath = [vc.stateDirPath stringByAppendingPathComponent:@"proxy-ca-trusted.fp"];
        NSString *toolsDir = ClassicGuestToolsDirectory();
        NSString *ittrustPath = [toolsDir stringByAppendingPathComponent:@"ittrust"];
        NSString *itproxyPath = [toolsDir stringByAppendingPathComponent:@"itproxy"];
        trustCtx.ittrustData = [NSData dataWithContentsOfFile:ittrustPath];
        trustCtx.itproxyData = [NSData dataWithContentsOfFile:itproxyPath];
        trustCtx.certDER = networkProxy.certificateDER;
        trustCtx.fingerprint = networkProxy.certificateFingerprint;
        trustCtx.markerPath = markerPath;
        trustCtx.stage = (trustCtx.ittrustData.length > 0 && trustCtx.itproxyData.length > 0 && trustCtx.certDER.length > 0) ? 0 : 6;
    } else {
        trustCtx.stage = 6;
    }

    if (isN42PpnInitBoot) {
        NSLog(@"[EmulatorVC] Running iPhone 5 first-boot PPN NAND initialization...");
        dispatch_async(dispatch_get_main_queue(), ^{
            vc.ipaCancelButton.hidden = YES;
            vc.ipaProgressBar.progress = 0.1f;
            vc.ipaProgressLabel.text = L(@"n42_ppn_init_banner");
            vc.ipaProgressCard.hidden = NO;
            if (vc.hardwareBar) {
                [vc.view bringSubviewToFront:vc.hardwareBar];
            }
        });
    }

    int16_t pcm_samples[4096 * 2];
    BOOL loggedFirstPCM = NO;
    BOOL n42PpnCompletedCleanly = NO;
    BOOL isN42NormalBoot = (strcmp(devInfo.board, "n42ap") == 0) && !isN42PpnInitBoot;
    uint64_t n42DiagReqId = 0;
    int n42DiagCount = 0;
    CFAbsoluteTime n42DiagNextTime = 0;
    uint64_t n42PrevFrames = 0;
    CFAbsoluteTime ppnStartTime = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime lastPpnProgressCheck = 0;
    CFAbsoluteTime carrierApplyTime = CFAbsoluteTimeGetCurrent() + 5.0;
    BOOL carrierApplied = NO;
    while (__atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE)) {
        lt_runtime_status rstat = LT_INIT(lt_runtime_status);
        lt_error pollErr = LT_INIT(lt_error);
        lt_status pollSt = lt_runtime_poll(runtime, &rstat, &pollErr);

        if (pollSt == LT_OK && rstat.state == LT_RUNNING && !carrierApplied && CFAbsoluteTimeGetCurrent() >= carrierApplyTime) {
            ClassicApplyCarrierNameIfConfigured();
            carrierApplied = YES;
        }

        if (pollSt == LT_OK && rstat.state == LT_RUNNING && trustCtx.stage < 6) {
            ClassicGuestNetworkTrustStep(runtime, &trustCtx);
        } else if (isN42NormalBoot && pollSt == LT_OK && rstat.state == LT_RUNNING && trustCtx.stage >= 6 && n42DiagCount < 60) {
            lt_error derr = LT_INIT(lt_error);
            if (n42DiagReqId != 0) {
                lt_guest_result dres = LT_INIT(lt_guest_result);
                if (lt_runtime_guest_poll(runtime, n42DiagReqId, &dres, &derr) == LT_OK && dres.state != 1) {
                    uint64_t curFrames = __atomic_load_n(&vc->_lastFrameSeq, __ATOMIC_RELAXED);
                    NSLog(@"[EmulatorVC] N42 diag #%d: front(st=%u rc=%d out=%s) frames=%llu(+%llu)",
                          n42DiagCount + 1, dres.state, dres.guest_status, dres.output,
                          (unsigned long long)curFrames, (unsigned long long)(curFrames - n42PrevFrames));
                    n42PrevFrames = curFrames;
                    n42DiagReqId = 0;
                    n42DiagCount++;
                    if (dres.state == 2 && dres.guest_status == 0) {
                        n42DiagCount = 60;
                    } else {
                        n42DiagNextTime = CFAbsoluteTimeGetCurrent() + 30.0;
                    }
                }
            } else if (CFAbsoluteTimeGetCurrent() >= n42DiagNextTime) {
                uint32_t ast = 0;
                if (lt_runtime_guest_status(runtime, &ast, &derr) == LT_OK && ast == 1) {
                    lt_guest_request dreq = LT_INIT(lt_guest_request);
                    dreq.operation = LT_GUEST_FRONTMOST;
                    dreq.timeout_ms = 5000;
                    uint64_t rid = 0;
                    if (lt_runtime_guest_request(runtime, &dreq, &rid, &derr) == LT_OK) {
                        n42DiagReqId = rid;
                    } else {
                        n42DiagNextTime = CFAbsoluteTimeGetCurrent() + 10.0;
                    }
                }
            }
        }

        if (isN42PpnInitBoot) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastPpnProgressCheck >= 0.8) {
                lastPpnProgressCheck = now;
                int elapsedSec = MAX(0, (int)(now - ppnStartTime));
                NSString *slog = [NSString stringWithContentsOfFile:serialPath encoding:NSISOLatin1StringEncoding error:nil];
                if (slog.length > 0) {
                    NSRange panicRng = [slog rangeOfString:@"panic("];
                    NSRange kbFailRng = [slog rangeOfString:@"it_keybag: FAILED:"];
                    NSRange rsFailRng = [slog rangeOfString:@"A6RESTORE FAIL "];
                    NSUInteger failLoc = NSNotFound;
                    if (panicRng.location != NSNotFound) failLoc = panicRng.location;
                    else if (kbFailRng.location != NSNotFound) failLoc = kbFailRng.location;
                    else if (rsFailRng.location != NSNotFound) failLoc = rsFailRng.location;
                    if (failLoc != NSNotFound) {
                        NSString *tail = [slog substringFromIndex:failLoc];
                        NSString *firstLine = [[tail componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject] ?: @"";
                        NSLog(@"[EmulatorVC] N42 PPN init aborting on guest failure: %@", firstLine);
                        unexpectedErrorMsg = firstLine.length > 0
                            ? [NSString stringWithFormat:@"%@\n\n[%@]", L(@"n42_ppn_init_failed_msg"), firstLine]
                            : L(@"n42_ppn_init_failed_msg");
                        __atomic_store_n(&vc->_forceStopRequested, YES, __ATOMIC_RELEASE);
                        break;
                    }
                    float prog = 0.08f;
                    NSString *phaseText = [NSString stringWithFormat:L(@"n42_restore_env_starting"), elapsedSec];
                    if ([slog containsString:@"Starting VFL Format"] || [slog containsString:@"A6RESTORE WAITING_DISK"]) {
                        prog = 0.12f;
                        phaseText = [NSString stringWithFormat:L(@"n42_format_ppn_nand"), elapsedSec];
                    }
                    if ([slog containsString:@"FTL_Open"] || [slog containsString:@"Creating block device"]) {
                        prog = 0.16f;
                        phaseText = [NSString stringWithFormat:L(@"n42_build_ppn_partitions"), elapsedSec];
                    }
                    if ([slog containsString:@"A6RESTORE MEDIA"]) {
                        prog = 0.18f;
                        phaseText = [NSString stringWithFormat:L(@"n42_restore_sys_image_start"), elapsedSec];
                    }
                    NSRange lastProg = [slog rangeOfString:@"A6RESTORE PROGRESS " options:NSBackwardsSearch];
                    if (lastProg.location != NSNotFound) {
                        NSString *tail = [slog substringFromIndex:NSMaxRange(lastProg)];
                        unsigned int curRec = 0, totRec = 0;
                        unsigned long long writtenBytes = 0;
                        int matched = sscanf(tail.UTF8String, "%u/%u bytes=%llu", &curRec, &totRec, &writtenBytes);
                        if (matched >= 2 && totRec > 0) {
                            float frac = MIN(1.0f, (float)curRec / (float)totRec);
                            prog = 0.18f + 0.46f * frac;
                            int pctVal = (int)(frac * 100.0f);
                            if (matched >= 3 && writtenBytes > 0) {
                                phaseText = [NSString stringWithFormat:L(@"n42_restore_sys_image_progress_mb"),
                                             pctVal, (double)writtenBytes / 1048576.0, elapsedSec];
                            } else {
                                phaseText = [NSString stringWithFormat:L(@"n42_restore_sys_image_progress_chunks"),
                                             pctVal, curRec, totRec, elapsedSec];
                            }
                        } else {
                            prog = 0.38f;
                        }
                    }
                    if ([slog containsString:@"A6RESTORE DONE "]) {
                        prog = 0.66f;
                        phaseText = [NSString stringWithFormat:L(@"n42_data_area_prep"), elapsedSec];
                    }
                    if ([slog containsString:@"A6NATIVEFORMAT START"]) {
                        prog = 0.72f;
                        phaseText = [NSString stringWithFormat:L(@"n42_format_data_keybag"), elapsedSec];
                    }
                    if ([slog containsString:@"A6NATIVEFORMAT copying original Data seed"]) {
                        prog = 0.80f;
                        phaseText = [NSString stringWithFormat:L(@"n42_write_initial_seeds"), elapsedSec];
                    }
                    if ([slog containsString:@"A6NATIVEGESTALT starting worker"]) {
                        prog = 0.88f;
                        phaseText = [NSString stringWithFormat:L(@"n42_gen_gestalt_cache"), elapsedSec];
                    }
                    if ([slog containsString:@"A6NATIVEFORMAT both volumes unmounted cleanly"]) {
                        prog = 0.96f;
                        phaseText = [NSString stringWithFormat:L(@"n42_storage_verify_final"), elapsedSec];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!vc.ipaInstallInFlight && !vc.ipaProgressCard.hidden) {
                            vc.ipaProgressBar.progress = prog;
                            vc.ipaProgressLabel.text = phaseText;
                        }
                    });
                }
            }
        }

        // Drain queued audio packets (capacity requires >= 4096 stereo frames)
        BOOL drainedAudio = NO;
        for (int pkt = 0; pkt < 32; pkt++) {
            lt_pcm_info pcm_info = LT_INIT(lt_pcm_info);
            lt_status pst = lt_runtime_pcm(runtime, pcm_samples, 4096, &pcm_info, &err);
            if (pst != LT_OK) {
                break;
            }
            if (pcm_info.frames > 0) {
                drainedAudio = YES;
                if (pcm_info.sample_rate >= 8000 &&
                    ((uint32_t)vc.audioBridge.sampleRate != pcm_info.sample_rate ||
                     (pcm_info.channels > 0 && (uint32_t)vc.audioBridge.channels != pcm_info.channels))) {
                    [vc.audioBridge startPlaybackWithSampleRate:(double)pcm_info.sample_rate
                                                       channels:(pcm_info.channels > 0 ? (int)pcm_info.channels : 2)];
                }
                if (!loggedFirstPCM) {
                    loggedFirstPCM = YES;
                    NSLog(@"[EmulatorVC] First guest audio packet: %u frames @ %u Hz (%u ch)",
                          pcm_info.frames, pcm_info.sample_rate, pcm_info.channels);
                }
                [vc.audioBridge pushPCMData:pcm_samples count:pcm_info.frames];
            }
        }

        if (pollSt != LT_OK || rstat.state == LT_STOPPED || rstat.state == LT_FAILED) {
            NSLog(@"[EmulatorVC] Runtime stopped (pollSt=%d state=%u confirmed=%u msg=%s)",
                  pollSt, rstat.state, rstat.guest_shutdown_confirmed, pollErr.message);
            if (__atomic_load_n(&vc->_isEmulating, __ATOMIC_ACQUIRE) && !vc->_isStopping) {
                BOOL cleanShutdown = (pollSt == LT_OK && rstat.state == LT_STOPPED && rstat.guest_shutdown_confirmed && !pollErr.message[0]);
                if (cleanShutdown && isN42PpnInitBoot) {
                    NSString *slog = [NSString stringWithContentsOfFile:serialPath encoding:NSISOLatin1StringEncoding error:nil] ?: @"";
                    BOOL restoreDone = [slog containsString:@"A6RESTORE DONE "];
                    BOOL keybagDone = [slog containsString:@"it_keybag: effaceable formatted, system keybag created; halting"];
                    BOOL hasFailure = [slog containsString:@"it_keybag: FAILED:"] ||
                                      [slog containsString:@"A6RESTORE FAIL "] ||
                                      [slog containsString:@"panic("];
                    if (restoreDone && keybagDone && !hasFailure) {
                        n42PpnCompletedCleanly = YES;
                    } else {
                        unexpectedErrorMsg = L(@"n42_ppn_init_failed_msg");
                    }
                } else if (!cleanShutdown) {
                    if (pollErr.message[0]) {
                        unexpectedErrorMsg = [NSString stringWithUTF8String:pollErr.message];
                    } else {
                        unexpectedErrorMsg = L(@"vm_unexpected_stop_msg");
                    }
                }
            }
            break;
        }

        usleep(drainedAudio ? 1000 : 2500);
    }

cleanup:
    // 7. Cleanup
    NSLog(@"[EmulatorVC] Tearing down runtime...");
    emulator_set_direct_iosurface_cb(NULL, NULL);
    lt_runtime_set_frame_pixel_listener(runtime, NULL, NULL, &err);
    lt_runtime_set_frame_listener(runtime, NULL, NULL, &err);
    lt_runtime_request_shutdown(runtime, &err);
    lt_runtime_status rstat_stop = LT_INIT(lt_runtime_status);
    const int max_wait_ticks = (int)((LT_SHUTDOWN_GRACE_MS + LT_SHUTDOWN_AGENT_WAIT_MS + 2000u) / 10u);
    for (int wait_i = 0; wait_i < max_wait_ticks; wait_i++) {
        if (__atomic_load_n(&vc->_forceStopRequested, __ATOMIC_ACQUIRE)) {
            NSLog(@"[EmulatorVC] Force stop requested during shutdown wait.");
            break;
        }
        lt_runtime_poll(runtime, &rstat_stop, &err);
        if (rstat_stop.state == LT_STOPPED || rstat_stop.state == LT_FAILED) {
            break;
        }
        usleep(10000);
    }
    vc->_runtime = NULL;
    vc->_device = NULL;
    if (rstat_stop.state == LT_STOPPED || rstat_stop.state == LT_FAILED) {
        lt_runtime_destroy(runtime, &err);
        lt_device_close(device);
        if (n42PpnCompletedCleanly) {
            [@"1\n" writeToFile:ppnMarkerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[EmulatorVC] iPhone 5 PPN NAND initialization marked complete at %@", ppnMarkerPath);
        }
    } else {
        NSLog(@"[EmulatorVC] Runtime did not stop cleanly; skipping destroy to avoid busy-free crash.");
    }
    [networkProxy stop];
    vc.usbBridge = nil;
    [usbBridge stop];
    unsetenv("IT_USB_TCP");

    if (n42PpnCompletedCleanly) {
        emulator_finish_thread_ui(vc, nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!vc.ipaInstallInFlight) {
                vc.ipaProgressCard.hidden = YES;
            }
            if (!vc.isBeingDismissed) {
                UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:L(@"n42_ppn_init_done_title")
                                                                                   message:L(@"n42_ppn_init_done_msg")
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                [doneAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    if (vc.presentingViewController) {
                        [vc.presentingViewController dismissViewControllerAnimated:YES completion:nil];
                    } else {
                        [vc dismissViewControllerAnimated:YES completion:nil];
                    }
                }]];
                [vc presentViewController:doneAlert animated:YES completion:nil];
            }
        });
    } else {
        if (isN42PpnInitBoot) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!vc.ipaInstallInFlight) {
                    vc.ipaProgressCard.hidden = YES;
                }
            });
        }
        emulator_finish_thread_ui(vc, unexpectedErrorMsg);
    }

    NSLog(@"[EmulatorVC] Emulator thread exited cleanly.");
    return NULL;
}

- (void)startEmulation {
    if (_isEmulating) return;

    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *logPath = [docDir stringByAppendingPathComponent:@"last_boot.log"];
    NSString *flagPath = [docDir stringByAppendingPathComponent:@"boot_in_progress.flag"];
    [@"1" writeToFile:flagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    freopen([logPath UTF8String], "w", stderr);
    setvbuf(stderr, NULL, _IOLBF, 4096);
    fprintf(stderr, "[EmulatorVC] Booting %s (base=%s state=%s)\n",
            [self.machineName UTF8String] ?: "",
            [self.baseDirPath UTF8String] ?: "",
            [self.stateDirPath UTF8String] ?: "");
    {
        NSString *lockPath = [self.baseDirPath stringByAppendingPathComponent:@"device.lock.json"];
        NSData *lockData = [NSData dataWithContentsOfFile:lockPath];
        NSDictionary *lockJson = lockData ? [NSJSONSerialization JSONObjectWithData:lockData options:0 error:nil] : nil;
        NSString *kbRestPath = [self.baseDirPath stringByAppendingPathComponent:@"kboot-restore.bin"];
        NSDictionary *kbAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kbRestPath error:nil];
        id restoreDiag = [lockJson isKindOfClass:[NSDictionary class]] ? lockJson[@"restore_diag"] : nil;
        id actDiag = [lockJson isKindOfClass:[NSDictionary class]] ? lockJson[@"activation"] : nil;
        id kbootRestoreOut = ([lockJson isKindOfClass:[NSDictionary class]] && [lockJson[@"outputs"] isKindOfClass:[NSDictionary class]]) ? lockJson[@"outputs"][@"kboot_restore"] : nil;
        fprintf(stderr, "[EmulatorVC] Lock prep_v12=%d build=%s kboot-restore=%llu lock_out=%s activation=%s restore_diag=%s\n",
                [lockJson isKindOfClass:[NSDictionary class]] ? [lockJson[@"prep_v12"] boolValue] : 0,
                [lockJson isKindOfClass:[NSDictionary class]] ? ([lockJson[@"build"] description].UTF8String ?: "") : "",
                (unsigned long long)[kbAttrs fileSize],
                kbootRestoreOut ? [[kbootRestoreOut description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String : "null",
                actDiag ? [[actDiag description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String : "null",
                restoreDiag ? [[restoreDiag description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String : "null");
    }

    __atomic_store_n(&_forceStopRequested, NO, __ATOMIC_RELEASE);
    __atomic_store_n(&_threadExited, NO, __ATOMIC_RELEASE);
    __atomic_store_n(&_isEmulating, YES, __ATOMIC_RELEASE);
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = YES;
    });

    // Start AudioUnit off main thread AFTER _isEmulating = YES so it never races out early.
    IOSAudioBridge *audio = self.audioBridge ?: [IOSAudioBridge sharedBridge];
    self.audioBridge = audio;
    __weak typeof(self) audioWeakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(audioWeakSelf) s = audioWeakSelf;
        if (!s || !__atomic_load_n(&s->_isEmulating, __ATOMIC_ACQUIRE)) return;
        [audio startPlaybackWithSampleRate:44100 channels:2];
    });

    void *ctx = (__bridge_retained void *)self;
    pthread_attr_t emuAttr;
    pthread_attr_init(&emuAttr);
    pthread_attr_set_qos_class_np(&emuAttr, QOS_CLASS_USER_INTERACTIVE, 0);
    int createRc = pthread_create(&_emulatorThread, &emuAttr, emulator_worker_thread, ctx);
    pthread_attr_destroy(&emuAttr);
    if (createRc == 0) {
        pthread_detach(_emulatorThread);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startClipboardSyncTimer];
        });
    } else {
        CFBridgingRelease(ctx);
        __atomic_store_n(&_isEmulating, NO, __ATOMIC_RELEASE);
        __atomic_store_n(&_threadExited, YES, __ATOMIC_RELEASE);
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].idleTimerDisabled = NO;
        });
        [[NSFileManager defaultManager] removeItemAtPath:flagPath error:nil];
    }
}

- (void)stopEmulation {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        if (self->_isWinRTMode) {
            [self releaseWinRTStickyModifiers];
            [self.winrtKeyInputView resignFirstResponder];
        }
    });
    if (!__atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) return;
    __atomic_store_n(&_isEmulating, NO, __ATOMIC_RELEASE);
    if (_isWinRTMode && _pfnWinrtQuit) {
        _pfnWinrtQuit();
    }
    if (_isAndroidMode && _pfnAndroidQuit) {
        _pfnAndroidQuit();
    }
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *flagPath = [docDir stringByAppendingPathComponent:@"boot_in_progress.flag"];
    [[NSFileManager defaultManager] removeItemAtPath:flagPath error:nil];
    [self.audioBridge stop];
    [self.motionManager stopMonitoring];
    [self.telemetryTimer invalidate];
    self.telemetryTimer = nil;
    [self stopClipboardSyncTimer];
}

- (void)setQemuGlesAllowed:(BOOL)allowed {
    typedef void (*gles_set_allowed_fn)(bool);
    static gles_set_allowed_fn fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fn = (gles_set_allowed_fn)dlsym(RTLD_DEFAULT, "qemu_ios_gles_set_allowed");
    });
    if (fn) {
        fn(allowed ? true : false);
    }
}

- (void)handleAppWillResignActive:(NSNotification *)note {
    self.metalView.paused = YES;
}

- (void)handleAppDidEnterBackground:(NSNotification *)note {
    [self setQemuGlesAllowed:NO];
    self.metalView.paused = YES;
    if (_isWinRTMode) {
        [self releaseWinRTStickyModifiers];
        [self.winrtKeyInputView resignFirstResponder];
        if (_pfnWinrtSync && __atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) {
            _pfnWinrtSync();
        }
    }
    if (_isAndroidMode && _pfnAndroidSync && __atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) {
        _pfnAndroidSync();
    }
    lt_runtime *rt = __atomic_load_n(&_runtime, __ATOMIC_ACQUIRE);
    if (rt && __atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_pause(rt, 1, &err);
    }
    [self.audioBridge stop];
}

- (void)handleAppDidBecomeActive:(NSNotification *)note {
    [self setQemuGlesAllowed:YES];
    self.metalView.paused = NO;
    [self.metalView setNeedsDisplay];
    lt_runtime *rt = __atomic_load_n(&_runtime, __ATOMIC_ACQUIRE);
    if (rt && __atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) {
        [UIApplication sharedApplication].idleTimerDisabled = YES;
        lt_error err = LT_INIT(lt_error);
        lt_runtime_pause(rt, 0, &err);
        IOSAudioBridge *audio = self.audioBridge;
        if (audio) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [audio startPlaybackWithSampleRate:44100 channels:2];
            });
        }
    } else if ((_isAndroidMode || (_isWinRTMode && self.winrtEnableAudio)) &&
               __atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) {
        [UIApplication sharedApplication].idleTimerDisabled = YES;
        IOSAudioBridge *audio = self.audioBridge;
        if (audio) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [audio startPlaybackWithSampleRate:44100 channels:2];
            });
        }
    }
    if (self.clipboardSyncEnabled) {
        [self checkHostPasteboardForSync];
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [self.metalView purgeTextureCaches];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isBeingDismissed || self.isMovingFromParentViewController) {
        [self stopEmulation];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopEmulation];
}

@end

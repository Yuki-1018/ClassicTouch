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
#import "ios_audio_bridge.h"
#import "ios_motion_manager.h"
#import "ios_jit_helper.h"
#import "ios_bootrom_helper.h"
#import "ios_network_proxy.h"
#import "ios_usb_mux.h"
#import "ios_ipa_installer.h"
#import "ios_guest_tools.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
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

    double _accelX, _accelY, _accelZ;
    double _gyroX, _gyroY, _gyroZ;
    double _lastSentAccelX, _lastSentAccelY, _lastSentAccelZ;
    double _lastSentGyroX, _lastSentGyroY, _lastSentGyroZ;
    BOOL _hasSentMotion;
    uint64_t _lastMotionNs;
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

@property (nonatomic, strong) IOSMetalView *metalView;
@property (nonatomic, strong) UIView *zoomIndicatorBar;
@property (nonatomic, strong) IOSAudioBridge *audioBridge;
@property (nonatomic, strong) IOSMotionManager *motionManager;
@property (nonatomic, strong) UIVisualEffectView *telemetryCard;
@property (nonatomic, strong) UILabel *telemetryLabel;
@property (nonatomic, strong) UIView *hardwareBar;
@property (nonatomic, strong) UIVisualEffectView *barBlurView;
@property (nonatomic, strong) UIButton *homeButton;
@property (nonatomic, strong) UIButton *powerButton;
@property (nonatomic, strong) UIButton *volUpButton;
@property (nonatomic, strong) UIButton *volDownButton;
@property (nonatomic, strong) UIButton *moreMenuButton;
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
    } else if ([boardStr isEqualToString:@"n72ap"]) {
        candidates = @[@"bootrom_240_4", @"bootrom_240_4.bin", @"bootrom.bin"];
        romType = @"s5l8720";
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

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
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
    if (!text.length) return;
    typedef void (*qemu_ios_ui_paste_fn)(const char *utf8);
    static qemu_ios_ui_paste_fn pasteFn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pasteFn = (qemu_ios_ui_paste_fn)dlsym(RTLD_DEFAULT, "qemu_ios_ui_paste");
    });
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
    typedef char *(*qemu_ios_ui_guest_pasteboard_fn)(uint64_t *serial);
    static qemu_ios_ui_guest_pasteboard_fn guestPbFn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        guestPbFn = (qemu_ios_ui_guest_pasteboard_fn)dlsym(RTLD_DEFAULT, "qemu_ios_ui_guest_pasteboard");
    });
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
    __atomic_store_n(&_hostInterfaceOrientation, (NSInteger)ori, __ATOMIC_RELEASE);

    BOOL isPad = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
    BOOL guestLandscape = (self.screenWidth > self.screenHeight);
    BOOL hostLandscape = (self.view.bounds.size.width > self.view.bounds.size.height);

    NSInteger rot = 0;
    if (guestLandscape) {
        // Landscape-native guest framebuffers (e.g. iPad 1st gen 1024x768)
        rot = hostLandscape ? 0 : 90;
    } else {
        // iPhone / iPod guests:
        // By default, kept upright (0 deg) even on a Landscape iPad to prevent accidental rotation.
        // If the user explicitly enabled iPad landscape rotation, rotate to match iPad orientation.
        if (isPad && self.iPadLandscapeRotationEnabled && hostLandscape) {
            if (ori == UIInterfaceOrientationLandscapeLeft) {
                rot = 270;
            } else {
                rot = 90;
            }
        } else {
            rot = 0;
        }
    }
    self.metalView.displayRotationDegrees = rot;
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
    if (!_runtime || !_isEmulating) return;

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

    // Metal rendering view
    self.metalView = [[IOSMetalView alloc] initWithFrame:self.view.bounds];
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

    // 1. 通知センターを開く（ホスト iPadOS と競合せず確実に開く）
    UIAction *notifAct = [UIAction actionWithTitle:L(@"menu_pull_notif")
                                             image:[UIImage systemImageNamed:@"bell.badge"]
                                        identifier:nil
                                           handler:^(__kindof UIAction *action) {
        [weakSelf pullNotificationCenter];
    }];
    [displayActions addObject:notifAct];

    // 2. コントロールセンターを開く（ホストのホームバー/Dockと競合せず確実に開く）
    UIAction *ccAct = [UIAction actionWithTitle:L(@"menu_pull_control_center")
                                          image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                     identifier:nil
                                        handler:^(__kindof UIAction *action) {
        [weakSelf pullControlCenter];
    }];
    [displayActions addObject:ccAct];

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
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
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

    UIMenu *toolsMenu = [UIMenu menuWithTitle:@""
                                        image:nil
                                   identifier:nil
                                      options:UIMenuOptionsDisplayInline
                                     children:@[clipSyncAct, pasteToGuestAct, hudAct, installIpaAct]];

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
                                     children:@[restartAct, exitAct]];

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

    self.homeButton = [self createCompactHardwareButton:@"circle.inset.filled" title:L(@"menu_btn_home") minWidth:0.0 action:@selector(homeButtonDown:) upAction:@selector(homeButtonUp:)];
    [self.homeButton removeTarget:self action:@selector(homeButtonUp:) forControlEvents:UIControlEventTouchCancel];
    [self.homeButton addTarget:self action:@selector(homeButtonCancel:) forControlEvents:UIControlEventTouchCancel];
    self.powerButton = [self createCompactHardwareButton:@"power" title:L(@"menu_btn_power") minWidth:0.0 action:@selector(powerButtonDown:) upAction:@selector(powerButtonUp:)];
    self.volDownButton = [self createCompactHardwareButton:@"speaker.minus.fill" title:nil minWidth:28.0 action:@selector(volDownButtonDown:) upAction:@selector(volDownButtonUp:)];
    self.volUpButton = [self createCompactHardwareButton:@"speaker.plus.fill" title:nil minWidth:28.0 action:@selector(volUpButtonDown:) upAction:@selector(volUpButtonUp:)];

    self.moreMenuButton = [self createCompactHardwareButton:@"ellipsis.circle" title:L(@"menu_btn_more") minWidth:0.0 action:nil upAction:nil];
    self.moreMenuButton.showsMenuAsPrimaryAction = YES;
    self.moreMenuButton.accessibilityLabel = L(@"menu_btn_more");
    [self refreshMoreMenu];

    self.hardwareStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.collapseButton,
        self.homeButton,
        self.powerButton,
        self.volDownButton,
        self.volUpButton,
        self.moreMenuButton
    ]];
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
    NSArray *items = @[self.homeButton, self.powerButton, self.volDownButton, self.volUpButton, self.moreMenuButton];
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
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 0, 0, &err);
    }
}

- (void)powerButtonDown:(id)sender {
    [_haptic impactOccurred];
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 1, 1, &err);
    }
}

- (void)powerButtonUp:(id)sender {
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 1, 0, &err);
    }
}

- (void)volUpButtonDown:(id)sender {
    [_haptic impactOccurred];
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 2, 1, &err);
    }
}

- (void)volUpButtonUp:(id)sender {
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 2, 0, &err);
    }
}

- (void)volDownButtonDown:(id)sender {
    [_haptic impactOccurred];
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 3, 1, &err);
    }
}

- (void)volDownButtonUp:(id)sender {
    if (_runtime) {
        lt_error err = LT_INIT(lt_error);
        lt_runtime_button(_runtime, 3, 0, &err);
    }
}

#pragma mark - Touch Dispatch

- (void)handleTouchId:(int)touchId phase:(int)phase x:(float)x y:(float)y {
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
    if (!__atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE) || !_runtime) return;
    if (!__atomic_load_n(&_boardSupportsAccel, __ATOMIC_ACQUIRE)) return;

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
    } else {
        // iPhone、または iPad で横画面回転が有効の場合:
        // ホスト端末の向きをそのまま仮想マシンに反映する！
        if (hostOri == UIInterfaceOrientationLandscapeLeft) {
            // ホストが LandscapeLeft:
            // 物理センサーの水平加速度が弱い（平置き・微傾斜など）場合でも確実に LandscapeLeft を維持
            if (fabs(rawAx) < 4.0 && fabs(rawAy) < 4.0) {
                ax = -9.80665;
                ay = 0.0;
            }
        } else if (hostOri == UIInterfaceOrientationLandscapeRight) {
            // ホストが LandscapeRight:
            if (fabs(rawAx) < 4.0 && fabs(rawAy) < 4.0) {
                ax = 9.80665;
                ay = 0.0;
            }
        } else if (hostOri == UIInterfaceOrientationPortraitUpsideDown) {
            if (fabs(rawAx) < 4.0 && fabs(rawAy) < 4.0) {
                ax = 0.0;
                ay = -9.80665;
            }
        } else {
            // Portrait
            if (fabs(rawAx) < 4.0 && fabs(rawAy) < 4.0) {
                ax = 0.0;
                ay = 9.80665;
            }
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
    [vc.metalView updateFrameIOSurface:iosurface_ref width:w height:h];
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

static void *emulator_worker_thread(void *arg) {
    // Keep supervisor slightly below QEMU vCPU USER_INTERACTIVE so A11 dual P-cores prioritize TCG execution.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    EmulatorViewController *vc = (__bridge_transfer EmulatorViewController *)arg;
    NSLog(@"[EmulatorVC] Starting emulator worker for %@", vc.machineId);

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
        id kbootRestoreOut = ([lockJson isKindOfClass:[NSDictionary class]] && [lockJson[@"outputs"] isKindOfClass:[NSDictionary class]]) ? lockJson[@"outputs"][@"kboot_restore"] : nil;
        fprintf(stderr, "[EmulatorVC] Lock prep_v12=%d build=%s kboot-restore=%llu lock_out=%s restore_diag=%s\n",
                [lockJson isKindOfClass:[NSDictionary class]] ? [lockJson[@"prep_v12"] boolValue] : 0,
                [lockJson isKindOfClass:[NSDictionary class]] ? ([lockJson[@"build"] description].UTF8String ?: "") : "",
                (unsigned long long)[kbAttrs fileSize],
                kbootRestoreOut ? [[kbootRestoreOut description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String : "null",
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
    });
    if (!__atomic_load_n(&_isEmulating, __ATOMIC_ACQUIRE)) return;
    __atomic_store_n(&_isEmulating, NO, __ATOMIC_RELEASE);
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

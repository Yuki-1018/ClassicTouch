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

#import "MainViewController.h"
#import "SettingsViewController.h"
#import "EmulatorViewController.h"
#import "IPSWDownloader.h"
#import "ios_jit_helper.h"
#import "ios_bootrom_helper.h"
#import "ios_guest_tools.h"
#import "ios_winrt_media_probe.h"
#import "ios_winrt_qcow2.h"
#include <sys/stat.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define L(key) NSLocalizedString((key), nil)

static void ClassicWinRTQcow2ProgressTrampoline(double frac, void *ctx) {
    UIAlertController *prog = (__bridge UIAlertController *)ctx;
    if (!prog) return;
    int pct = (int)llround(frac * 100.0);
    dispatch_async(dispatch_get_main_queue(), ^{
        prog.message = [NSString stringWithFormat:@"未使用領域を削減しています（%d%%）", pct];
    });
}

static BOOL ClassicCreateWinRTQcow2DiskImage(NSString *path, uint64_t sizeBytes, NSError **outError) {
    int rc = winrt_qcow2_create_blank([path fileSystemRepresentation], sizeBytes);
    if (rc != 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:-rc userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed creating QCOW2 disk (%s)", strerror(-rc)]
            }];
        }
        return NO;
    }
    return YES;
}

static BOOL ClassicCreateSparseDiskImage(NSString *path, uint64_t sizeBytes, NSError **outError) {
    if (path.length == 0 || sizeBytes < (1ULL << 20)) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"ClassicTouch" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid disk path or size"}];
        }
        return NO;
    }
    int fd = open([path fileSystemRepresentation], O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return NO;
    }
    if (ftruncate(fd, (off_t)sizeBytes) != 0) {
        int savedErr = errno;
        close(fd);
        unlink([path fileSystemRepresentation]);
        if (outError) {
            *outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErr userInfo:nil];
        }
        return NO;
    }
    close(fd);
    return YES;
}

// Firmwarekit C FFI declarations
typedef void (*firmware_progress_cb)(int percent, const char *step_name);
extern int lighttouch_firmware_create(
    const char *catalog_path,
    const char *entry_id,
    const char *ipsw_path,
    const char *guest_tools_path,
    const char *out_dir,
    firmware_progress_cb progress_cb
);
extern int lighttouch_firmware_create_with_options(
    const char *catalog_path,
    const char *entry_id,
    const char *ipsw_path,
    const char *guest_tools_path,
    const char *out_dir,
    int jailbreak,
    firmware_progress_cb progress_cb
);
extern int lighttouch_android_prepare(
    const char *zip_path,
    const char *out_dir,
    firmware_progress_cb progress_cb
);
extern int lighttouch_android_prepare_custom(
    const char *zip_path,
    const char *base_zip_path,
    const char *out_dir,
    firmware_progress_cb progress_cb
);
extern char *lighttouch_ipsw_inspect(const char *ipsw_path);
extern char *lighttouch_android_inspect_zip(const char *zip_path);
extern int lighttouch_firefoxos_prepare(
    const char *gonk_zip_path,
    const char *b2g_tar_gz_path,
    const char *gaia_zip_path,
    const char *out_dir,
    firmware_progress_cb progress_cb
);
extern int lighttouch_extract_zip_image(const char *zip_path, const char *out_path);
extern int lighttouch_prepare_ubuntutouch_virt(const char *rootfs_tar_gz,
                                               const char *overlay_debs_dir,
                                               const char *ut_version,
                                               const char *out_dir,
                                               firmware_progress_cb progress_cb);
extern const char *lighttouch_firmware_last_error(void);
extern void lighttouch_firmware_free_string(char *s);

static UIViewController *TopPresentedViewController(UIViewController *root) {
    UIViewController *curr = root;
    while (curr.presentedViewController) {
        curr = curr.presentedViewController;
    }
    return curr;
}

#pragma mark - Models

@interface VMContainer : NSObject
@property (nonatomic, copy) NSString *containerId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *baseId;
@property (nonatomic, copy) NSString *productType;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *build;
@property (nonatomic, copy) NSString *platform;
@property (nonatomic, assign) NSInteger ramMB;
@property (nonatomic, assign) NSInteger lcdDensity;
@property (nonatomic, assign) NSInteger gpuMode;
@property (nonatomic, copy, nullable) NSString *winrtDiskPath;
@property (nonatomic, copy, nullable) NSString *winrtIsoPath;
@property (nonatomic, assign) BOOL winrtBootFromIso;
@property (nonatomic, copy, nullable) NSString *winrtRtcDate;
@property (nonatomic, assign) BOOL winrtEnableNet;
@property (nonatomic, assign) BOOL winrtEnableAudio;
@property (nonatomic, assign) NSTimeInterval createdAt;

- (NSString *)containerPathWithRoot:(NSString *)containersRoot;
- (NSString *)statePathWithRoot:(NSString *)containersRoot;
- (NSString *)basePathWithRoot:(NSString *)basesRoot;
- (int64_t)stateDiskUsageWithRoot:(NSString *)containersRoot;
- (BOOL)saveMetadataWithRoot:(NSString *)containersRoot;
+ (nullable instancetype)loadFromDirectory:(NSString *)dirPath;
@end

@implementation VMContainer

- (NSString *)containerPathWithRoot:(NSString *)containersRoot {
    return [containersRoot stringByAppendingPathComponent:self.containerId];
}

- (NSString *)statePathWithRoot:(NSString *)containersRoot {
    return [[self containerPathWithRoot:containersRoot] stringByAppendingPathComponent:@"state"];
}

- (NSString *)basePathWithRoot:(NSString *)basesRoot {
    return [basesRoot stringByAppendingPathComponent:self.baseId];
}

- (int64_t)stateDiskUsageWithRoot:(NSString *)containersRoot {
    NSString *stPath = [self statePathWithRoot:containersRoot];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:stPath]) return 0;

    int64_t total = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:stPath];
    for (NSString *sub in enumerator) {
        NSString *full = [stPath stringByAppendingPathComponent:sub];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        total += attrs.fileSize;
    }
    return total;
}

- (BOOL)saveMetadataWithRoot:(NSString *)containersRoot {
    NSString *cDir = [self containerPathWithRoot:containersRoot];
    [[NSFileManager defaultManager] createDirectoryAtPath:cDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *jsonPath = [cDir stringByAppendingPathComponent:@"container.json"];

    NSMutableDictionary *dict = [@{
        @"id": self.containerId ?: @"",
        @"name": self.name ?: @"",
        @"baseId": self.baseId ?: @"",
        @"productType": self.productType ?: @"",
        @"version": self.version ?: @"",
        @"build": self.build ?: @"",
        @"platform": self.platform.length > 0 ? self.platform : @"ios",
        @"createdAt": @(self.createdAt)
    } mutableCopy];
    if ([self.platform isEqualToString:@"android"] || [self.baseId hasPrefix:@"android-"] ||
        [self.platform isEqualToString:@"firefoxos"] || [self.baseId hasPrefix:@"fxos-"]) {
        if (self.ramMB > 0) dict[@"ramMB"] = @(self.ramMB);
        if (self.lcdDensity > 0) dict[@"lcdDensity"] = @(self.lcdDensity);
        if (self.gpuMode != 0) dict[@"gpuMode"] = @(self.gpuMode);
    } else if ([self.platform isEqualToString:@"winrt"] || [self.baseId hasPrefix:@"winrt-"] ||
               [self.platform isEqualToString:@"chromeos"] || [self.baseId hasPrefix:@"chromeos-"] ||
               [self.platform isEqualToString:@"ubuntutouch"] || [self.baseId hasPrefix:@"ut-virt-"]) {
        if (self.ramMB > 0) dict[@"ramMB"] = @(self.ramMB);
        if (self.winrtDiskPath.length > 0) dict[@"winrtDiskPath"] = self.winrtDiskPath;
        if (self.winrtIsoPath.length > 0) dict[@"winrtIsoPath"] = self.winrtIsoPath;
        dict[@"winrtBootFromIso"] = @(self.winrtBootFromIso);
        if (self.winrtRtcDate.length > 0) dict[@"winrtRtcDate"] = self.winrtRtcDate;
        dict[@"winrtEnableNet"] = @(self.winrtEnableNet);
        dict[@"winrtEnableAudio"] = @(self.winrtEnableAudio);
    }

    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&err];
    if (data && !err) {
        return [data writeToFile:jsonPath atomically:YES];
    }
    return NO;
}

+ (nullable instancetype)loadFromDirectory:(NSString *)dirPath {
    NSString *jsonPath = [dirPath stringByAppendingPathComponent:@"container.json"];
    NSData *data = [NSData dataWithContentsOfFile:jsonPath];
    if (!data) return nil;

    NSError *err = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!dict || ![dict isKindOfClass:[NSDictionary class]]) return nil;

    VMContainer *c = [[VMContainer alloc] init];
    c.containerId = dict[@"id"] ?: dirPath.lastPathComponent;
    c.name = dict[@"name"] ?: c.containerId;
    c.baseId = dict[@"baseId"] ?: c.containerId;
    c.productType = dict[@"productType"] ?: @"";
    c.version = dict[@"version"] ?: @"";
    c.build = dict[@"build"] ?: @"";
    c.platform = dict[@"platform"] ?: ([c.baseId hasPrefix:@"winrt-"] ? @"winrt" : ([c.baseId hasPrefix:@"chromeos-"] ? @"chromeos" : ([c.baseId hasPrefix:@"ut-virt-"] ? @"ubuntutouch" : ([c.baseId hasPrefix:@"fxos-"] ? @"firefoxos" : ([c.baseId hasPrefix:@"android-"] ? @"android" : @"ios")))));
    c.ramMB = [dict[@"ramMB"] integerValue];
    c.lcdDensity = [dict[@"lcdDensity"] integerValue];
    c.gpuMode = [dict[@"gpuMode"] integerValue];
    c.winrtDiskPath = [dict[@"winrtDiskPath"] isKindOfClass:[NSString class]] ? dict[@"winrtDiskPath"] : nil;
    c.winrtIsoPath = [dict[@"winrtIsoPath"] isKindOfClass:[NSString class]] ? dict[@"winrtIsoPath"] : nil;
    c.winrtBootFromIso = [dict[@"winrtBootFromIso"] boolValue];
    c.winrtRtcDate = [dict[@"winrtRtcDate"] isKindOfClass:[NSString class]] ? dict[@"winrtRtcDate"] : @"2013-07-15";
    c.winrtEnableNet = dict[@"winrtEnableNet"] ? [dict[@"winrtEnableNet"] boolValue] : YES;
    c.winrtEnableAudio = dict[@"winrtEnableAudio"] ? [dict[@"winrtEnableAudio"] boolValue] : YES;
    c.createdAt = [dict[@"createdAt"] doubleValue];
    return c;
}

@end

@interface CatalogEntry : NSObject
@property (nonatomic, copy) NSString *entryId;
@property (nonatomic, copy) NSString *board;
@property (nonatomic, copy) NSString *productType;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *build;
@property (nonatomic, copy) NSString *platform;
@property (nonatomic, copy) NSString *variant;
@property (nonatomic, copy) NSString *cpu;
@property (nonatomic, copy) NSString *cmdline;
@property (nonatomic, assign) int ramMB;
@property (nonatomic, assign) int smp;
@property (nonatomic, assign) int apiLevel;
@property (nonatomic, assign) int lcdWidth;
@property (nonatomic, assign) int lcdHeight;
@property (nonatomic, assign) int lcdDensity;
@property (nonatomic, assign) int64_t rtcEpoch;
@property (nonatomic, assign) int diskGB;
@property (nonatomic, copy) NSString *rtcDate;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *fallbackUrl;
@property (nonatomic, copy) NSString *sha1;
@property (nonatomic, assign) int64_t bytes;
@property (nonatomic, assign) int64_t b2gBytes;
@property (nonatomic, copy) NSString *gaiaUrl;
@property (nonatomic, copy) NSString *gaiaSha1;
@property (nonatomic, assign) int64_t gaiaBytes;
@property (nonatomic, copy) NSString *gonkUrl;
@property (nonatomic, copy) NSString *gonkSha1;
@property (nonatomic, assign) int64_t gonkBytes;
@property (nonatomic, copy, nullable) NSArray<NSString *> *overlayUrls;
@property (nonatomic, assign) int64_t overlayBytes;
@end

@implementation CatalogEntry
@end

@interface FirmwareFile : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *entryId;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *build;
@property (nonatomic, copy) NSString *productType;
@property (nonatomic, copy) NSString *platform;
@property (nonatomic, assign) int64_t fileSizeBytes;
@end

@implementation FirmwareFile
@end

#pragma mark - MainViewController Implementation

@interface MainViewController () {
    UIImpactFeedbackGenerator *_haptic;
    UINotificationFeedbackGenerator *_notifyHaptic;
}

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<VMContainer *> *containers;
@property (nonatomic, strong) NSArray<CatalogEntry *> *catalogEntries;

// Progress UI overlay
@property (nonatomic, strong) UIVisualEffectView *progressOverlay;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UILabel *progressTitleLabel;
@property (nonatomic, strong) UILabel *progressDetailLabel;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, copy, nullable) NSDictionary *deferredBackgroundDownloadResult;
@property (nonatomic, assign) BOOL isPickingBootrom;
@property (nonatomic, assign) BOOL isImportingIPSWForManagement;
@property (nonatomic, strong) UIBarButtonItem *romBtn;
@property (nonatomic, strong) UIButton *romNavButton;
@property (nonatomic, strong) UIBarButtonItem *firmwareBtn;

// Pending installation state for Wizard flow
@property (nonatomic, strong) CatalogEntry *pendingEntry;
@property (nonatomic, copy) NSString *pendingContainerName;
@property (nonatomic, weak) EmulatorViewController *activeEmulatorVC;
@property (nonatomic, assign) BOOL hasConsumedEngineProcess;
@property (nonatomic, assign) BOOL isCheckingJit;
@property (nonatomic, assign) BOOL isPreparingBase;
@property (nonatomic, assign) BOOL isDownloadingOverlays;
@property (nonatomic, assign) NSUInteger progressToken;
@property (nonatomic, strong) dispatch_queue_t startupQueue;
@property (nonatomic, assign) BOOL hasCompletedInitialLoad;
@property (nonatomic, assign) BOOL isCatalogLoading;
@property (nonatomic, assign) BOOL isCatalogLoaded;
@property (nonatomic, strong) NSMutableArray<void(^)(void)> *catalogWaiters;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *cachedBootromPaths;
@property (nonatomic, assign) BOOL hasLoadedBootromCache;
@property (nonatomic, strong, nullable) UIView *emptyStateView;

@end

@interface MainViewController (DetailSupport)
- (NSString *)humanReadableNameForId:(NSString *)sub;
- (NSString *)formattedOSVersion:(NSString *)version;
- (NSString *)formattedOSVersion:(NSString *)version forPlatform:(nullable NSString *)platform;
- (nullable NSString *)requiredBootromTypeForIdentifier:(NSString *)identifier;
- (BOOL)hasInstalledBootromForIdentifier:(NSString *)identifier;
- (nullable NSString *)pathForInstalledBootromType:(NSString *)romType;
- (BOOL)hasInstalledBootrom;
- (void)invalidateBootromCache;
- (NSString *)appDocumentsPath;
- (NSString *)containersDirectory;
- (NSString *)firmwaresDirectory;
- (NSString *)legacyIPSWDirectory;
- (nullable NSString *)findExistingIPSWForEntryId:(NSString *)entryId;
- (nullable CatalogEntry *)catalogEntryWithId:(NSString *)entryId;
- (void)downloadChromeOSImageForContainer:(VMContainer *)container
                                    entry:(CatalogEntry *)entry
                       fromViewController:(UIViewController *)presenter
                               completion:(void (^ _Nullable)(BOOL ok))completion;
- (int64_t)remainingDownloadBytesForEntry:(CatalogEntry *)ce;
- (BOOL)hasPreparedBaseForEntryId:(NSString *)entryId;
- (void)bootContainer:(VMContainer *)container;
- (void)confirmDeleteContainer:(VMContainer *)container indexPath:(NSIndexPath *)indexPath;
- (void)handleImportedBootrom:(NSURL *)url;
- (void)updateRomButtonState;
- (NSArray<FirmwareFile *> *)scanDownloadedFirmwares;
- (NSArray<VMContainer *> *)containersUsingEntryId:(NSString *)entryId;
- (void)showDocumentPickerForIPSW;
- (void)showDocumentPickerForIPSWForManagement:(BOOL)managementOnly;
- (void)downloadCatalogIPSWForManagement:(CatalogEntry *)entry;
- (void)promptFirmwareManagement:(id)sender;
- (void)promptContainerNameForEntry:(CatalogEntry *)entry deviceTitle:(NSString *)deviceTitle;
- (void)handleImportedIPSWFromURL:(NSURL *)url presentingViewController:(nullable UIViewController *)presenter completion:(nullable void(^)(void))completion;
@property (nonatomic, strong) NSArray<CatalogEntry *> *catalogEntries;
@end

@interface ContainerDetailViewController : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) VMContainer *container;
@property (nonatomic, weak) MainViewController *mainVC;
@property (nonatomic, assign) NSInteger containerIndex;
@property (nonatomic, copy) NSString *cachedDiskUsageText;
@property (nonatomic, assign) NSInteger winrtPickingMode;
@property (nonatomic, strong, nullable) UIView *importBusyView;
@end

@implementation ContainerDetailViewController

- (instancetype)initWithContainer:(VMContainer *)container mainVC:(MainViewController *)mainVC index:(NSInteger)index {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _container = container;
        _mainVC = mainVC;
        _containerIndex = index;
        _cachedDiskUsageText = L(@"calculating");
    }
    return self;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.container.name ?: L(@"container_details");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    VMContainer *container = self.container;
    NSString *containersRoot = [self.mainVC containersDirectory];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int64_t bytes = [container stateDiskUsageWithRoot:containersRoot];
        double mb = (double)bytes / (1024.0 * 1024.0);
        NSString *formatted = [NSString stringWithFormat:@"%.1f MB", mb];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.cachedDiskUsageText = formatted;
            if ([s numberOfSectionsInTableView:s.tableView] > 0 && [s.tableView numberOfRowsInSection:0] > 4) {
                [s.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:4 inSection:0]]
                                   withRowAnimation:UITableViewRowAnimationNone];
            }
        });
    });
}

- (BOOL)isWinRTContainer {
    return [self.container.platform isEqualToString:@"winrt"] ||
           [self.container.baseId hasPrefix:@"winrt-"];
}

- (BOOL)isChromeOSContainer {
    return [self.container.platform isEqualToString:@"chromeos"] ||
           [self.container.baseId hasPrefix:@"chromeos-"];
}

- (BOOL)isUbuntuTouchVirtContainer {
    return [self.container.platform isEqualToString:@"ubuntutouch"] ||
           [self.container.baseId hasPrefix:@"ut-virt-"];
}

- (BOOL)isVirtHardwareContainer {
    return [self isWinRTContainer] || [self isChromeOSContainer] || [self isUbuntuTouchVirtContainer];
}

- (NSInteger)effectiveWinRTRamMB {
    if (self.container.ramMB >= 512) return self.container.ramMB;
    return ([self isChromeOSContainer] || [self isUbuntuTouchVirtContainer]) ? 1536 : 2048;
}

- (NSString *)effectiveWinRTRtcDate {
    return self.container.winrtRtcDate.length > 0 ? self.container.winrtRtcDate : @"2013-07-15";
}

- (NSString *)resolvedStatePath:(nullable NSString *)pathOrName {
    if (pathOrName.length == 0) return @"";
    if ([pathOrName isAbsolutePath]) return pathOrName;
    NSString *statePath = [self.container statePathWithRoot:[self.mainVC containersDirectory]];
    return [statePath stringByAppendingPathComponent:pathOrName];
}

- (NSString *)resolvedWinRTPath:(nullable NSString *)pathOrName {
    return [self resolvedStatePath:pathOrName];
}

- (BOOL)isAndroidContainer {
    if ([self isVirtHardwareContainer]) return NO;
    return [self.container.platform isEqualToString:@"android"] ||
           [self.container.baseId hasPrefix:@"android-"] ||
           [self.container.platform isEqualToString:@"firefoxos"] ||
           [self.container.baseId hasPrefix:@"fxos-"];
}

- (NSInteger)effectiveAndroidRamMB {
    if (self.container.ramMB >= 256) return self.container.ramMB;
    return 512;
}

- (NSInteger)effectiveAndroidLcdDensity {
    if (self.container.lcdDensity >= 160) return self.container.lcdDensity;
    return 320;
}

- (BOOL)effectiveAndroidGpuEnabled {
    return self.container.gpuMode >= 0;
}

- (void)refreshDiskUsage {
    VMContainer *container = self.container;
    NSString *containersRoot = [self.mainVC containersDirectory];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int64_t bytes = [container stateDiskUsageWithRoot:containersRoot];
        double mb = (double)bytes / (1024.0 * 1024.0);
        NSString *formatted = [NSString stringWithFormat:@"%.1f MB", mb];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.cachedDiskUsageText = formatted;
            if ([s numberOfSectionsInTableView:s.tableView] > 0 && [s.tableView numberOfRowsInSection:0] > 4) {
                [s.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:4 inSection:0]]
                                   withRowAnimation:UITableViewRowAnimationNone];
            }
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ([self isAndroidContainer] || [self isVirtHardwareContainer]) ? 3 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        BOOL requiresBootrom = ([self.mainVC requiredBootromTypeForIdentifier:self.container.baseId] != nil);
        return requiresBootrom ? 6 : 5;
    }
    if ([self isWinRTContainer] && section == 1) {
        return 7;
    }
    if ([self isChromeOSContainer] && section == 1) {
        return 5;
    }
    if ([self isUbuntuTouchVirtContainer] && section == 1) {
        return 4;
    }
    if ([self isAndroidContainer] && section == 1) {
        return 4;
    }
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return L(@"section_info");
    if ([self isWinRTContainer] && section == 1) return L(@"section_winrt_config");
    if ([self isChromeOSContainer] && section == 1) return L(@"section_chromeos_config");
    if ([self isUbuntuTouchVirtContainer] && section == 1) return L(@"section_ubuntutouch_config");
    if ([self isAndroidContainer] && section == 1) return L(@"section_android_config");
    return L(@"section_actions");
}

- (UITableViewCell *)configureVirtDiskStatusCell:(UITableViewCell *)cell title:(NSString *)title path:(nullable NSString *)relPath {
    cell.textLabel.text = title;
    NSString *diskFull = [self resolvedWinRTPath:relPath];
    if (diskFull.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:diskFull]) {
        struct stat st;
        unsigned long long physBytes = 0;
        unsigned long long logicalBytes = 0;
        if (stat([diskFull fileSystemRepresentation], &st) == 0) {
            logicalBytes = (unsigned long long)st.st_size;
            physBytes = (unsigned long long)st.st_blocks * 512ULL;
            if (physBytes == 0 && logicalBytes > 0) physBytes = logicalBytes;
        }
        uint64_t qcowVirt = 0;
        if (winrt_qcow2_read_virtual_size([diskFull fileSystemRepresentation], &qcowVirt) && qcowVirt > 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%.1f / %.0f GB)",
                diskFull.lastPathComponent,
                (double)logicalBytes / (1024.0 * 1024.0 * 1024.0),
                (double)qcowVirt / (1024.0 * 1024.0 * 1024.0)];
        } else {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (実 %.1f / %.0f GB)",
                diskFull.lastPathComponent,
                (double)physBytes / (1024.0 * 1024.0 * 1024.0),
                (double)logicalBytes / (1024.0 * 1024.0 * 1024.0)];
        }
    } else {
        cell.detailTextLabel.text = L(@"winrt_cfg_none");
    }
    cell.imageView.image = [UIImage systemImageNamed:@"internaldrive"];
    cell.imageView.tintColor = [UIColor systemBlueColor];
    return cell;
}

- (void)presentVirtRamPickerWithRecommended:(NSInteger)recMB indexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"winrt_cfg_ram")
                                                                   message:L(@"winrt_cfg_ram_hint")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger curRam = [self effectiveWinRTRamMB];
    for (NSNumber *mbNum in @[@512, @768, @1024, @1536, @2048]) {
        NSInteger mb = mbNum.integerValue;
        NSString *tag = (mb == recMB)
            ? [NSString stringWithFormat:@"%ld MB (%@)", (long)mb, L(@"recommended")]
            : [NSString stringWithFormat:@"%ld MB", (long)mb];
        if (mb == curRam) tag = [NSString stringWithFormat:@"✓ %@", tag];
        [sheet addAction:[UIAlertAction actionWithTitle:tag style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.container.ramMB = mb;
            [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentVirtQcow2DiskSheetWithTitle:(NSString *)title
                               defaultName:(NSString *)defaultName
                                     sizes:(NSArray<NSNumber *> *)sizes
                       allowConvertFromRaw:(BOOL)allowConvert
                                 indexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:L(@"winrt_cfg_disk_hint")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *curDiskFull = [self resolvedWinRTPath:self.container.winrtDiskPath];
    NSString *curExt = curDiskFull.pathExtension.lowercaseString;
    if (allowConvert && curDiskFull.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:curDiskFull] &&
        ([curExt isEqualToString:@"img"] || [curExt isEqualToString:@"raw"])) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"既存の IMG を QCOW2 に変換して省容量化"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            NSString *statePath = [self.container statePathWithRoot:[self.mainVC containersDirectory]];
            NSString *dstName = defaultName;
            NSString *dstPath = [statePath stringByAppendingPathComponent:dstName];
            NSString *tmpPath = [statePath stringByAppendingPathComponent:[defaultName stringByAppendingString:@".tmp"]];
            UIAlertController *prog = [UIAlertController alertControllerWithTitle:@"QCOW2 に変換中…"
                                                                          message:@"未使用領域を削減しています（0%）"
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [self presentViewController:prog animated:YES completion:nil];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                int rc = winrt_qcow2_convert_from_raw(
                    [curDiskFull fileSystemRepresentation],
                    [tmpPath fileSystemRepresentation],
                    ClassicWinRTQcow2ProgressTrampoline,
                    (__bridge void *)prog
                );
                dispatch_async(dispatch_get_main_queue(), ^{
                    [prog dismissViewControllerAnimated:YES completion:^{
                        if (rc == 0) {
                            NSFileManager *fm = [NSFileManager defaultManager];
                            [fm removeItemAtPath:dstPath error:nil];
                            NSError *mvErr = nil;
                            if ([fm moveItemAtPath:tmpPath toPath:dstPath error:&mvErr]) {
                                if (![curDiskFull isEqualToString:dstPath]) {
                                    [fm removeItemAtPath:curDiskFull error:nil];
                                }
                                self.container.winrtDiskPath = dstName;
                                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                                [self.tableView reloadData];
                                [self refreshDiskUsage];
                            }
                        } else {
                            UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"変換エラー"
                                                                                            message:[NSString stringWithFormat:@"QCOW2 変換に失敗しました (%s)", strerror(-rc)]
                                                                                     preferredStyle:UIAlertControllerStyleAlert];
                            [errAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                            [self presentViewController:errAlert animated:YES completion:nil];
                        }
                    }];
                });
            });
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"winrt_import_disk_action")
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        self.winrtPickingMode = 1;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    for (NSNumber *gbNum in sizes) {
        NSInteger gb = gbNum.integerValue;
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:L(@"winrt_create_blank_disk_fmt"), (long)gb]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            NSString *statePath = [self.container statePathWithRoot:[self.mainVC containersDirectory]];
            [[NSFileManager defaultManager] createDirectoryAtPath:statePath withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *oldDisk = [self resolvedWinRTPath:self.container.winrtDiskPath];
            NSString *oldIso = [self resolvedWinRTPath:self.container.winrtIsoPath];
            NSString *newPath = [statePath stringByAppendingPathComponent:defaultName];
            NSError *err = nil;
            if (ClassicCreateWinRTQcow2DiskImage(newPath, (uint64_t)gb * 1024ULL * 1024ULL * 1024ULL, &err)) {
                if (oldDisk.length > 0 && ![oldDisk isEqualToString:newPath] && ![oldDisk isEqualToString:oldIso]) {
                    [[NSFileManager defaultManager] removeItemAtPath:oldDisk error:nil];
                }
                self.container.winrtDiskPath = defaultName;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadData];
                [self refreshDiskUsage];
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentWinRTOrChromeOSImageSheetWithTitle:(NSString *)title
                                     allowDownload:(BOOL)allowDownload
                                         indexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:L(@"winrt_cfg_iso_hint")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (allowDownload) {
        CatalogEntry *matchedCros = [self.mainVC catalogEntryWithId:self.container.baseId];
        if (matchedCros.url.length > 0) {
            NSString *dlTitle = [NSString stringWithFormat:@"公式イメージをダウンロード (%@)", matchedCros.version ?: @"Chrome OS"];
            [sheet addAction:[UIAlertAction actionWithTitle:dlTitle
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *action) {
                [self.mainVC downloadChromeOSImageForContainer:self.container entry:matchedCros fromViewController:self completion:^(BOOL ok) {
                    if (ok) {
                        [self.tableView reloadData];
                        [self refreshDiskUsage];
                    }
                }];
            }]];
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"winrt_attach_iso_action")
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        self.winrtPickingMode = 2;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    NSString *isoFull = [self resolvedWinRTPath:self.container.winrtIsoPath];
    if (isoFull.length > 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:L(@"winrt_eject_iso_action")
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *action) {
            NSString *diskFull = [self resolvedWinRTPath:self.container.winrtDiskPath];
            NSString *statePath = [self.container statePathWithRoot:[self.mainVC containersDirectory]];
            if ([isoFull hasPrefix:statePath] && ![isoFull isEqualToString:diskFull]) {
                [[NSFileManager defaultManager] removeItemAtPath:isoFull error:nil];
            }
            self.container.winrtIsoPath = nil;
            [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
            [self.tableView reloadData];
            [self refreshDiskUsage];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = L(@"container_id");
            cell.detailTextLabel.text = self.container.containerId ?: @"-";
            cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = L(@"device");
            cell.detailTextLabel.text = [self.mainVC humanReadableNameForId:self.container.baseId];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = L(@"os_version");
            cell.detailTextLabel.text = self.container.version.length > 0
                ? [NSString stringWithFormat:@"%@ (%@)", [self.mainVC formattedOSVersion:self.container.version forPlatform:self.container.platform], self.container.build ?: @""]
                : @"-";
        } else if (indexPath.row == 3) {
            cell.textLabel.text = L(@"configuration");
            if ([self isWinRTContainer]) {
                cell.detailTextLabel.text = L(@"winrt_variant_arm32");
            } else if ([self isChromeOSContainer]) {
                cell.detailTextLabel.text = @"ARMv7 Virt (OSMesa Desktop)";
            } else if ([self isUbuntuTouchVirtContainer]) {
                cell.detailTextLabel.text = @"ARMv7 Virt (Mir + QtUbuntu)";
            } else if ([self.container.platform isEqualToString:@"firefoxos"] || [self.container.baseId hasPrefix:@"fxos-"]) {
                cell.detailTextLabel.text = @"Boot to Gecko (B2G)";
            } else if ([self.container.platform isEqualToString:@"android"]) {
                cell.detailTextLabel.text = [self.container.baseId containsString:@"gapps"] ? L(@"android_variant_gapps") : L(@"android_variant_aosp");
            } else {
                cell.detailTextLabel.text = [self.container.baseId hasSuffix:@"-jb"] ? L(@"with_cydia") : L(@"standard");
            }
        } else if (indexPath.row == 4) {
            cell.textLabel.text = L(@"storage_used");
            cell.detailTextLabel.text = self.cachedDiskUsageText ?: @"-";
        } else {
            cell.textLabel.text = L(@"bootrom_type_s5l8900");
            BOOL ok = [self.mainVC hasInstalledBootromForIdentifier:self.container.baseId];
            cell.detailTextLabel.text = ok ? L(@"installed") : L(@"not_installed");
            cell.detailTextLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
        }
        return cell;
    }

    if ([self isVirtHardwareContainer] && indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([self isWinRTContainer]) {
            if (indexPath.row == 0) {
                cell.textLabel.text = L(@"winrt_cfg_ram");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB", (long)[self effectiveWinRTRamMB]];
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.imageView.tintColor = [UIColor systemGreenColor];
            } else if (indexPath.row == 1) {
                return [self configureVirtDiskStatusCell:cell title:L(@"winrt_cfg_disk") path:self.container.winrtDiskPath];
            } else if (indexPath.row == 2) {
                cell.textLabel.text = L(@"winrt_cfg_iso");
                NSString *isoFull = [self resolvedWinRTPath:self.container.winrtIsoPath];
                cell.detailTextLabel.text = (isoFull.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:isoFull])
                    ? isoFull.lastPathComponent : L(@"winrt_cfg_none");
                cell.imageView.image = [UIImage systemImageNamed:@"opticaldisc"];
                cell.imageView.tintColor = [UIColor systemPurpleColor];
            } else if (indexPath.row == 3) {
                cell.textLabel.text = L(@"winrt_cfg_boot_order");
                cell.detailTextLabel.text = self.container.winrtBootFromIso ? L(@"winrt_boot_usb_first") : L(@"winrt_boot_sd_first");
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
                cell.imageView.tintColor = [UIColor systemOrangeColor];
            } else if (indexPath.row == 4) {
                cell.textLabel.text = L(@"winrt_cfg_rtc");
                cell.detailTextLabel.text = [self effectiveWinRTRtcDate];
                cell.imageView.image = [UIImage systemImageNamed:@"calendar.badge.clock"];
                cell.imageView.tintColor = [UIColor systemIndigoColor];
            } else if (indexPath.row == 5) {
                cell.textLabel.text = L(@"winrt_cfg_net");
                cell.detailTextLabel.text = self.container.winrtEnableNet ? L(@"winrt_enabled") : L(@"winrt_disabled");
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.imageView.image = [UIImage systemImageNamed:@"network"];
                cell.imageView.tintColor = [UIColor systemTealColor];
            } else {
                cell.textLabel.text = L(@"winrt_cfg_audio");
                cell.detailTextLabel.text = self.container.winrtEnableAudio ? L(@"winrt_enabled") : L(@"winrt_disabled");
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.imageView.image = [UIImage systemImageNamed:@"speaker.wave.2"];
                cell.imageView.tintColor = [UIColor systemPinkColor];
            }
        } else if ([self isChromeOSContainer]) {
            if (indexPath.row == 0) {
                cell.textLabel.text = L(@"winrt_cfg_ram");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB", (long)[self effectiveWinRTRamMB]];
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.imageView.tintColor = [UIColor systemGreenColor];
            } else if (indexPath.row == 1) {
                return [self configureVirtDiskStatusCell:cell title:L(@"chromeos_cfg_stateful") path:self.container.winrtDiskPath];
            } else if (indexPath.row == 2) {
                cell.textLabel.text = L(@"chromeos_cfg_image");
                NSString *isoFull = [self resolvedWinRTPath:self.container.winrtIsoPath];
                cell.detailTextLabel.text = (isoFull.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:isoFull])
                    ? isoFull.lastPathComponent : L(@"winrt_cfg_none");
                cell.imageView.image = [UIImage systemImageNamed:@"opticaldisc"];
                cell.imageView.tintColor = [UIColor systemPurpleColor];
            } else if (indexPath.row == 3) {
                cell.textLabel.text = L(@"winrt_cfg_net");
                cell.detailTextLabel.text = self.container.winrtEnableNet ? L(@"winrt_enabled") : L(@"winrt_disabled");
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.imageView.image = [UIImage systemImageNamed:@"network"];
                cell.imageView.tintColor = [UIColor systemTealColor];
            } else {
                cell.textLabel.text = L(@"winrt_cfg_audio");
                cell.detailTextLabel.text = self.container.winrtEnableAudio ? L(@"winrt_enabled") : L(@"winrt_disabled");
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.imageView.image = [UIImage systemImageNamed:@"speaker.wave.2"];
                cell.imageView.tintColor = [UIColor systemPinkColor];
            }
        } else {
            if (indexPath.row == 0) {
                cell.textLabel.text = L(@"winrt_cfg_ram");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB", (long)[self effectiveWinRTRamMB]];
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.imageView.tintColor = [UIColor systemGreenColor];
            } else if (indexPath.row == 1) {
                return [self configureVirtDiskStatusCell:cell title:L(@"ubuntutouch_cfg_userdata") path:self.container.winrtDiskPath];
            } else if (indexPath.row == 2) {
                cell.textLabel.text = L(@"winrt_cfg_net");
                cell.detailTextLabel.text = self.container.winrtEnableNet ? L(@"winrt_enabled") : L(@"winrt_disabled");
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.imageView.image = [UIImage systemImageNamed:@"network"];
                cell.imageView.tintColor = [UIColor systemTealColor];
            } else {
                cell.textLabel.text = L(@"winrt_cfg_audio");
                cell.detailTextLabel.text = self.container.winrtEnableAudio ? L(@"winrt_enabled") : L(@"winrt_disabled");
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.imageView.image = [UIImage systemImageNamed:@"speaker.wave.2"];
                cell.imageView.tintColor = [UIColor systemPinkColor];
            }
        }
        return cell;
    }

    if ([self isAndroidContainer] && indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.text = L(@"android_cfg_ram");
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB", (long)[self effectiveAndroidRamMB]];
            cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
            cell.imageView.tintColor = [UIColor systemGreenColor];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = L(@"android_cfg_dpi");
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld dpi", (long)[self effectiveAndroidLcdDensity]];
            cell.imageView.image = [UIImage systemImageNamed:@"aspectratio"];
            cell.imageView.tintColor = [UIColor systemIndigoColor];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = L(@"android_cfg_gpu");
            cell.detailTextLabel.text = [self effectiveAndroidGpuEnabled] ? L(@"android_cfg_gpu_on") : L(@"android_cfg_gpu_off");
            cell.imageView.image = [UIImage systemImageNamed:@"cpu"];
            cell.imageView.tintColor = [UIColor systemTealColor];
        } else {
            cell.textLabel.text = L(@"android_cfg_storage_reset");
            cell.detailTextLabel.text = L(@"android_cfg_cache_or_data");
            cell.imageView.image = [UIImage systemImageNamed:@"externaldrive"];
            cell.imageView.tintColor = [UIColor systemOrangeColor];
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.row == 0) {
        cell.textLabel.text = L(@"boot_container");
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.imageView.image = [UIImage systemImageNamed:@"play.fill"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
    } else if (indexPath.row == 1) {
        cell.textLabel.text = L(@"rename_container");
        cell.textLabel.textColor = [UIColor labelColor];
        cell.imageView.image = [UIImage systemImageNamed:@"pencil"];
        cell.imageView.tintColor = [UIColor systemOrangeColor];
    } else if (indexPath.row == 2) {
        cell.textLabel.text = L(@"view_serial_log");
        cell.textLabel.textColor = [UIColor labelColor];
        cell.imageView.image = [UIImage systemImageNamed:@"doc.text.magnifyingglass"];
        cell.imageView.tintColor = [UIColor systemTealColor];
    } else {
        cell.textLabel.text = L(@"delete_container");
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.imageView.tintColor = [UIColor systemRedColor];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 0) {
        if (self.container.containerId.length > 0) {
            [UIPasteboard generalPasteboard].string = self.container.containerId;
            UIAlertController *copiedAlert = [UIAlertController alertControllerWithTitle:L(@"copied")
                                                                                 message:[NSString stringWithFormat:L(@"copied_container_id_fmt"), self.container.containerId]
                                                                          preferredStyle:UIAlertControllerStyleAlert];
            [copiedAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:copiedAlert animated:YES completion:nil];
        }
        return;
    }
    NSInteger actionsSection = ([self isAndroidContainer] || [self isVirtHardwareContainer]) ? 2 : 1;
    if ([self isVirtHardwareContainer] && indexPath.section == 1) {
        if ([self isWinRTContainer]) {
            if (indexPath.row == 0) {
                [self presentVirtRamPickerWithRecommended:2048 indexPath:indexPath];
            } else if (indexPath.row == 1) {
                [self presentVirtQcow2DiskSheetWithTitle:L(@"winrt_cfg_disk")
                                             defaultName:@"sdcard.qcow2"
                                                   sizes:@[@32, @48, @64, @128]
                                     allowConvertFromRaw:YES
                                               indexPath:indexPath];
            } else if (indexPath.row == 2) {
                [self presentWinRTOrChromeOSImageSheetWithTitle:L(@"winrt_cfg_iso")
                                                  allowDownload:NO
                                                      indexPath:indexPath];
            } else if (indexPath.row == 3) {
                self.container.winrtBootFromIso = !self.container.winrtBootFromIso;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            } else if (indexPath.row == 4) {
                UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"winrt_cfg_rtc")
                                                                               message:L(@"winrt_cfg_rtc_hint")
                                                                        preferredStyle:UIAlertControllerStyleActionSheet];
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                df.dateFormat = @"yyyy-MM-dd";
                NSString *todayStr = [df stringFromDate:[NSDate date]];
                NSString *curDate = [self effectiveWinRTRtcDate];
                NSArray<NSArray<NSString *> *> *presets = @[
                    @[@"2013-07-15", [NSString stringWithFormat:@"2013-07-15 (Windows RT 8.0 / 8.1)"]],
                    @[@"2017-03-01", [NSString stringWithFormat:@"2017-03-01 (Windows 10 Build 15035)"]],
                    @[todayStr, [NSString stringWithFormat:@"%@ (%@)", todayStr, L(@"winrt_rtc_today")]]
                ];
                for (NSArray<NSString *> *p in presets) {
                    NSString *val = p[0];
                    NSString *title = [val isEqualToString:curDate] ? [NSString stringWithFormat:@"✓ %@", p[1]] : p[1];
                    [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                        self.container.winrtRtcDate = val;
                        [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                        [self.tableView reloadData];
                    }]];
                }
                [sheet addAction:[UIAlertAction actionWithTitle:L(@"winrt_rtc_custom") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:L(@"winrt_cfg_rtc")
                                                                                    message:L(@"winrt_rtc_custom_hint")
                                                                             preferredStyle:UIAlertControllerStyleAlert];
                    [prompt addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                        tf.placeholder = @"YYYY-MM-DD";
                        tf.text = curDate;
                    }];
                    [prompt addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
                    [prompt addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *okAct) {
                        NSString *entered = [prompt.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if (entered.length == 10) {
                            self.container.winrtRtcDate = entered;
                            [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                            [self.tableView reloadData];
                        }
                    }]];
                    [self presentViewController:prompt animated:YES completion:nil];
                }]];
                [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
                sheet.popoverPresentationController.sourceView = self.tableView;
                sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
                [self presentViewController:sheet animated:YES completion:nil];
            } else if (indexPath.row == 5) {
                self.container.winrtEnableNet = !self.container.winrtEnableNet;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            } else {
                self.container.winrtEnableAudio = !self.container.winrtEnableAudio;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            }
        } else if ([self isChromeOSContainer]) {
            if (indexPath.row == 0) {
                [self presentVirtRamPickerWithRecommended:1536 indexPath:indexPath];
            } else if (indexPath.row == 1) {
                [self presentVirtQcow2DiskSheetWithTitle:L(@"chromeos_cfg_stateful")
                                             defaultName:@"sdcard.qcow2"
                                                   sizes:@[@16, @32, @48, @64, @128]
                                     allowConvertFromRaw:NO
                                               indexPath:indexPath];
            } else if (indexPath.row == 2) {
                [self presentWinRTOrChromeOSImageSheetWithTitle:L(@"chromeos_cfg_image")
                                                  allowDownload:YES
                                                      indexPath:indexPath];
            } else if (indexPath.row == 3) {
                self.container.winrtEnableNet = !self.container.winrtEnableNet;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            } else {
                self.container.winrtEnableAudio = !self.container.winrtEnableAudio;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            }
        } else {
            if (indexPath.row == 0) {
                [self presentVirtRamPickerWithRecommended:1536 indexPath:indexPath];
            } else if (indexPath.row == 1) {
                [self presentVirtQcow2DiskSheetWithTitle:L(@"ubuntutouch_cfg_userdata")
                                             defaultName:@"userdata.qcow2"
                                                   sizes:@[@8, @16, @32, @64]
                                     allowConvertFromRaw:NO
                                               indexPath:indexPath];
            } else if (indexPath.row == 2) {
                self.container.winrtEnableNet = !self.container.winrtEnableNet;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            } else {
                self.container.winrtEnableAudio = !self.container.winrtEnableAudio;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            }
        }
        return;
    }

    if ([self isAndroidContainer] && indexPath.section == 1) {
        if (indexPath.row == 0) {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"android_cfg_ram")
                                                                           message:L(@"android_cfg_ram_hint")
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
            NSInteger curRam = [self effectiveAndroidRamMB];
            NSInteger recRam = 512;
            for (NSNumber *mbNum in @[@256, @384, @512, @768, @1024, @1536, @2048, @3072]) {
                NSInteger mb = mbNum.integerValue;
                NSString *tag = (mb == recRam) ? [NSString stringWithFormat:@"%ld MB (%@)", (long)mb, L(@"recommended")] : [NSString stringWithFormat:@"%ld MB", (long)mb];
                if (mb == curRam) tag = [NSString stringWithFormat:@"✓ %@", tag];
                [sheet addAction:[UIAlertAction actionWithTitle:tag style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    self.container.ramMB = mb;
                    [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                    [self.tableView reloadData];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:L(@"android_cfg_ram_custom") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                UIAlertController *prompt = [UIAlertController alertControllerWithTitle:L(@"android_cfg_ram")
                                                                                message:L(@"android_cfg_ram_custom_hint")
                                                                         preferredStyle:UIAlertControllerStyleAlert];
                [prompt addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                    tf.keyboardType = UIKeyboardTypeNumberPad;
                    tf.placeholder = @"1536";
                    tf.text = [NSString stringWithFormat:@"%ld", (long)curRam];
                }];
                [prompt addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
                [prompt addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction *okAct) {
                    NSInteger entered = prompt.textFields.firstObject.text.integerValue;
                    if (entered < 256) entered = 256;
                    if (entered > 3072) entered = 3072;
                    self.container.ramMB = entered;
                    [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                    [self.tableView reloadData];
                }]];
                [self presentViewController:prompt animated:YES completion:nil];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView = self.tableView;
            sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
            [self presentViewController:sheet animated:YES completion:nil];
        } else if (indexPath.row == 1) {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"android_cfg_dpi")
                                                                           message:L(@"android_cfg_dpi_hint")
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
            NSInteger curDpi = [self effectiveAndroidLcdDensity];
            NSInteger stdDpi = 320;
            for (NSNumber *dpiNum in @[@240, @320, @400]) {
                NSInteger dpi = dpiNum.integerValue;
                NSString *tag = (dpi == stdDpi) ? [NSString stringWithFormat:@"%ld dpi (%@)", (long)dpi, L(@"standard")] : [NSString stringWithFormat:@"%ld dpi", (long)dpi];
                if (dpi == curDpi) tag = [NSString stringWithFormat:@"✓ %@", tag];
                [sheet addAction:[UIAlertAction actionWithTitle:tag style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    self.container.lcdDensity = dpi;
                    [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                    [self.tableView reloadData];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView = self.tableView;
            sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
            [self presentViewController:sheet animated:YES completion:nil];
        } else if (indexPath.row == 2) {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"android_cfg_gpu")
                                                                           message:L(@"android_cfg_gpu_hint")
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
            BOOL gpuOn = [self effectiveAndroidGpuEnabled];
            [sheet addAction:[UIAlertAction actionWithTitle:(gpuOn ? [NSString stringWithFormat:@"✓ %@", L(@"android_cfg_gpu_on")] : L(@"android_cfg_gpu_on"))
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *action) {
                self.container.gpuMode = 1;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadData];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:(!gpuOn ? [NSString stringWithFormat:@"✓ %@", L(@"android_cfg_gpu_off")] : L(@"android_cfg_gpu_off"))
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *action) {
                self.container.gpuMode = -1;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.tableView reloadData];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView = self.tableView;
            sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
            [self presentViewController:sheet animated:YES completion:nil];
        } else if (indexPath.row == 3) {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"android_cfg_storage_reset")
                                                                           message:L(@"android_cfg_storage_hint")
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
            [sheet addAction:[UIAlertAction actionWithTitle:L(@"android_clear_cache_action")
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *action) {
                NSString *statePath = [self.container statePathWithRoot:[self.mainVC containersDirectory]];
                [[NSFileManager defaultManager] removeItemAtPath:[statePath stringByAppendingPathComponent:@"cache.img"] error:nil];
                [self refreshDiskUsage];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:L(@"android_wipe_userdata_action")
                                                     style:UIAlertActionStyleDestructive
                                                   handler:^(UIAlertAction *action) {
                NSString *statePath = [self.container statePathWithRoot:[self.mainVC containersDirectory]];
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtPath:[statePath stringByAppendingPathComponent:@"userdata.img"] error:nil];
                [fm removeItemAtPath:[statePath stringByAppendingPathComponent:@"cache.img"] error:nil];
                [self refreshDiskUsage];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView = self.tableView;
            sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
            [self presentViewController:sheet animated:YES completion:nil];
        }
        return;
    }
    if (indexPath.section != actionsSection) return;

    if (indexPath.row == 0) {
        [self.navigationController popViewControllerAnimated:NO];
        [self.mainVC bootContainer:self.container];
    } else if (indexPath.row == 1) {
        UIAlertController *prompt = [UIAlertController alertControllerWithTitle:L(@"rename_title")
                                                                        message:nil
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [prompt addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = self.container.name;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [prompt addAction:[UIAlertAction actionWithTitle:L(@"save") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UITextField *tf = prompt.textFields.firstObject;
            if (tf.text.length > 0) {
                self.container.name = tf.text;
                self.title = tf.text;
                [self.container saveMetadataWithRoot:[self.mainVC containersDirectory]];
                [self.mainVC.tableView reloadData];
            }
        }]];
        [prompt addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:prompt animated:YES completion:nil];
    } else if (indexPath.row == 2) {
        NSString *statePath = [self.container statePathWithRoot:[self.mainVC containersDirectory]];
        NSString *serialPath = [statePath stringByAppendingPathComponent:@"serial.log"];
        NSString *logText = [NSString stringWithContentsOfFile:serialPath encoding:NSUTF8StringEncoding error:nil];
        if (!logText) {
            logText = [NSString stringWithContentsOfFile:serialPath encoding:NSISOLatin1StringEncoding error:nil];
        }
        NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *bootLogPath = [docDir stringByAppendingPathComponent:@"last_boot.log"];
        NSString *bootLogText = [NSString stringWithContentsOfFile:bootLogPath encoding:NSUTF8StringEncoding error:nil];
        if (!bootLogText) {
            bootLogText = [NSString stringWithContentsOfFile:bootLogPath encoding:NSISOLatin1StringEncoding error:nil];
        }
        if (bootLogText.length > 2500) {
            bootLogText = [bootLogText substringFromIndex:bootLogText.length - 2500];
        }
        if (logText.length > 2500) {
            logText = [logText substringFromIndex:logText.length - 2500];
        }
        if (bootLogText.length > 0) {
            logText = [NSString stringWithFormat:@"%@\n--- stderr (last_boot.log) ---\n%@",
                       logText ?: @"", bootLogText];
        }
        if (logText.length == 0) {
            logText = L(@"no_serial_log");
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"view_serial_log")
                                                                       message:logText
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"copy") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = logText;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (indexPath.row == 3) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:self.containerIndex inSection:0];
        [self.navigationController popViewControllerAnimated:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.mainVC confirmDeleteContainer:self.container indexPath:ip];
        });
    }
}

- (void)showImportBusy:(BOOL)busy title:(nullable NSString *)title {
    if (busy) {
        if (self.importBusyView) [self.importBusyView removeFromSuperview];
        UIView *host = self.navigationController.view ?: self.view;
        UIView *overlay = [[UIView alloc] initWithFrame:host.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        spinner.color = [UIColor whiteColor];
        spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [spinner startAnimating];
        UILabel *lbl = [[UILabel alloc] init];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        lbl.text = title ?: L(@"winrt_importing_media");
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
        lbl.textAlignment = NSTextAlignmentCenter;
        [overlay addSubview:spinner];
        [overlay addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [spinner.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
            [spinner.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-14],
            [lbl.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:12],
            [lbl.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
            [lbl.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:24],
            [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-24]
        ]];
        [host addSubview:overlay];
        self.importBusyView = overlay;
        self.navigationController.navigationBar.userInteractionEnabled = NO;
    } else {
        [self.importBusyView removeFromSuperview];
        self.importBusyView = nil;
        self.navigationController.navigationBar.userInteractionEnabled = YES;
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.winrtPickingMode = 0;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSInteger mode = self.winrtPickingMode;
    self.winrtPickingMode = 0;
    NSURL *pickedURL = urls.firstObject;
    if (!pickedURL) return;

    if (mode == 0) return;

    NSString *ext = pickedURL.pathExtension.lowercaseString ?: @"";
    NSSet<NSString *> *validExts = (mode == 1)
        ? [NSSet setWithArray:@[@"vhd", @"vhdx", @"img", @"raw", @"qcow2"]]
        : [NSSet setWithArray:@[@"iso", @"vhd", @"vhdx", @"img", @"raw"]];
    if (![validExts containsObject:ext]) {
        [[NSFileManager defaultManager] removeItemAtURL:pickedURL error:nil];
        UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:L(@"error")
                                                                          message:L(@"winrt_invalid_image_ext")
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [errAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:errAlert animated:YES completion:nil];
        return;
    }

    NSString *statePath = [self.container statePathWithRoot:[self.mainVC containersDirectory]];
    NSString *otherFull = [self resolvedWinRTPath:(mode == 1 ? self.container.winrtIsoPath : self.container.winrtDiskPath)];
    NSString *oldFull = [self resolvedWinRTPath:(mode == 1 ? self.container.winrtDiskPath : self.container.winrtIsoPath)];
    NSString *fileName = pickedURL.lastPathComponent ?: (mode == 1 ? @"disk.img" : @"install.iso");
    NSString *destPath = [statePath stringByAppendingPathComponent:fileName];
    if ([destPath isEqualToString:otherFull]) {
        fileName = [(mode == 1 ? @"disk_" : @"usb_") stringByAppendingString:fileName];
        destPath = [statePath stringByAppendingPathComponent:fileName];
    }

    [self showImportBusy:YES title:L(@"winrt_importing_media")];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [pickedURL startAccessingSecurityScopedResource];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:statePath withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm fileExistsAtPath:destPath]) {
            [fm removeItemAtPath:destPath error:nil];
        }
        NSError *copyErr = nil;
        NSURL *destURL = [NSURL fileURLWithPath:destPath];
        BOOL ok = [fm moveItemAtURL:pickedURL toURL:destURL error:&copyErr];
        if (!ok) {
            copyErr = nil;
            ok = [fm copyItemAtURL:pickedURL toURL:destURL error:&copyErr];
        }
        if (scoped) {
            [pickedURL stopAccessingSecurityScopedResource];
        }
        BOOL showNoElToritoWarn = NO;
        if (ok && mode == 2 && [ext isEqualToString:@"iso"]) {
            ClassicWinRTMediaInfo probe = ClassicProbeWinRTMedia(destPath);
            if (probe.exists && !probe.hasElTorito) {
                showNoElToritoWarn = YES;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s showImportBusy:NO title:nil];
            if (!ok) {
                UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"error")
                                                                              message:copyErr.localizedDescription ?: @"Import failed"
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleCancel handler:nil]];
                [s presentViewController:fail animated:YES completion:nil];
                return;
            }
            if (oldFull.length > 0 && [oldFull hasPrefix:statePath] &&
                ![oldFull isEqualToString:destPath] && ![oldFull isEqualToString:otherFull]) {
                [fm removeItemAtPath:oldFull error:nil];
            }
            if (mode == 1) {
                s.container.winrtDiskPath = fileName;
            } else {
                s.container.winrtIsoPath = fileName;
                s.container.winrtBootFromIso = YES;
            }
            [s.container saveMetadataWithRoot:[s.mainVC containersDirectory]];
            [s.tableView reloadData];
            [s refreshDiskUsage];
            if (showNoElToritoWarn) {
                UIAlertController *warn = [UIAlertController alertControllerWithTitle:L(@"winrt_iso_no_eltorito_title")
                                                                              message:L(@"winrt_iso_no_eltorito_msg")
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [warn addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                [s presentViewController:warn animated:YES completion:nil];
            }
        });
    });
}

@end

@interface BootromViewController : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, weak) MainViewController *mainVC;
@end

@implementation BootromViewController

- (instancetype)initWithMainVC:(MainViewController *)mainVC {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _mainVC = mainVC;
    }
    return self;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"bootrom_title");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(closeTapped:)];
}

- (void)closeTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    BOOL installed = [self.mainVC hasInstalledBootrom];
    if (section == 0) return 1;
    return installed ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? L(@"status") : L(@"section_actions");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? L(@"bootrom_footer_soc") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSString *path = [self.mainVC pathForInstalledBootromType:@"s5l8900"];
        cell.textLabel.text = L(@"bootrom_s5l8900_desc");
        if (path) {
            unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%llu KB)", path.lastPathComponent, sz / 1024];
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        } else {
            cell.detailTextLabel.text = L(@"not_installed");
            cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.row == 0) {
        cell.textLabel.text = L(@"import_bootrom");
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.imageView.image = [UIImage systemImageNamed:@"folder.badge.plus"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
    } else {
        cell.textLabel.text = L(@"remove_bootrom");
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.imageView.tintColor = [UIColor systemRedColor];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;

    if (indexPath.row == 0) {
        NSArray *types = @[ UTTypeItem, UTTypeData ];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    } else {
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:L(@"remove_bootrom_confirm_title")
                                                                         message:L(@"remove_bootrom_confirm_msg")
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:L(@"delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            NSString *docs = [self.mainVC appDocumentsPath];
            NSString *romsDir = [docs stringByAppendingPathComponent:@"bootroms"];
            NSFileManager *fm = [NSFileManager defaultManager];
            for (NSString *name in @[@"bootrom_s5l8900", @"bootrom_s5l8900.bin", @"s5l8900.bin", @"s5l8900-bootrom.bin", @"bootrom_240_4", @"bootrom_240_4.bin", @"bootrom.bin"]) {
                [fm removeItemAtPath:[docs stringByAppendingPathComponent:name] error:nil];
                [fm removeItemAtPath:[romsDir stringByAppendingPathComponent:name] error:nil];
            }
            [self.mainVC invalidateBootromCache];
            [self.mainVC updateRomButtonState];
            [self.mainVC.tableView reloadData];
            [self.tableView reloadData];
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:confirm animated:YES completion:nil];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    [self.mainVC handleImportedBootrom:url];
    [self.tableView reloadData];
}

@end

@interface FirmwareManagementViewController : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, weak) MainViewController *mainVC;
@property (nonatomic, strong) NSArray<FirmwareFile *> *firmwares;
@end

@implementation FirmwareManagementViewController

- (instancetype)initWithMainVC:(MainViewController *)mainVC {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _mainVC = mainVC;
    }
    return self;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"firmware_mgmt_title");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(closeTapped:)];
    [self reloadFirmwares];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFirmwares];
}

- (void)reloadFirmwares {
    self.firmwares = [self.mainVC scanDownloadedFirmwares];
    [self.tableView reloadData];
}

- (void)closeTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)numberOfRowsForSectionActions {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return self.firmwares.count > 0 ? self.firmwares.count : 1;
    }
    return [self numberOfRowsForSectionActions];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? L(@"downloaded_ipsws") : L(@"section_actions");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        if (self.firmwares.count == 0) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = L(@"no_firmware");
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        FirmwareFile *f = self.firmwares[indexPath.row];
        NSArray<VMContainer *> *usedBy = [self.mainVC containersUsingEntryId:f.entryId];
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)", [self.mainVC humanReadableNameForId:f.entryId], [self.mainVC formattedOSVersion:f.version forPlatform:f.platform]];
        cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        double mb = (double)f.fileSizeBytes / (1024.0 * 1024.0);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f MB • %@", mb, usedBy.count > 0 ? L(@"in_use_badge") : L(@"unused")];
        cell.detailTextLabel.textColor = usedBy.count > 0 ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
        cell.imageView.image = [UIImage systemImageNamed:@"opticaldisc"];
        cell.imageView.tintColor = usedBy.count > 0 ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.row == 0) {
        cell.textLabel.text = L(@"download_catalog_ipsw");
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.imageView.image = [UIImage systemImageNamed:@"arrow.down.circle"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
    } else {
        cell.textLabel.text = L(@"import_local_ipsw");
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.imageView.image = [UIImage systemImageNamed:@"folder.badge.plus"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
    }
    return cell;
}

- (void)presentCatalogDownloadDevicePickerFromCell:(nullable UITableViewCell *)sourceCell {
    UIAlertController *deviceSelect = [UIAlertController alertControllerWithTitle:L(@"select_device_title")
                                                                          message:L(@"download_catalog_device_msg")
                                                                   preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSDictionary<NSString *, NSString *> *> *devices = @[
        @{@"title": L(@"device_iphone_2g_desc"), @"type": @"iPhone1,1"},
        @{@"title": L(@"device_iphone_3gs_desc"), @"type": @"iPhone2,1"},
        @{@"title": L(@"device_iphone_4_desc"), @"type": @"iPhone3,1"},
        @{@"title": L(@"device_iphone_5_desc"), @"type": @"iPhone5,2"},
        @{@"title": L(@"device_ipod_1g_desc"), @"type": @"iPod1,1"},
        @{@"title": L(@"device_ipod_3g_desc"), @"type": @"iPod3,1"},
        @{@"title": L(@"device_ipod_4g_desc"), @"type": @"iPod4,1"},
        @{@"title": L(@"device_ipad_1g_desc"), @"type": @"iPad1,1"},
        @{@"title": L(@"device_android_arm_desc"), @"type": @"AndroidARMv7"},
        @{@"title": L(@"device_firefoxos_arm_desc"), @"type": @"FirefoxOSARMv7"},
        @{@"title": L(@"device_ubuntutouch_virt_desc"), @"type": @"UbuntuTouchVirtARMv7"}
    ];

    for (NSDictionary<NSString *, NSString *> *d in devices) {
        NSString *title = d[@"title"];
        NSString *prodType = d[@"type"];
        [deviceSelect addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self presentCatalogDownloadVersionPickerForProductType:prodType deviceTitle:title sourceCell:sourceCell];
        }]];
    }
    [deviceSelect addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (deviceSelect.popoverPresentationController) {
        deviceSelect.popoverPresentationController.sourceView = sourceCell ?: self.tableView;
        deviceSelect.popoverPresentationController.sourceRect = sourceCell ? sourceCell.bounds : self.tableView.bounds;
    }
    [self presentViewController:deviceSelect animated:YES completion:nil];
}

- (void)dismissToMainAndRun:(void (^)(void))block {
    MainViewController *mainVC = self.mainVC;
    UIViewController *rootPresenter = mainVC.navigationController ?: mainVC;
    if (rootPresenter && rootPresenter.presentedViewController) {
        [rootPresenter dismissViewControllerAnimated:YES completion:block];
    } else if (mainVC && mainVC.presentedViewController) {
        [mainVC dismissViewControllerAnimated:YES completion:block];
    } else {
        [self dismissViewControllerAnimated:YES completion:block];
    }
}

- (void)presentCatalogDownloadVersionPickerForProductType:(NSString *)prodType deviceTitle:(NSString *)deviceTitle sourceCell:(nullable UITableViewCell *)sourceCell {
    NSMutableArray<CatalogEntry *> *filtered = [NSMutableArray array];
    for (CatalogEntry *ce in self.mainVC.catalogEntries) {
        if ([ce.productType isEqualToString:prodType] && ce.url.length > 0) {
            [filtered addObject:ce];
        }
    }

    UIAlertController *versionSelect = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:L(@"select_os_title"), deviceTitle]
                                                                           message:L(@"download_catalog_version_msg")
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
    for (CatalogEntry *ce in filtered) {
        NSString *existing = [self.mainVC findExistingIPSWForEntryId:ce.entryId];
        int64_t dlBytes = [self.mainVC remainingDownloadBytesForEntry:ce];
        NSString *tag = existing
            ? [NSString stringWithFormat:@" [%@]", L(@"downloaded_badge")]
            : [NSString stringWithFormat:@" (%.0f MB)", (double)dlBytes / (1024.0 * 1024.0)];
        NSString *btnTitle = [NSString stringWithFormat:@"%@ (%@)%@", [self.mainVC formattedOSVersion:ce.version forPlatform:ce.platform], ce.build, tag];
        [versionSelect addAction:[UIAlertAction actionWithTitle:btnTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (existing) {
                UIAlertController *redl = [UIAlertController alertControllerWithTitle:L(@"redownload_ipsw_title")
                                                                              message:[NSString stringWithFormat:L(@"redownload_ipsw_msg"), [self.mainVC formattedOSVersion:ce.version forPlatform:ce.platform], ce.build]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [redl addAction:[UIAlertAction actionWithTitle:L(@"redownload_action") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
                    MainViewController *mainVC = self.mainVC;
                    if ([ce.platform isEqualToString:@"firefoxos"]) {
                        NSFileManager *fm = [NSFileManager defaultManager];
                        NSString *tarName = [NSString stringWithFormat:@"%@.tar.gz", ce.entryId];
                        NSString *gaiaName = [NSString stringWithFormat:@"%@-gaia.zip", ce.entryId];
                        [fm removeItemAtPath:[[mainVC firmwaresDirectory] stringByAppendingPathComponent:tarName] error:nil];
                        [fm removeItemAtPath:[[mainVC firmwaresDirectory] stringByAppendingPathComponent:gaiaName] error:nil];
                    }
                    [self dismissToMainAndRun:^{
                        [mainVC downloadCatalogIPSWForManagement:ce];
                    }];
                }]];
                [redl addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:redl animated:YES completion:nil];
            } else {
                MainViewController *mainVC = self.mainVC;
                [self dismissToMainAndRun:^{
                    [mainVC downloadCatalogIPSWForManagement:ce];
                }];
            }
        }]];
    }
    [versionSelect addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (versionSelect.popoverPresentationController) {
        versionSelect.popoverPresentationController.sourceView = sourceCell ?: self.tableView;
        versionSelect.popoverPresentationController.sourceRect = sourceCell ? sourceCell.bounds : self.tableView.bounds;
    }
    [self presentViewController:versionSelect animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 && self.firmwares.count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 0 && indexPath.row < (NSInteger)self.firmwares.count) {
        [self attemptDeleteFirmware:self.firmwares[indexPath.row]];
    }
}

- (void)attemptDeleteFirmware:(FirmwareFile *)f {
    NSArray<VMContainer *> *usedBy = [self.mainVC containersUsingEntryId:f.entryId];
    if (usedBy.count > 0) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (VMContainer *c in usedBy) {
            [names addObject:c.name ?: c.containerId];
        }
        UIAlertController *blocked = [UIAlertController alertControllerWithTitle:L(@"cannot_delete_in_use_title")
                                                                         message:[NSString stringWithFormat:L(@"cannot_delete_in_use_msg"), [names componentsJoinedByString:@", "]]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [blocked addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:blocked animated:YES completion:nil];
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:L(@"delete")
                                                                     message:L(@"delete_ipsw_msg")
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:L(@"delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:f.filePath error:nil];
        if (f.fileName.length > 0) {
            [fm removeItemAtPath:[[self.mainVC firmwaresDirectory] stringByAppendingPathComponent:f.fileName] error:nil];
            [fm removeItemAtPath:[[self.mainVC legacyIPSWDirectory] stringByAppendingPathComponent:f.fileName] error:nil];
        }
        if ([f.entryId hasPrefix:@"fxos-"]) {
            NSString *gaiaName = [NSString stringWithFormat:@"%@-gaia.zip", f.entryId];
            [fm removeItemAtPath:[[self.mainVC firmwaresDirectory] stringByAppendingPathComponent:gaiaName] error:nil];
            [fm removeItemAtPath:[[self.mainVC legacyIPSWDirectory] stringByAppendingPathComponent:gaiaName] error:nil];
        } else if ([f.entryId hasPrefix:@"custom-"]) {
            NSString *customMeta = [NSString stringWithFormat:@"%@.custom.json", f.entryId];
            [fm removeItemAtPath:[[self.mainVC firmwaresDirectory] stringByAppendingPathComponent:customMeta] error:nil];
            [fm removeItemAtPath:[[self.mainVC legacyIPSWDirectory] stringByAppendingPathComponent:customMeta] error:nil];
        }
        [self reloadFirmwares];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            [self presentCatalogDownloadDevicePickerFromCell:[tableView cellForRowAtIndexPath:indexPath]];
        } else {
            NSArray *types = @[
                [UTType typeWithFilenameExtension:@"ipsw"] ?: UTTypeData,
                [UTType typeWithFilenameExtension:@"zip"] ?: UTTypeData,
                [UTType typeWithFilenameExtension:@"img"] ?: UTTypeData,
                [UTType typeWithFilenameExtension:@"gz"] ?: (UTTypeGZIP ?: UTTypeData)
            ];
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
            picker.delegate = self;
            picker.allowsMultipleSelection = NO;
            [self presentViewController:picker animated:YES completion:nil];
        }
        return;
    }
    if (self.firmwares.count == 0) return;

    FirmwareFile *f = self.firmwares[indexPath.row];
    NSString *cleanName = [self.mainVC humanReadableNameForId:f.entryId];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:cleanName
                                                                   message:[NSString stringWithFormat:@"%@ (%.1f MB)", [self.mainVC formattedOSVersion:f.version ?: @"" forPlatform:f.platform], (double)f.fileSizeBytes / (1024.0 * 1024.0)]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"create_container") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        CatalogEntry *ce = nil;
        for (CatalogEntry *c in self.mainVC.catalogEntries) {
            if ([c.entryId isEqualToString:f.entryId]) {
                ce = c;
                break;
            }
        }
        if (!ce) {
            ce = [[CatalogEntry alloc] init];
            ce.entryId = f.entryId;
            ce.productType = f.productType;
            ce.version = f.version;
            ce.build = f.build;
            ce.platform = f.platform ?: ([f.entryId hasPrefix:@"chromeos-"] ? @"chromeos" : ([f.entryId hasPrefix:@"ut-virt-"] ? @"ubuntutouch" : ([f.entryId hasPrefix:@"fxos-"] ? @"firefoxos" : ([f.entryId hasPrefix:@"android-"] ? @"android" : @"ios"))));
        }
        MainViewController *mainVC = self.mainVC;
        [self dismissToMainAndRun:^{
            [mainVC promptContainerNameForEntry:ce deviceTitle:cleanName];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self attemptDeleteFirmware:f];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: tableView;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : tableView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    [self.mainVC handleImportedIPSWFromURL:url presentingViewController:self completion:^{
        [weakSelf reloadFirmwares];
    }];
}

@end

static __weak MainViewController *sCurrentMainVC = nil;

@implementation MainViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationPortrait;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    sCurrentMainVC = self;
    self.title = @"ClassicTouch";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UINavigationBarAppearance *navAppearance = [[UINavigationBarAppearance alloc] init];
    [navAppearance configureWithDefaultBackground];
    navAppearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    navAppearance.titleTextAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [UIColor labelColor]
    };
    self.navigationController.navigationBar.standardAppearance = navAppearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = navAppearance;
    self.navigationController.navigationBar.compactAppearance = navAppearance;

    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    _notifyHaptic = [[UINotificationFeedbackGenerator alloc] init];

    // Left Bar Button: Reorder (Edit)
    self.navigationItem.leftBarButtonItem = self.editButtonItem;

    // Right Bar Buttons: Add Device (+) and Settings (Gear)
    UIButton *addNavBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *addCfg = [UIButtonConfiguration tintedButtonConfiguration];
    addCfg.image = [UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightBold]];
    addCfg.title = L(@"create");
    addCfg.imagePadding = 3.5;
    addCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    addCfg.contentInsets = NSDirectionalEdgeInsetsMake(5.0, 10.0, 5.0, 10.0);
    addNavBtn.configuration = addCfg;
    addNavBtn.accessibilityLabel = L(@"create_new_vm");
    [addNavBtn addTarget:self action:@selector(presentDeviceCreationWizard:) forControlEvents:UIControlEventTouchUpInside];
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithCustomView:addNavBtn];

    UIButton *settingsNavBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *settingsCfg = [UIButtonConfiguration plainButtonConfiguration];
    settingsCfg.image = [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightMedium]];
    settingsCfg.contentInsets = NSDirectionalEdgeInsetsMake(6.0, 6.0, 6.0, 6.0);
    settingsNavBtn.configuration = settingsCfg;
    settingsNavBtn.accessibilityLabel = L(@"settings_title");
    [settingsNavBtn addTarget:self action:@selector(openSettings:) forControlEvents:UIControlEventTouchUpInside];
    UIBarButtonItem *settingsBtn = [[UIBarButtonItem alloc] initWithCustomView:settingsNavBtn];

    self.navigationItem.rightBarButtonItems = @[addBtn, settingsBtn];

    self.containers = [NSMutableArray array];
    self.catalogEntries = @[];
    self.catalogWaiters = [NSMutableArray array];
    self.cachedBootromPaths = [NSMutableDictionary dictionary];

    dispatch_queue_attr_t startupAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    self.startupQueue = dispatch_queue_create("com.classictouch.startup", startupAttr);

    // Table view
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];

    [self setupProgressOverlay];
    [self updateRomButtonState];
    [self performInitialStartupLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(syncBackgroundDownloadUIState)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)containersArray:(NSArray<VMContainer *> *)a equalsContainersArray:(NSArray<VMContainer *> *)b {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        VMContainer *ca = a[i];
        VMContainer *cb = b[i];
        if (![ca.containerId isEqualToString:cb.containerId] ||
            ![(ca.name ?: @"") isEqualToString:(cb.name ?: @"")] ||
            ![(ca.baseId ?: @"") isEqualToString:(cb.baseId ?: @"")]) {
            return NO;
        }
    }
    return YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.hasCompletedInitialLoad) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.startupQueue, ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        NSMutableArray<VMContainer *> *containers = [s scanContainersFromDisk];
        NSDictionary<NSString *, NSString *> *roms = [s scanInstalledBootromsFromDisk];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) ms = weakSelf;
            if (!ms) return;
            BOOL containersChanged = ![ms containersArray:ms.containers equalsContainersArray:containers];
            BOOL romsChanged = ![ms.cachedBootromPaths isEqualToDictionary:roms] || !ms.hasLoadedBootromCache;
            if (containersChanged) {
                ms.containers = containers;
            }
            if (romsChanged) {
                ms.cachedBootromPaths = [roms mutableCopy];
                ms.hasLoadedBootromCache = YES;
                [ms updateRomButtonState];
            }
            if (containersChanged || romsChanged) {
                [ms.tableView reloadData];
            }
        });
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSString *docDir = [self appDocumentsPath];
    NSString *flagPath = [docDir stringByAppendingPathComponent:@"boot_in_progress.flag"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:flagPath]) {
        [fm removeItemAtPath:flagPath error:nil];
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"ClassicTouchShownInitialNotice_v1"]) {
        UIAlertController *notice = [UIAlertController alertControllerWithTitle:L(@"first_run_note_title")
                                                                        message:L(@"first_run_note_msg")
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:L(@"ok_dont_show_again") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [defaults setBool:YES forKey:@"ClassicTouchShownInitialNotice_v1"];
            [defaults synchronize];
        }]];
        [self presentViewController:notice animated:YES completion:nil];
    }

    [self syncBackgroundDownloadUIState];
}

#pragma mark - Directory Helpers

- (NSString *)appDocumentsPath {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

- (NSString *)containersDirectory {
    NSString *dir = [[self appDocumentsPath] stringByAppendingPathComponent:@"Containers"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)basesDirectory {
    NSString *dir = [[self appDocumentsPath] stringByAppendingPathComponent:@"Bases"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)firmwaresDirectory {
    NSString *dir = [[self appDocumentsPath] stringByAppendingPathComponent:@"Firmwares"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)legacyIPSWDirectory {
    return [[self appDocumentsPath] stringByAppendingPathComponent:@"ipsw"];
}

- (void)ensureBaseDirectoriesExist {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[self containersDirectory] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[self basesDirectory] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[self firmwaresDirectory] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[[self appDocumentsPath] stringByAppendingPathComponent:@"bootroms"] withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)syncGuestToolsIfNeeded {
    (void)ClassicGuestToolsDirectory();
}

- (void)ensureDirectoriesExist {
    [self ensureBaseDirectoriesExist];
    [self syncGuestToolsIfNeeded];
}

- (NSString *)catalogFilePath {
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"firmware-catalog" ofType:@"json"];
    if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        return bundlePath;
    }
    bundlePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"firmware-catalog.json"];
    if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        return bundlePath;
    }
    bundlePath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"firmware-catalog.json"];
    if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        return bundlePath;
    }
    return [[self appDocumentsPath] stringByAppendingPathComponent:@"firmware-catalog.json"];
}

- (NSString *)guestToolsDirectory {
    return ClassicGuestToolsDirectory();
}

#pragma mark - Migration from Legacy Versions

- (void)migrateLegacyMachinesIfNeeded {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *legacyMachines = [[self appDocumentsPath] stringByAppendingPathComponent:@"Machines"];
    NSString *legacyStates = [[self appDocumentsPath] stringByAppendingPathComponent:@"MachineStates"];

    if ([defaults boolForKey:@"ClassicTouchMigratedLegacy_v1"] && ![fm fileExistsAtPath:legacyMachines]) {
        return;
    }

    if ([fm fileExistsAtPath:legacyMachines]) {
        NSArray *subs = [fm contentsOfDirectoryAtPath:legacyMachines error:nil];
        for (NSString *sub in subs) {
            NSString *oldBase = [legacyMachines stringByAppendingPathComponent:sub];
            NSString *targetBase = [[self basesDirectory] stringByAppendingPathComponent:sub];

            // Move legacy machine base to Bases/
            if (![fm fileExistsAtPath:targetBase]) {
                [fm moveItemAtPath:oldBase toPath:targetBase error:nil];
            }

            // Create initial container in Containers/
            NSString *cDir = [[self containersDirectory] stringByAppendingPathComponent:sub];
            if (![fm fileExistsAtPath:cDir]) {
                [fm createDirectoryAtPath:cDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *cState = [cDir stringByAppendingPathComponent:@"state"];

                // Move old state if exists
                NSString *oldState = [legacyStates stringByAppendingPathComponent:sub];
                if ([fm fileExistsAtPath:oldState]) {
                    [fm moveItemAtPath:oldState toPath:cState error:nil];
                } else {
                    [fm createDirectoryAtPath:cState withIntermediateDirectories:YES attributes:nil error:nil];
                }

                VMContainer *mc = [[VMContainer alloc] init];
                mc.containerId = sub;
                mc.name = [self humanReadableNameForId:sub];
                mc.baseId = sub;
                mc.productType = [self productTypeForId:sub];
                mc.createdAt = [[NSDate date] timeIntervalSince1970];
                [mc saveMetadataWithRoot:[self containersDirectory]];
            }
        }
    }
    [defaults setBool:YES forKey:@"ClassicTouchMigratedLegacy_v1"];
}

#pragma mark - Catalog & Async Startup Loading

- (void)performInitialStartupLoad {
    if (self.isCatalogLoading || self.isCatalogLoaded) return;
    self.isCatalogLoading = YES;
    __weak typeof(self) weakSelf = self;

    // Phase 1 (immediate UI): scan containers & BootROM status first without waiting for 1.24MB JSON or guest-tools copy.
    dispatch_async(self.startupQueue, ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s ensureBaseDirectoriesExist];
        [s migrateLegacyMachinesIfNeeded];
        NSMutableArray<VMContainer *> *containers = [s scanContainersFromDisk];
        NSDictionary<NSString *, NSString *> *roms = [s scanInstalledBootromsFromDisk];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) ms = weakSelf;
            if (!ms) return;
            ms.containers = containers;
            ms.cachedBootromPaths = [roms mutableCopy];
            ms.hasLoadedBootromCache = YES;
            ms.hasCompletedInitialLoad = YES;
            [ms updateRomButtonState];
            [ms.tableView reloadData];
        });
    });

    // Phase 2 (parallel background): parse firmware-catalog.json once for device wizard / IPSW matching.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        NSArray<CatalogEntry *> *entries = [s loadCatalogEntriesFromDisk];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) ms = weakSelf;
            if (!ms) return;
            ms.catalogEntries = entries;
            ms.isCatalogLoaded = YES;
            ms.isCatalogLoading = NO;

            NSArray<void(^)(void)> *waiters = [ms.catalogWaiters copy];
            [ms.catalogWaiters removeAllObjects];
            for (void (^waiter)(void) in waiters) {
                waiter();
            }
        });
    });

    // Phase 3 (low priority): sync Documents/guest-tools only when app bundle version changes.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s syncGuestToolsIfNeeded];
    });
}

- (void)ensureCatalogLoadedThen:(void(^)(void))completion {
    if (!completion) return;
    if (self.isCatalogLoaded) {
        completion();
        return;
    }
    [self.catalogWaiters addObject:[completion copy]];
    if (!self.isCatalogLoading) {
        [self performInitialStartupLoad];
    }
}

- (NSArray<CatalogEntry *> *)loadCatalogEntriesFromDisk {
    NSString *path = [self catalogFilePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @[];

    NSError *err = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!json || ![json isKindOfClass:[NSDictionary class]]) return @[];

    NSArray *entries = json[@"entries"];
    if (!entries || ![entries isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray<CatalogEntry *> *list = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *d in entries) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        CatalogEntry *ce = [[CatalogEntry alloc] init];
        ce.entryId = d[@"id"];
        ce.board = d[@"board"];
        ce.productType = d[@"product_type"];
        ce.version = d[@"version"];
        ce.build = d[@"build"];
        ce.platform = @"ios";

        NSDictionary *recipe = d[@"recipe"];
        if ([recipe isKindOfClass:[NSDictionary class]]) {
            ce.rtcEpoch = [recipe[@"rtc_epoch"] longLongValue];
        }

        NSDictionary *src = d[@"source"];
        if ([src isKindOfClass:[NSDictionary class]]) {
            ce.url = src[@"url"];
            ce.sha1 = src[@"sha1"];
            ce.bytes = [src[@"bytes"] longLongValue];
            NSArray *mirrors = src[@"mirrors"];
            if ([mirrors isKindOfClass:[NSArray class]] && mirrors.count > 0) {
                NSDictionary *m = mirrors.firstObject;
                ce.fallbackUrl = m[@"url"];
            }
        }
        [list addObject:ce];
    }

    NSString *androidCatalogPath = [[NSBundle mainBundle] pathForResource:@"android-catalog" ofType:@"json"];
    if (!androidCatalogPath) {
        androidCatalogPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"android-catalog.json"];
    }
    NSData *aData = androidCatalogPath ? [NSData dataWithContentsOfFile:androidCatalogPath] : nil;
    NSDictionary *aJson = aData ? [NSJSONSerialization JSONObjectWithData:aData options:0 error:nil] : nil;
    NSArray *aEntries = [aJson isKindOfClass:[NSDictionary class]] ? aJson[@"entries"] : nil;
    if ([aEntries isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in aEntries) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            CatalogEntry *ce = [[CatalogEntry alloc] init];
            ce.entryId = d[@"id"];
            ce.board = d[@"board"] ?: @"goldfish";
            ce.productType = @"AndroidARMv7";
            ce.version = d[@"version"];
            ce.variant = d[@"variant"] ?: @"aosp";
            NSString *codename = d[@"codename"] ?: @"";
            NSString *varLabel = [ce.variant isEqualToString:@"google_apis"] ? @"Google APIs" : @"AOSP";
            ce.build = codename.length > 0 ? [NSString stringWithFormat:@"%@ • %@", codename, varLabel] : varLabel;
            ce.platform = @"android";
            ce.cpu = d[@"cpu"] ?: @"cortex-a8";
            ce.cmdline = d[@"cmdline"];
            ce.ramMB = [d[@"ram_mb"] intValue] > 0 ? [d[@"ram_mb"] intValue] : 512;
            ce.apiLevel = [d[@"api_level"] intValue];
            ce.lcdWidth = [d[@"width"] intValue];
            ce.lcdHeight = [d[@"height"] intValue];
            ce.lcdDensity = [d[@"dpi"] intValue];
            ce.url = d[@"url"];
            ce.sha1 = d[@"sha1"];
            ce.bytes = [d[@"size"] longLongValue];
            [list addObject:ce];
        }
    }

    NSString *fxosCatalogPath = [[NSBundle mainBundle] pathForResource:@"firefoxos-catalog" ofType:@"json"];
    if (!fxosCatalogPath) {
        fxosCatalogPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"firefoxos-catalog.json"];
    }
    NSData *fData = fxosCatalogPath ? [NSData dataWithContentsOfFile:fxosCatalogPath] : nil;
    NSDictionary *fJson = fData ? [NSJSONSerialization JSONObjectWithData:fData options:0 error:nil] : nil;
    NSArray *fEntries = [fJson isKindOfClass:[NSDictionary class]] ? fJson[@"entries"] : nil;
    if ([fEntries isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in fEntries) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            CatalogEntry *ce = [[CatalogEntry alloc] init];
            ce.entryId = d[@"id"];
            ce.board = d[@"board"] ?: @"goldfish";
            ce.productType = @"FirefoxOSARMv7";
            ce.version = d[@"version"];
            ce.variant = d[@"variant"] ?: @"b2g";
            ce.build = d[@"codename"] ?: @"B2G";
            ce.platform = @"firefoxos";
            ce.cpu = d[@"cpu"] ?: @"cortex-a8";
            ce.cmdline = d[@"cmdline"];
            ce.ramMB = [d[@"ram_mb"] intValue] > 0 ? [d[@"ram_mb"] intValue] : 768;
            ce.apiLevel = [d[@"api_level"] intValue] > 0 ? [d[@"api_level"] intValue] : 19;
            ce.lcdWidth = [d[@"width"] intValue];
            ce.lcdHeight = [d[@"height"] intValue];
            ce.lcdDensity = [d[@"dpi"] intValue];
            ce.url = d[@"url"];
            ce.sha1 = d[@"sha1"];
            ce.b2gBytes = [d[@"size"] longLongValue];
            ce.gaiaUrl = d[@"gaia_url"];
            ce.gaiaSha1 = d[@"gaia_sha1"];
            ce.gaiaBytes = [d[@"gaia_size"] longLongValue];
            ce.gonkUrl = d[@"gonk_url"];
            ce.gonkSha1 = d[@"gonk_sha1"];
            ce.gonkBytes = [d[@"gonk_size"] longLongValue];
            ce.bytes = ce.b2gBytes + ce.gaiaBytes;
            [list addObject:ce];
        }
    }

    NSString *winrtCatalogPath = [[NSBundle mainBundle] pathForResource:@"winrt-catalog" ofType:@"json"];
    if (!winrtCatalogPath) {
        winrtCatalogPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"winrt-catalog.json"];
    }
    NSData *wData = winrtCatalogPath ? [NSData dataWithContentsOfFile:winrtCatalogPath] : nil;
    NSDictionary *wJson = wData ? [NSJSONSerialization JSONObjectWithData:wData options:0 error:nil] : nil;
    NSArray *wEntries = [wJson isKindOfClass:[NSDictionary class]] ? wJson[@"entries"] : nil;
    if ([wEntries isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in wEntries) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            CatalogEntry *ce = [[CatalogEntry alloc] init];
            ce.entryId = d[@"id"];
            ce.board = d[@"board"] ?: @"virt";
            ce.productType = d[@"product_type"] ?: @"WinRTARMv7";
            ce.version = d[@"version"] ?: @"8.1";
            ce.build = d[@"codename"] ?: @"ARM32 UEFI";
            ce.platform = @"winrt";
            ce.cpu = d[@"cpu"] ?: @"cortex-a15";
            ce.ramMB = [d[@"ram_mb"] intValue] > 0 ? [d[@"ram_mb"] intValue] : 1024;
            ce.diskGB = [d[@"disk_gb"] intValue] >= 32 ? [d[@"disk_gb"] intValue] : 32;
            ce.lcdWidth = [d[@"width"] intValue] > 0 ? [d[@"width"] intValue] : 1024;
            ce.lcdHeight = [d[@"height"] intValue] > 0 ? [d[@"height"] intValue] : 768;
            ce.rtcDate = [d[@"rtc_date"] isKindOfClass:[NSString class]] ? d[@"rtc_date"] : @"2013-07-15";
            [list addObject:ce];
        }
    }

    NSString *chromeosCatalogPath = [[NSBundle mainBundle] pathForResource:@"chromeos-catalog" ofType:@"json"];
    if (!chromeosCatalogPath) {
        chromeosCatalogPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"chromeos-catalog.json"];
    }
    NSData *chromeosData = chromeosCatalogPath ? [NSData dataWithContentsOfFile:chromeosCatalogPath] : nil;
    NSDictionary *chromeosRoot = chromeosData ? [NSJSONSerialization JSONObjectWithData:chromeosData options:0 error:nil] : nil;
    NSArray *chromeosEntries = [chromeosRoot isKindOfClass:[NSDictionary class]] ? chromeosRoot[@"entries"] : nil;
    if ([chromeosEntries isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in chromeosEntries) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            CatalogEntry *ce = [[CatalogEntry alloc] init];
            ce.entryId = d[@"id"];
            ce.board = d[@"board"] ?: @"virt";
            ce.productType = d[@"product_type"] ?: @"ChromeOSARMv7";
            ce.version = d[@"version"] ?: @"R40";
            ce.build = d[@"codename"] ?: @"Chrome OS R40 (ARM32)";
            ce.platform = @"chromeos";
            ce.cpu = d[@"cpu"] ?: @"cortex-a15";
            ce.ramMB = [d[@"ram_mb"] intValue] > 0 ? [d[@"ram_mb"] intValue] : 1536;
            ce.diskGB = [d[@"disk_gb"] intValue] >= 16 ? [d[@"disk_gb"] intValue] : 16;
            ce.lcdWidth = [d[@"width"] intValue] > 0 ? [d[@"width"] intValue] : 1024;
            ce.lcdHeight = [d[@"height"] intValue] > 0 ? [d[@"height"] intValue] : 768;
            ce.rtcDate = [d[@"rtc_date"] isKindOfClass:[NSString class]] ? d[@"rtc_date"] : @"today";
            ce.url = [d[@"url"] isKindOfClass:[NSString class]] ? d[@"url"] : nil;
            ce.bytes = [d[@"bytes"] longLongValue];
            [list addObject:ce];
        }
    }

    NSString *utCatalogPath = [[NSBundle mainBundle] pathForResource:@"ubuntutouch-catalog" ofType:@"json"];
    if (!utCatalogPath) {
        utCatalogPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"ubuntutouch-catalog.json"];
    }
    NSData *utData = utCatalogPath ? [NSData dataWithContentsOfFile:utCatalogPath] : nil;
    NSDictionary *utRoot = utData ? [NSJSONSerialization JSONObjectWithData:utData options:0 error:nil] : nil;
    NSArray *utEntries = [utRoot isKindOfClass:[NSDictionary class]] ? utRoot[@"entries"] : nil;
    if ([utEntries isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in utEntries) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            CatalogEntry *ce = [[CatalogEntry alloc] init];
            ce.entryId = d[@"id"];
            ce.board = d[@"board"] ?: @"virt";
            ce.productType = d[@"product_type"] ?: @"UbuntuTouchVirtARMv7";
            ce.version = d[@"version"] ?: @"15.04";
            ce.build = d[@"codename"] ?: @"Ubuntu Touch (Virt)";
            ce.platform = @"ubuntutouch";
            ce.cpu = d[@"cpu"] ?: @"cortex-a15";
            ce.ramMB = [d[@"ram_mb"] intValue] > 0 ? [d[@"ram_mb"] intValue] : 1536;
            ce.diskGB = [d[@"disk_gb"] intValue] >= 8 ? [d[@"disk_gb"] intValue] : 16;
            ce.lcdWidth = [d[@"width"] intValue] > 0 ? [d[@"width"] intValue] : 544;
            ce.lcdHeight = [d[@"height"] intValue] > 0 ? [d[@"height"] intValue] : 960;
            ce.rtcDate = @"today";
            ce.url = [d[@"url"] isKindOfClass:[NSString class]] ? d[@"url"] : nil;
            ce.bytes = [d[@"bytes"] longLongValue];
            ce.overlayBytes = [d[@"overlay_bytes"] longLongValue];
            if ([d[@"overlay_urls"] isKindOfClass:[NSArray class]]) {
                NSMutableArray<NSString *> *urls = [NSMutableArray array];
                for (id item in (NSArray *)d[@"overlay_urls"]) {
                    if ([item isKindOfClass:[NSString class]] && ((NSString *)item).length > 0) {
                        [urls addObject:item];
                    }
                }
                ce.overlayUrls = urls;
            }
            [list addObject:ce];
        }
    }

    NSLog(@"[MainViewController] Loaded %lu catalog entries", (unsigned long)list.count);
    return [list copy];
}

- (void)loadCatalog {
    self.catalogEntries = [self loadCatalogEntriesFromDisk];
    self.isCatalogLoaded = YES;
}

#pragma mark - Scanning Containers & Firmwares

- (NSMutableArray<VMContainer *> *)scanContainersFromDisk {
    NSMutableArray<VMContainer *> *list = [NSMutableArray array];
    NSString *containersRoot = [self containersDirectory];
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:containersRoot error:nil];

    for (NSString *sub in dirs) {
        NSString *cDir = [containersRoot stringByAppendingPathComponent:sub];
        VMContainer *c = [VMContainer loadFromDirectory:cDir];
        if (c) {
            [list addObject:c];
        }
    }

    // Sort containers:
    // 1. If saved custom order exists, respect it.
    // 2. Otherwise / newly created containers: sort by creation date ascending (created first at top, newer at bottom).
    NSArray<NSString *> *savedOrder = [[NSUserDefaults standardUserDefaults] arrayForKey:@"ClassicTouchContainerOrder_v1"];
    NSMutableDictionary<NSString *, NSNumber *> *orderMap = [NSMutableDictionary dictionary];
    if (savedOrder) {
        for (NSUInteger i = 0; i < savedOrder.count; i++) {
            orderMap[savedOrder[i]] = @(i);
        }
    }

    [list sortUsingComparator:^NSComparisonResult(VMContainer *a, VMContainer *b) {
        NSNumber *oa = orderMap[a.containerId];
        NSNumber *ob = orderMap[b.containerId];
        if (oa && ob) {
            return [oa compare:ob];
        }
        if (oa && !ob) {
            return NSOrderedAscending;
        }
        if (!oa && ob) {
            return NSOrderedDescending;
        }
        if (a.createdAt < b.createdAt) return NSOrderedAscending;
        if (a.createdAt > b.createdAt) return NSOrderedDescending;
        return [a.name compare:b.name];
    }];

    return list;
}

- (void)saveCustomContainerOrder {
    NSMutableArray<NSString *> *order = [NSMutableArray arrayWithCapacity:self.containers.count];
    for (VMContainer *c in self.containers) {
        if (c.containerId.length > 0) {
            [order addObject:c.containerId];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:order forKey:@"ClassicTouchContainerOrder_v1"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)scanContainers {
    self.containers = [self scanContainersFromDisk];
    [self.tableView reloadData];
}

- (NSArray<NSString *> *)ipswSearchDirectories {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *docs = [self appDocumentsPath];
    NSArray<NSString *> *candidates = @[
        [self firmwaresDirectory] ?: @"",
        [self legacyIPSWDirectory] ?: @"",
        docs ?: @"",
        docs ? [docs stringByAppendingPathComponent:@"Downloads"] : @"",
        docs ? [docs stringByAppendingPathComponent:@"Inbox"] : @""
    ];
    for (NSString *raw in candidates) {
        if (raw.length == 0) continue;
        NSString *norm = [raw stringByStandardizingPath];
        if (![seen containsObject:norm]) {
            [seen addObject:norm];
            [dirs addObject:raw];
        }
    }
    return dirs;
}

- (nullable CatalogEntry *)catalogEntryMatchingIPSWFilename:(NSString *)fileName {
    if (fileName.length == 0) return nil;
    NSString *lowerFile = fileName.lowercaseString;
    NSString *stem = [lowerFile hasSuffix:@".tar.gz"]
        ? [fileName substringToIndex:fileName.length - 7]
        : [fileName stringByDeletingPathExtension];
    NSString *lowerStem = stem.lowercaseString;

    for (CatalogEntry *ce in self.catalogEntries) {
        if ([ce.entryId isEqualToString:stem] || [ce.entryId.lowercaseString isEqualToString:lowerStem]) {
            return ce;
        }
    }
    for (CatalogEntry *ce in self.catalogEntries) {
        NSString *urlName = ce.url.lastPathComponent.lowercaseString;
        if (urlName.length > 0 && [urlName isEqualToString:lowerFile]) {
            return ce;
        }
    }
    for (CatalogEntry *ce in self.catalogEntries) {
        if (ce.build.length > 0 && [lowerFile containsString:@"_restore.ipsw"]) {
            NSString *buildToken = [NSString stringWithFormat:@"_%@_", ce.build.lowercaseString];
            if ([lowerFile containsString:buildToken]) {
                return ce;
            }
        }
    }
    return nil;
}

- (nullable NSString *)findExistingGonkBaseZip {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [self ipswSearchDirectories]) {
        for (NSString *name in @[@"android-19-aosp.zip", @"armeabi-v7a-19_r05.zip"]) {
            NSString *candidate = [dir stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:candidate]) return candidate;
        }
    }
    return nil;
}

- (nullable NSString *)findExistingGaiaZipForEntryId:(NSString *)entryId {
    if (entryId.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *gaiaName = [NSString stringWithFormat:@"%@-gaia.zip", entryId];
    for (NSString *dir in [self ipswSearchDirectories]) {
        NSString *candidate = [dir stringByAppendingPathComponent:gaiaName];
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

- (nullable NSString *)findExistingB2GTarForEntryId:(NSString *)entryId {
    if (entryId.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tarName = [NSString stringWithFormat:@"%@.tar.gz", entryId];
    for (NSString *dir in [self ipswSearchDirectories]) {
        NSString *candidate = [dir stringByAppendingPathComponent:tarName];
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }
    CatalogEntry *ce = [self catalogEntryWithId:entryId];
    NSString *urlName = ce.url.lastPathComponent;
    if (urlName.length > 0) {
        for (NSString *dir in [self ipswSearchDirectories]) {
            NSString *candidate = [dir stringByAppendingPathComponent:urlName];
            if ([fm fileExistsAtPath:candidate]) return candidate;
        }
    }
    return nil;
}

- (int64_t)remainingDownloadBytesForEntry:(CatalogEntry *)ce {
    if ([ce.platform isEqualToString:@"firefoxos"]) {
        int64_t total = 0;
        if (![self findExistingGonkBaseZip]) total += ce.gonkBytes;
        if (![self findExistingGaiaZipForEntryId:ce.entryId]) total += ce.gaiaBytes;
        if (![self findExistingB2GTarForEntryId:ce.entryId]) total += (ce.b2gBytes > 0 ? ce.b2gBytes : ce.bytes);
        return total > 0 ? total : ce.bytes;
    }
    if ([ce.platform isEqualToString:@"ubuntutouch"]) {
        int64_t total = [self findExistingIPSWForEntryId:ce.entryId] ? 0 : ce.bytes;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *overlaysDir = [[[self firmwaresDirectory] stringByAppendingPathComponent:@"ut-overlays"] stringByAppendingPathComponent:(ce.entryId ?: @"ut")];
        BOOL allOverlaysReady = (ce.overlayUrls.count > 0);
        for (NSString *urlStr in ce.overlayUrls) {
            NSString *p = [overlaysDir stringByAppendingPathComponent:[NSURL URLWithString:urlStr].lastPathComponent ?: @""];
            NSDictionary *attrs = [fm attributesOfItemAtPath:p error:nil];
            if (!attrs || [attrs fileSize] == 0) {
                allOverlaysReady = NO;
                break;
            }
        }
        if (!allOverlaysReady) {
            total += ce.overlayBytes;
        }
        return total > 0 ? total : (ce.bytes + ce.overlayBytes);
    }
    return ce.bytes;
}

- (NSArray<FirmwareFile *> *)scanDownloadedFirmwares {
    NSMutableArray<FirmwareFile *> *res = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *searchDirs = [self ipswSearchDirectories];

    NSMutableSet<NSString *> *seenFiles = [NSMutableSet set];
    NSMutableSet<NSString *> *seenEntryIds = [NSMutableSet set];
    for (NSString *dir in searchDirs) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            if ([f hasPrefix:@"."]) continue;
            BOOL isTarGz = [f.lowercaseString hasSuffix:@".tar.gz"];
            NSString *ext = isTarGz ? @"tar.gz" : f.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"ipsw"] && ![ext isEqualToString:@"zip"] && !isTarGz) continue;
            if ([seenFiles containsObject:f.lowercaseString]) continue;

            NSString *full = [dir stringByAppendingPathComponent:f];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (!attrs || [attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;

            NSString *stem = isTarGz ? [f substringToIndex:f.length - 7] : [f stringByDeletingPathExtension];
            CatalogEntry *matched = [self catalogEntryMatchingIPSWFilename:f];
            if (!matched) {
                matched = [self loadCustomCatalogEntryForId:stem];
            }
            if ([ext isEqualToString:@"zip"] && (!matched || ![matched.platform isEqualToString:@"android"])) {
                continue;
            }
            if (isTarGz) {
                if (!matched || (![matched.platform isEqualToString:@"firefoxos"] && ![matched.platform isEqualToString:@"ubuntutouch"])) {
                    continue;
                }
                if ([matched.platform isEqualToString:@"firefoxos"] &&
                    (![self findExistingGonkBaseZip] || ![self findExistingGaiaZipForEntryId:matched.entryId])) {
                    continue;
                }
            }
            NSString *entryId = matched ? matched.entryId : stem;
            if ([seenEntryIds containsObject:entryId]) continue;

            [seenFiles addObject:f.lowercaseString];
            [seenEntryIds addObject:entryId];

            FirmwareFile *ff = [[FirmwareFile alloc] init];
            ff.fileName = f;
            ff.filePath = full;
            ff.entryId = entryId;
            ff.fileSizeBytes = (isTarGz && matched.bytes > 0) ? matched.bytes : attrs.fileSize;
            ff.platform = matched.platform ?: ([entryId hasPrefix:@"chromeos-"] ? @"chromeos" : ([entryId hasPrefix:@"ut-virt-"] ? @"ubuntutouch" : ([entryId hasPrefix:@"fxos-"] ? @"firefoxos" : ([entryId hasPrefix:@"android-"] ? @"android" : @"ios"))));
            if (matched) {
                ff.version = matched.version;
                ff.build = matched.build;
                ff.productType = matched.productType;
            }
            [res addObject:ff];
        }
    }
    return [res copy];
}

- (nullable NSString *)findExistingIPSWForEntryId:(NSString *)entryId {
    if (entryId.length == 0) return nil;
    if ([entryId hasPrefix:@"fxos-"]) {
        NSString *gonk = [self findExistingGonkBaseZip];
        NSString *gaia = [self findExistingGaiaZipForEntryId:entryId];
        NSString *b2g = [self findExistingB2GTarForEntryId:entryId];
        if (gonk && gaia && b2g) {
            return b2g;
        }
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *searchDirs = [self ipswSearchDirectories];
    NSString *exactIpsw = [NSString stringWithFormat:@"%@.ipsw", entryId];
    NSString *exactZip = [NSString stringWithFormat:@"%@.zip", entryId];
    NSString *exactTarGz = [NSString stringWithFormat:@"%@.tar.gz", entryId];
    for (NSString *dir in searchDirs) {
        NSString *candidateIpsw = [dir stringByAppendingPathComponent:exactIpsw];
        if ([fm fileExistsAtPath:candidateIpsw]) return candidateIpsw;
        NSString *candidateZip = [dir stringByAppendingPathComponent:exactZip];
        if ([fm fileExistsAtPath:candidateZip]) return candidateZip;
        NSString *candidateTarGz = [dir stringByAppendingPathComponent:exactTarGz];
        if ([fm fileExistsAtPath:candidateTarGz]) return candidateTarGz;
    }

    CatalogEntry *ce = [self catalogEntryWithId:entryId];
    NSString *urlName = ce.url.lastPathComponent;
    if (urlName.length > 0) {
        for (NSString *dir in searchDirs) {
            NSString *candidate = [dir stringByAppendingPathComponent:urlName];
            if ([fm fileExistsAtPath:candidate]) return candidate;
        }
    }

    for (FirmwareFile *ff in [self scanDownloadedFirmwares]) {
        if ([ff.entryId isEqualToString:entryId] && ff.filePath.length > 0 && [fm fileExistsAtPath:ff.filePath]) {
            return ff.filePath;
        }
    }
    return nil;
}

- (BOOL)isBasePrepV11OrStableReady:(NSString *)baseDir entryId:(NSString *)entryId {
    NSString *lockPath = [baseDir stringByAppendingPathComponent:@"device.lock.json"];
    NSData *data = [NSData dataWithContentsOfFile:lockPath];
    if (!data) return NO;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return NO;

    NSString *rawEntryId = [entryId hasSuffix:@"-jb"]
        ? [entryId substringToIndex:entryId.length - 3]
        : entryId;
    CatalogEntry *ce = [self catalogEntryWithId:rawEntryId];
    if (ce && ce.rtcEpoch > 0) {
        NSDictionary *mach = [json[@"machine"] isKindOfClass:[NSDictionary class]] ? json[@"machine"] : nil;
        if (!mach[@"rtc-epoch"]) {
            return NO;
        }
    }
    if (([entryId hasPrefix:@"m68ap-5"] || [entryId hasPrefix:@"m68ap-7"] ||
         [entryId hasPrefix:@"n45ap-5"] || [entryId hasPrefix:@"n45ap-7"]) &&
        ![json[@"prep_v15"] boolValue]) {
        return NO;
    }
    if ([entryId hasPrefix:@"k48ap-"] && ![json[@"prep_v14"] boolValue]) {
        return NO;
    }
    if ([json[@"prep_v15"] boolValue] || [json[@"prep_v14"] boolValue] || [json[@"prep_v13"] boolValue]) {
        return YES;
    }
    BOOL isK48Ios4Plus = ([entryId hasPrefix:@"k48ap-"] ||
                          [entryId hasPrefix:@"n81ap-"] ||
                          [entryId hasPrefix:@"n90ap-"] ||
                          [entryId hasPrefix:@"n88ap-8"] ||
                          [entryId hasPrefix:@"n88ap-9"] ||
                          [entryId hasPrefix:@"n88ap-10"] ||
                          [entryId hasPrefix:@"n18ap-8"] ||
                          [entryId hasPrefix:@"n18ap-9"]);
    if (isK48Ios4Plus) {
        return NO;
    }
    if ([json[@"prep_v12"] boolValue]) {
        return YES;
    }
    if ([entryId hasPrefix:@"n42ap-"]) {
        return NO;
    }
    // Pre-v3 stable bases (built with macOS OpenGLES e5a72f95...) remain valid without rebuild;
    // bases built in v3/v4 (with __la_symbol_ptr OpenGLES or v4 sandbox_patch) are rebuilt automatically.
    NSDictionary *tool = [json[@"tool"] isKindOfClass:[NSDictionary class]] ? json[@"tool"] : nil;
    NSDictionary *built = [tool[@"built"] isKindOfClass:[NSDictionary class]] ? tool[@"built"] : nil;
    NSDictionary *gt = [built[@"guest tools"] isKindOfClass:[NSDictionary class]] ? built[@"guest tools"] : nil;
    NSString *oglSha = [gt[@"OpenGLES"] isKindOfClass:[NSString class]] ? gt[@"OpenGLES"]
                     : ([built[@"OpenGLES"] isKindOfClass:[NSString class]] ? built[@"OpenGLES"] : nil);
    if ([oglSha isEqualToString:@"e5a72f95c31227e0abb5ad114d36553ec2859736735eb4ef2a775a0011e53c4b"] ||
        [oglSha isEqualToString:@"aef482c571907eb65277be0037959c571e4d8f54166ca9ace6e24b1fb5b821e6"]) {
        return YES;
    }
    return NO;
}

- (BOOL)isFirefoxOSBasePrepV2Ready:(NSString *)baseDir entryId:(NSString *)entryId {
    NSString *metaPath = [baseDir stringByAppendingPathComponent:@"android-metadata.json"];
    NSData *data = [NSData dataWithContentsOfFile:metaPath];
    if (!data) return NO;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return NO;
    NSInteger minVersion = [entryId hasPrefix:@"fxos-2.6"] ? 6 : 3;
    return [json[@"fxos_prep_version"] integerValue] >= minVersion;
}

- (BOOL)hasPreparedBaseForEntryId:(NSString *)entryId {
    if ([entryId hasPrefix:@"winrt-"] || [entryId hasPrefix:@"chromeos-"]) {
        return YES;
    }
    NSString *base = [[self basesDirectory] stringByAppendingPathComponent:entryId];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([entryId hasPrefix:@"ut-virt-"]) {
        return [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"rootfs.ext4"]] &&
               [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"virt-metadata.json"]];
    }
    if ([entryId hasPrefix:@"android-"] || [entryId hasPrefix:@"fxos-"] ||
        [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"kernel-qemu"]]) {
        BOOL hasImages = [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"kernel-qemu"]] &&
                         [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"ramdisk.img"]] &&
                         [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"system.img"]] &&
                         [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"userdata.img"]];
        if (!hasImages) return NO;
        if ([entryId hasPrefix:@"fxos-"] && ![self isFirefoxOSBasePrepV2Ready:base entryId:entryId]) {
            return NO;
        }
        return YES;
    }
    BOOL hasLock = [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"device.lock.json"]] ||
                   [fm fileExistsAtPath:[base stringByAppendingPathComponent:@"lock.json"]];
    if (!hasLock) return NO;
    if (![self isBasePrepV11OrStableReady:base entryId:entryId]) {
        return NO;
    }
    return YES;
}

#pragma mark - BootROM State

- (nullable NSString *)requiredBootromTypeForIdentifier:(NSString *)identifier {
    if (!identifier.length) return nil;
    if ([identifier containsString:@"m68"] || [identifier containsString:@"iPhone1,1"] ||
        [identifier containsString:@"n45"] || [identifier containsString:@"iPod1,1"]) {
        NSString *base = [[self basesDirectory] stringByAppendingPathComponent:identifier];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[base stringByAppendingPathComponent:@"kboot.bin"]]) {
            return nil;
        }
        NSRange dash = [identifier rangeOfString:@"-"];
        if (dash.location != NSNotFound && dash.location + 1 < identifier.length) {
            unichar buildLead = [identifier characterAtIndex:dash.location + 1];
            if (buildLead == '5' || buildLead == '7') {
                return nil;
            }
        }
        return @"s5l8900";
    }
    return nil;
}

- (nullable NSString *)scanPathForInstalledBootromTypeOnDisk:(NSString *)romType {
    if (![romType isEqualToString:@"s5l8900"]) return nil;
    NSString *docs = [self appDocumentsPath];
    NSString *romsDir = [docs stringByAppendingPathComponent:@"bootroms"];
    NSArray<NSString *> *names = @[@"bootrom_s5l8900", @"bootrom_s5l8900.bin", @"s5l8900.bin", @"s5l8900-bootrom.bin", @"bootrom.bin"];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[docs, romsDir]) {
        for (NSString *name in names) {
            NSString *p = [dir stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:p] && ClassicBootromFileMatchesExpectedType(p, romType)) {
                return p;
            }
        }
    }
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)scanInstalledBootromsFromDisk {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    NSString *s5l8900 = [self scanPathForInstalledBootromTypeOnDisk:@"s5l8900"];
    if (s5l8900) map[@"s5l8900"] = s5l8900;
    return [map copy];
}

- (void)invalidateBootromCache {
    [self.cachedBootromPaths removeAllObjects];
    self.hasLoadedBootromCache = YES;
}

- (nullable NSString *)pathForInstalledBootromType:(NSString *)romType {
    if (!romType.length) return nil;
    if (self.hasLoadedBootromCache) {
        return self.cachedBootromPaths[romType];
    }
    return [self scanPathForInstalledBootromTypeOnDisk:romType];
}

- (BOOL)hasInstalledBootromForIdentifier:(NSString *)identifier {
    NSString *romType = [self requiredBootromTypeForIdentifier:identifier];
    if (!romType) return YES;
    return [self pathForInstalledBootromType:romType] != nil;
}

- (BOOL)hasInstalledBootrom {
    return ([self pathForInstalledBootromType:@"s5l8900"] != nil);
}

- (void)updateRomButtonState {
    BOOL installed = [self hasInstalledBootrom];
    UIImageSymbolConfiguration *symConfig = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightMedium];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.image = [UIImage systemImageNamed:(installed ? @"cpu.fill" : @"cpu") withConfiguration:symConfig];
    cfg.title = @"ROM";
    cfg.imagePadding = 3.5;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 4.0, 4.0, 4.0);
    cfg.baseForegroundColor = installed ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    self.romNavButton.configuration = cfg;
    self.romNavButton.accessibilityLabel = installed ? L(@"bootrom_selected") : L(@"bootrom_unselected");
}

#pragma mark - Device & OS Names

- (NSString *)formattedOSVersion:(NSString *)version {
    return [self formattedOSVersion:version forPlatform:nil];
}

- (NSString *)formattedOSVersion:(NSString *)version forPlatform:(nullable NSString *)platform {
    if (!version || version.length == 0) return @"";
    if ([platform isEqualToString:@"winrt"]) {
        return [NSString stringWithFormat:@"Windows %@", version];
    }
    if ([platform isEqualToString:@"chromeos"]) {
        return [NSString stringWithFormat:@"Chrome OS %@", version];
    }
    if ([platform isEqualToString:@"ubuntutouch"]) {
        return [NSString stringWithFormat:@"Ubuntu Touch %@", version];
    }
    if ([platform isEqualToString:@"firefoxos"]) {
        return [NSString stringWithFormat:@"Firefox OS %@", version];
    }
    if ([platform isEqualToString:@"android"]) {
        return [NSString stringWithFormat:@"Android %@", version];
    }
    if ([version hasPrefix:@"1."] || [version isEqualToString:@"1"] ||
        [version hasPrefix:@"2."] || [version isEqualToString:@"2"] ||
        [version hasPrefix:@"3."] || [version isEqualToString:@"3"]) {
        return [NSString stringWithFormat:@"iPhone OS %@", version];
    }
    return [NSString stringWithFormat:@"iOS %@", version];
}

- (NSString *)humanReadableNameForId:(NSString *)sub {
    if ([sub hasPrefix:@"winrt-"] || [sub containsString:@"WinRTARMv7"]) {
        return L(@"device_winrt_arm");
    }
    if ([sub hasPrefix:@"chromeos-"] || [sub containsString:@"ChromeOSARMv7"]) {
        return L(@"device_chromeos_arm");
    }
    if ([sub hasPrefix:@"ut-virt-"] || [sub containsString:@"UbuntuTouchVirtARMv7"]) {
        return L(@"device_ubuntutouch_virt");
    }
    if ([sub hasPrefix:@"fxos-"] || [sub containsString:@"FirefoxOSARMv7"]) {
        return L(@"device_firefoxos_arm");
    }
    if ([sub hasPrefix:@"android-"] || [sub containsString:@"AndroidARMv7"] || [sub containsString:@"goldfish"]) {
        return L(@"device_android_arm");
    }
    if ([sub containsString:@"iPad1,1"] || [sub containsString:@"k48ap"]) return L(@"device_ipad_1g");
    if ([sub containsString:@"iPhone1,1"] || [sub containsString:@"m68ap"]) return L(@"device_iphone_2g");
    if ([sub containsString:@"iPhone2,1"] || [sub containsString:@"n88ap"]) return L(@"device_iphone_3gs");
    if ([sub containsString:@"iPhone3,1"] || [sub containsString:@"n90ap"]) return L(@"device_iphone_4");
    if ([sub containsString:@"iPhone5,2"] || [sub containsString:@"iPhone5,1"] || [sub containsString:@"n42ap"]) return L(@"device_iphone_5");
    if ([sub containsString:@"iPod1,1"] || [sub containsString:@"n45ap"]) return L(@"device_ipod_1g");
    if ([sub containsString:@"iPod3,1"] || [sub containsString:@"n18ap"]) return L(@"device_ipod_3g");
    if ([sub containsString:@"iPod4,1"] || [sub containsString:@"n81ap"]) return L(@"device_ipod_4g");
    return sub;
}

- (NSString *)productTypeForId:(NSString *)sub {
    if ([sub hasPrefix:@"winrt-"] || [sub containsString:@"WinRTARMv7"]) return @"WinRTARMv7";
    if ([sub hasPrefix:@"chromeos-"] || [sub containsString:@"ChromeOSARMv7"]) return @"ChromeOSARMv7";
    if ([sub hasPrefix:@"ut-virt-"] || [sub containsString:@"UbuntuTouchVirtARMv7"]) return @"UbuntuTouchVirtARMv7";
    if ([sub hasPrefix:@"fxos-"] || [sub containsString:@"FirefoxOSARMv7"]) return @"FirefoxOSARMv7";
    if ([sub hasPrefix:@"android-"] || [sub containsString:@"AndroidARMv7"] || [sub containsString:@"goldfish"]) return @"AndroidARMv7";
    if ([sub containsString:@"iPad1,1"] || [sub containsString:@"k48ap"]) return @"iPad1,1";
    if ([sub containsString:@"iPhone1,1"] || [sub containsString:@"m68ap"]) return @"iPhone1,1";
    if ([sub containsString:@"iPhone2,1"] || [sub containsString:@"n88ap"]) return @"iPhone2,1";
    if ([sub containsString:@"iPhone3,1"] || [sub containsString:@"n90ap"]) return @"iPhone3,1";
    if ([sub containsString:@"iPhone5,2"] || [sub containsString:@"iPhone5,1"] || [sub containsString:@"n42ap"]) return @"iPhone5,2";
    if ([sub containsString:@"iPod1,1"] || [sub containsString:@"n45ap"]) return @"iPod1,1";
    if ([sub containsString:@"iPod3,1"] || [sub containsString:@"n18ap"]) return @"iPod3,1";
    if ([sub containsString:@"iPod4,1"] || [sub containsString:@"n81ap"]) return @"iPod4,1";
    return @"";
}

#pragma mark - Step-by-Step Creation Wizard (端末 -> OS -> コンテナ名)

- (BOOL)supportsCydiaForEntry:(CatalogEntry *)entry {
    if ([entry.platform isEqualToString:@"android"] || [entry.platform isEqualToString:@"firefoxos"] ||
        [entry.platform isEqualToString:@"winrt"] || [entry.platform isEqualToString:@"chromeos"] ||
        [entry.platform isEqualToString:@"ubuntutouch"]) {
        return NO;
    }
    NSString *pt = entry.productType ?: @"";
    NSString *eid = entry.entryId ?: @"";
    NSInteger major = [[entry.version componentsSeparatedByString:@"."].firstObject integerValue];
    if ([pt isEqualToString:@"iPhone5,2"] || [pt isEqualToString:@"iPhone5,1"] || [eid containsString:@"n42ap"]) {
        return major == 6;
    }
    BOOL supportedBoard = ([pt isEqualToString:@"iPhone2,1"] || [eid containsString:@"n88ap"] ||
                           [pt isEqualToString:@"iPhone3,1"] || [eid containsString:@"n90ap"] ||
                           [pt isEqualToString:@"iPod3,1"] || [eid containsString:@"n18ap"] ||
                           [pt isEqualToString:@"iPod4,1"] || [eid containsString:@"n81ap"] ||
                           [pt isEqualToString:@"iPad1,1"] || [eid containsString:@"k48ap"]);
    if (!supportedBoard) return NO;
    if ([entry.version isEqualToString:@"3.0"] || [entry.version hasPrefix:@"3.0."]) {
        return NO;
    }
    return major >= 3 && major <= 7;
}

- (void)presentDeviceCreationWizard:(id)sender {
    [_haptic impactOccurred];
    __weak typeof(self) weakSelf = self;
    [self ensureCatalogLoadedThen:^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s presentDeviceCreationWizardReady];
    }];
}

- (void)presentDeviceCreationWizardReady {
    // Step 1: Select Device Model
    UIAlertController *deviceSelect = [UIAlertController alertControllerWithTitle:L(@"wizard_select_device_title")
                                                                          message:L(@"wizard_select_device_prompt")
                                                                   preferredStyle:UIAlertControllerStyleActionSheet];

    NSDictionary *devices = @{
        L(@"device_iphone_2g_desc"): @"iPhone1,1",
        L(@"device_iphone_3gs_desc"): @"iPhone2,1",
        L(@"device_iphone_4_desc"): @"iPhone3,1",
        L(@"device_iphone_5_desc"): @"iPhone5,2",
        L(@"device_ipod_1g_desc"): @"iPod1,1",
        L(@"device_ipod_3g_desc"): @"iPod3,1",
        L(@"device_ipod_4g_desc"): @"iPod4,1",
        L(@"device_ipad_1g_desc"): @"iPad1,1",
        L(@"device_android_arm_desc"): @"AndroidARMv7",
        L(@"device_firefoxos_arm_desc"): @"FirefoxOSARMv7",
        L(@"device_winrt_arm_desc"): @"WinRTARMv7",
        L(@"device_chromeos_arm_desc"): @"ChromeOSARMv7",
        L(@"device_ubuntutouch_virt_desc"): @"UbuntuTouchVirtARMv7"
    };

    NSArray *deviceOrder = @[
        L(@"device_iphone_2g_desc"),
        L(@"device_iphone_3gs_desc"),
        L(@"device_iphone_4_desc"),
        L(@"device_iphone_5_desc"),
        L(@"device_ipod_1g_desc"),
        L(@"device_ipod_3g_desc"),
        L(@"device_ipod_4g_desc"),
        L(@"device_ipad_1g_desc"),
        L(@"device_android_arm_desc"),
        L(@"device_firefoxos_arm_desc"),
        L(@"device_winrt_arm_desc"),
        L(@"device_chromeos_arm_desc"),
        L(@"device_ubuntutouch_virt_desc")
    ];

    for (NSString *title in deviceOrder) {
        NSString *prodType = devices[title];
        [deviceSelect addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self showVersionPickerForProductType:prodType deviceTitle:title];
        }]];
    }

    [deviceSelect addAction:[UIAlertAction actionWithTitle:L(@"select_local_ipsw") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showDocumentPickerForIPSW];
    }]];

    [deviceSelect addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];

    if (deviceSelect.popoverPresentationController) {
        deviceSelect.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    }
    [self presentViewController:deviceSelect animated:YES completion:nil];
}

- (void)showVersionPickerForProductType:(NSString *)prodType deviceTitle:(NSString *)deviceTitle {
    // Step 2: Select OS Version for the chosen device
    NSMutableArray<CatalogEntry *> *filtered = [NSMutableArray array];
    for (CatalogEntry *ce in self.catalogEntries) {
        if ([ce.productType isEqualToString:prodType]) {
            [filtered addObject:ce];
        }
    }
    for (FirmwareFile *ff in [self scanDownloadedFirmwares]) {
        if ([ff.entryId hasPrefix:@"custom-"]) {
            CatalogEntry *customCe = [self catalogEntryWithId:ff.entryId];
            if (customCe && [customCe.productType isEqualToString:prodType]) {
                [filtered addObject:customCe];
            }
        }
    }

    UIAlertController *versionSelect = [UIAlertController alertControllerWithTitle:L(@"wizard_select_os_title")
                                                                           message:[NSString stringWithFormat:L(@"wizard_select_os_prompt_fmt"), deviceTitle]
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];

    for (CatalogEntry *ce in filtered) {
        NSString *btnTitle = nil;
        if ([ce.platform isEqualToString:@"winrt"] || [ce.platform isEqualToString:@"chromeos"]) {
            int defGB = [ce.platform isEqualToString:@"chromeos"] ? (ce.diskGB >= 16 ? ce.diskGB : 16) : (ce.diskGB >= 32 ? ce.diskGB : 32);
            btnTitle = [NSString stringWithFormat:@"%@ (%d GB QCOW2)", ce.build ?: @"ARM Desktop", defGB];
        } else {
            NSString *jbId = [NSString stringWithFormat:@"%@-jb", ce.entryId];
            BOOL baseExists = [self hasPreparedBaseForEntryId:ce.entryId];
            BOOL jbExists = [self hasPreparedBaseForEntryId:jbId];
            NSString *localIPSW = [self findExistingIPSWForEntryId:ce.entryId];

            NSString *tag = @"";
            if (baseExists && jbExists) {
                tag = L(@"tag_ready_cydia");
            } else if (jbExists) {
                tag = L(@"tag_cydia_ready");
            } else if (baseExists) {
                tag = L(@"tag_ready");
            } else if (localIPSW) {
                tag = L(@"tag_downloaded");
            } else {
                int64_t dlBytes = [self remainingDownloadBytesForEntry:ce];
                tag = [NSString stringWithFormat:@" (%.0f MB)", (double)dlBytes / (1024.0 * 1024.0)];
            }
            btnTitle = [NSString stringWithFormat:@"%@ (%@)%@", [self formattedOSVersion:ce.version forPlatform:ce.platform], ce.build, tag];
        }
        [versionSelect addAction:[UIAlertAction actionWithTitle:btnTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self promptContainerNameForEntry:ce deviceTitle:deviceTitle];
        }]];
    }

    [versionSelect addAction:[UIAlertAction actionWithTitle:L(@"back_to_device_select") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self presentDeviceCreationWizard:nil];
    }]];
    [versionSelect addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (versionSelect.popoverPresentationController) {
        versionSelect.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    }
    [self presentViewController:versionSelect animated:YES completion:nil];
}

- (void)promptContainerNameForEntry:(CatalogEntry *)entry deviceTitle:(NSString *)deviceTitle {
    // Step 3: Enter Container Name (UTM-like) & Cydia option
    NSString *cleanDevice = [self humanReadableNameForId:entry.entryId];
    NSString *verFmt = [self formattedOSVersion:entry.version forPlatform:entry.platform];
    BOOL isFirefoxOS = [entry.platform isEqualToString:@"firefoxos"];
    BOOL isWinRT = [entry.platform isEqualToString:@"winrt"] || [entry.platform isEqualToString:@"chromeos"];
    BOOL isUbuntuTouchVirt = [entry.platform isEqualToString:@"ubuntutouch"];
    NSString *defaultName = (isWinRT || isUbuntuTouchVirt) && entry.build.length > 0
        ? entry.build
        : (isFirefoxOS && entry.build.length > 0
            ? [NSString stringWithFormat:@"%@ (%@)", verFmt, entry.build]
            : ([entry.platform isEqualToString:@"android"] && entry.build.length > 0
                ? [NSString stringWithFormat:@"%@ (%@)", verFmt, [entry.variant isEqualToString:@"google_apis"] ? @"Google APIs" : @"AOSP"]
                : [NSString stringWithFormat:@"%@ (%@)", cleanDevice, verFmt]));
    BOOL canCydia = [self supportsCydiaForEntry:entry];

    BOOL isIPhone5 = ([entry.productType isEqualToString:@"iPhone5,2"] || [entry.entryId containsString:@"n42ap"]);
    BOOL isAndroid = [entry.platform isEqualToString:@"android"] || isFirefoxOS;
    NSString *msg = canCydia
        ? L(@"wizard_name_config_prompt_cydia")
        : ((isWinRT || isUbuntuTouchVirt)
            ? L(@"wizard_name_config_prompt_winrt")
            : (isAndroid
                ? L(@"wizard_name_config_prompt_android")
                : (isIPhone5
                    ? L(@"wizard_name_config_prompt_n42")
                    : L(@"wizard_name_config_prompt_default"))));

    UIAlertController *namePrompt = [UIAlertController alertControllerWithTitle:L(@"wizard_name_config_title")
                                                                        message:msg
                                                                 preferredStyle:UIAlertControllerStyleAlert];

    [namePrompt addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = defaultName;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    if (canCydia) {
        NSString *stockTitle = [self hasPreparedBaseForEntryId:entry.entryId] ? L(@"btn_create_standard_ready") : L(@"btn_create_standard_rec");
        NSString *jbId = [NSString stringWithFormat:@"%@-jb", entry.entryId];
        NSString *jbTitle = [self hasPreparedBaseForEntryId:jbId] ? L(@"btn_create_cydia_ready") : L(@"btn_create_cydia_jb");

        [namePrompt addAction:[UIAlertAction actionWithTitle:jbTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UITextField *tf = namePrompt.textFields.firstObject;
            NSString *chosenName = tf.text.length > 0 ? tf.text : [NSString stringWithFormat:@"%@ (Cydia)", defaultName];
            [self executeContainerCreationForEntry:entry containerName:chosenName installCydia:YES];
        }]];
        [namePrompt addAction:[UIAlertAction actionWithTitle:stockTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UITextField *tf = namePrompt.textFields.firstObject;
            NSString *chosenName = tf.text.length > 0 ? tf.text : defaultName;
            [self executeContainerCreationForEntry:entry containerName:chosenName installCydia:NO];
        }]];
    } else if ([entry.platform isEqualToString:@"winrt"] ||
               [entry.platform isEqualToString:@"chromeos"] ||
               [entry.platform isEqualToString:@"ubuntutouch"]) {
        BOOL isChromeOS = [entry.platform isEqualToString:@"chromeos"];
        BOOL isUTVirt = [entry.platform isEqualToString:@"ubuntutouch"];
        [namePrompt addAction:[UIAlertAction actionWithTitle:L(@"create") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UITextField *tf = namePrompt.textFields.firstObject;
            NSString *chosenName = tf.text.length > 0 ? tf.text : defaultName;
            UIAlertController *sizeSheet = [UIAlertController alertControllerWithTitle:@"ストレージ容量を選択"
                                                                             message:@"QCOW2 形式のため、実際に使用した分だけ容量を消費します。"
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray<NSNumber *> *sizes = isUTVirt
                ? @[@8, @16, @32, @64]
                : (isChromeOS ? @[@16, @32, @48, @64, @128] : @[@32, @48, @64, @128]);
            int recGB = isUTVirt
                ? (entry.diskGB >= 8 ? entry.diskGB : 16)
                : (isChromeOS ? (entry.diskGB >= 16 ? entry.diskGB : 16) : 32);
            for (NSNumber *gbNum in sizes) {
                int gb = gbNum.intValue;
                NSString *title = (gb == recGB)
                    ? [NSString stringWithFormat:@"%d GB（推奨・QCOW2）", gb]
                    : [NSString stringWithFormat:@"%d GB（QCOW2）", gb];
                [sizeSheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
                    entry.diskGB = gb;
                    [self executeContainerCreationForEntry:entry containerName:chosenName installCydia:NO];
                }]];
            }
            [sizeSheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
            sizeSheet.popoverPresentationController.sourceView = self.view;
            sizeSheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentViewController:sizeSheet animated:YES completion:nil];
            });
        }]];
    } else {
        [namePrompt addAction:[UIAlertAction actionWithTitle:L(@"create") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UITextField *tf = namePrompt.textFields.firstObject;
            NSString *chosenName = tf.text.length > 0 ? tf.text : defaultName;
            [self executeContainerCreationForEntry:entry containerName:chosenName installCydia:NO];
        }]];
    }

    [namePrompt addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:namePrompt animated:YES completion:nil];
}

- (void)downloadChromeOSImageForContainer:(VMContainer *)container
                                    entry:(CatalogEntry *)entry
                       fromViewController:(UIViewController *)presenter
                               completion:(void (^ _Nullable)(BOOL ok))completion {
    if (!container || !entry || entry.url.length == 0) {
        if (completion) completion(NO);
        return;
    }
    NSURL *url = [NSURL URLWithString:entry.url];
    if (!url) {
        if (completion) completion(NO);
        return;
    }
    NSString *title = [NSString stringWithFormat:@"%@ をダウンロード中…", entry.version ?: @"Chrome OS ARM"];
    UIAlertController *prog = [UIAlertController alertControllerWithTitle:title
                                                                  message:@"接続しています…"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    NSString *dlId = [NSString stringWithFormat:@"crosdl-%@-%ld", entry.entryId ?: @"img", (long)[[NSDate date] timeIntervalSince1970] % 100000];
    [prog addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [[IPSWDownloader sharedDownloader] cancel];
    }]];
    [presenter presentViewController:prog animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    [[IPSWDownloader sharedDownloader] startDownloadWithId:dlId
                                              displayTitle:entry.build ?: entry.version ?: @"Chrome OS ARM"
                                                primaryURL:url
                                               fallbackURL:nil
                                              expectedSHA1:nil
                                             expectedBytes:entry.bytes
                                                  metadata:@{}
                                                  progress:^(int64_t bytesWritten, int64_t totalBytes, double frac, double speedMBs) {
        dispatch_async(dispatch_get_main_queue(), ^{
            int pct = (int)llround(frac * 100.0);
            if (totalBytes > 0) {
                prog.message = [NSString stringWithFormat:@"%d%%  (%.1f / %.1f MB • %.1f MB/s)",
                                pct, (double)bytesWritten / 1048576.0, (double)totalBytes / 1048576.0, speedMBs];
            } else {
                prog.message = [NSString stringWithFormat:@"%.1f MB (%.1f MB/s)",
                                (double)bytesWritten / 1048576.0, speedMBs];
            }
        });
    } completion:^(NSURL * _Nullable localURL, NSError * _Nullable error) {
        if (error || !localURL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [prog dismissViewControllerAnimated:YES completion:^{
                    if (error && error.code != NSURLErrorCancelled) {
                        UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"ダウンロード失敗"
                                                                                          message:error.localizedDescription ?: @"Unknown error"
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                        [errAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                        [presenter presentViewController:errAlert animated:YES completion:nil];
                    }
                    if (completion) completion(NO);
                }];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            prog.title = @"イメージを配置中…";
            prog.message = [entry.url.lowercaseString hasSuffix:@".zip"]
                ? @"ZIP アーカイブを展開しています…"
                : @"ディスクイメージを保存しています…";
        });

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            NSString *statePath = [container statePathWithRoot:[s containersDirectory]];
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:statePath withIntermediateDirectories:YES attributes:nil error:nil];

            BOOL isZip = [entry.url.lowercaseString hasSuffix:@".zip"];
            NSString *destName = isZip
                ? [NSString stringWithFormat:@"%@.img", entry.entryId ?: @"chromeos"]
                : [NSString stringWithFormat:@"%@.iso", entry.entryId ?: @"chromeos"];
            NSString *destPath = [statePath stringByAppendingPathComponent:destName];
            [fm removeItemAtPath:destPath error:nil];

            BOOL ok = NO;
            NSString *errMsg = nil;
            if (isZip) {
                int rc = lighttouch_extract_zip_image([localURL.path fileSystemRepresentation],
                                                      [destPath fileSystemRepresentation]);
                [fm removeItemAtPath:localURL.path error:nil];
                if (rc == 0) {
                    ok = YES;
                } else {
                    const char *le = lighttouch_firmware_last_error();
                    errMsg = (le && *le) ? [NSString stringWithUTF8String:le] : @"ZIP 展開に失敗しました";
                }
            } else {
                NSError *mvErr = nil;
                if ([fm moveItemAtPath:localURL.path toPath:destPath error:&mvErr] ||
                    [fm copyItemAtPath:localURL.path toPath:destPath error:&mvErr]) {
                    [fm removeItemAtPath:localURL.path error:nil];
                    ok = YES;
                } else {
                    errMsg = mvErr.localizedDescription ?: @"ファイル保存に失敗しました";
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) {
                    container.winrtIsoPath = destName;
                    container.winrtBootFromIso = YES;
                    [container saveMetadataWithRoot:[s containersDirectory]];
                    [s scanContainers];
                }
                [prog dismissViewControllerAnimated:YES completion:^{
                    if (!ok) {
                        UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"展開エラー"
                                                                                          message:errMsg ?: @"Unknown error"
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                        [errAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                        [presenter presentViewController:errAlert animated:YES completion:nil];
                    } else {
                        [s->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
                    }
                    if (completion) completion(ok);
                }];
            });
        });
    }];
}

- (void)createWinRTContainerWithId:(NSString *)cid name:(NSString *)name entry:(CatalogEntry *)entry {
    BOOL isChromeOS = [entry.platform isEqualToString:@"chromeos"];
    VMContainer *c = [[VMContainer alloc] init];
    c.containerId = cid;
    c.name = name;
    c.baseId = entry.entryId ?: (isChromeOS ? @"chromeos-daisy-r40" : @"winrt-8.1");
    c.productType = entry.productType ?: (isChromeOS ? @"ChromeOSARMv7" : @"WinRTARMv7");
    c.version = entry.version ?: (isChromeOS ? @"R40" : @"8.1");
    c.build = entry.build ?: (isChromeOS ? @"Chrome OS R40 (ARM32)" : @"Windows RT (ARM32)");
    c.platform = isChromeOS ? @"chromeos" : @"winrt";
    c.ramMB = entry.ramMB > 0 ? entry.ramMB : (isChromeOS ? 1536 : 2048);
    c.winrtDiskPath = @"sdcard.qcow2";
    c.winrtIsoPath = nil;
    c.winrtBootFromIso = NO;
    c.winrtRtcDate = entry.rtcDate.length > 0 ? entry.rtcDate : (isChromeOS ? @"today" : @"2013-07-15");
    c.winrtEnableNet = YES;
    c.winrtEnableAudio = YES;
    c.createdAt = [[NSDate date] timeIntervalSince1970];

    NSString *statePath = [c statePathWithRoot:[self containersDirectory]];
    [[NSFileManager defaultManager] createDirectoryAtPath:statePath withIntermediateDirectories:YES attributes:nil error:nil];

    int minGB = isChromeOS ? 16 : 32;
    uint64_t diskBytes = (uint64_t)(entry.diskGB >= minGB ? entry.diskGB : minGB) * 1024ULL * 1024ULL * 1024ULL;
    NSString *diskPath = [statePath stringByAppendingPathComponent:c.winrtDiskPath];
    NSError *diskErr = nil;
    if (!ClassicCreateWinRTQcow2DiskImage(diskPath, diskBytes, &diskErr)) {
        UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"storage_build_failed")
                                                                      message:diskErr.localizedDescription ?: @"Failed creating sparse disk"
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:fail animated:YES completion:nil];
        return;
    }

    [c saveMetadataWithRoot:[self containersDirectory]];
    [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self scanContainers];

    NSUInteger rowIdx = [self.containers indexOfObjectPassingTest:^BOOL(VMContainer *obj, NSUInteger idx, BOOL *stop) {
        return [obj.containerId isEqualToString:cid];
    }];

    UIAlertController *done = [UIAlertController alertControllerWithTitle:L(@"container_created_title")
                                                                  message:[NSString stringWithFormat:L(@"winrt_container_created_msg_fmt"), name]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    if (isChromeOS && entry.url.length > 0) {
        [done addAction:[UIAlertAction actionWithTitle:@"公式イメージをダウンロード" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            VMContainer *target = (rowIdx != NSNotFound && rowIdx < self.containers.count) ? self.containers[rowIdx] : c;
            [self downloadChromeOSImageForContainer:target entry:entry fromViewController:self completion:nil];
        }]];
    }
    [done addAction:[UIAlertAction actionWithTitle:L(@"winrt_configure_media") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (rowIdx != NSNotFound) {
            ContainerDetailViewController *detailVC = [[ContainerDetailViewController alloc] initWithContainer:self.containers[rowIdx] mainVC:self index:(NSInteger)rowIdx];
            [self.navigationController pushViewController:detailVC animated:YES];
        }
    }]];
    [done addAction:[UIAlertAction actionWithTitle:L(@"done") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

- (void)createOrPrepareUbuntuTouchVirtForEntry:(CatalogEntry *)entry
                                   containerId:(NSString *)cid
                                          name:(NSString *)name
                                        diskGB:(int)diskGB {
    if ([self hasPreparedBaseForEntryId:entry.entryId]) {
        [self instantiateUbuntuTouchVirtContainerWithId:cid name:name entry:entry diskGB:diskGB];
        return;
    }
    NSString *localTar = [self findExistingIPSWForEntryId:entry.entryId];
    if (localTar.length > 0) {
        [self downloadOverlaysAndPrepareUbuntuTouchVirt:[NSURL fileURLWithPath:localTar]
                                                  entry:entry
                                            containerId:cid
                                          containerName:name
                                                 diskGB:diskGB];
        return;
    }
    NSString *displayTitle = [NSString stringWithFormat:@"%@ (%@)",
                              [self humanReadableNameForId:entry.productType],
                              [self formattedOSVersion:entry.version forPlatform:entry.platform]];
    NSDictionary *metadata = @{
        @"platform": @"ubuntutouch",
        @"entryId": entry.entryId ?: @"",
        @"containerId": cid ?: @"",
        @"containerName": name ?: @"",
        @"diskGB": @(diskGB),
        @"managementOnly": @NO,
        @"displayTitle": displayTitle
    };
    [self startIPSWDownloadForEntry:entry metadata:metadata];
}

- (void)downloadOverlaysAndPrepareUbuntuTouchVirt:(NSURL *)tarURL
                                            entry:(CatalogEntry *)entry
                                      containerId:(NSString *)cid
                                    containerName:(NSString *)name
                                           diskGB:(int)diskGB {
    if (self.isPreparingBase || self.isDownloadingOverlays) {
        return;
    }
    if (tarURL.path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:tarURL.path]) {
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
        UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"storage_build_failed")
                                                                      message:[NSString stringWithFormat:L(@"firmware_err_ipsw_not_found_fmt"), tarURL.path ?: @"(null)"]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:fail animated:YES completion:nil];
        return;
    }

    NSArray<NSString *> *overlayUrls = entry.overlayUrls;
    if (overlayUrls.count == 0 && entry.entryId.length > 0) {
        CatalogEntry *catEntry = [self catalogEntryWithId:entry.entryId];
        if (catEntry.overlayUrls.count > 0) {
            overlayUrls = catEntry.overlayUrls;
        }
    }
    if (overlayUrls.count == 0) {
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
        UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"storage_build_failed")
                                                                      message:@"Ubuntu Touch Mesa/Mir overlay package list is missing from catalog."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:fail animated:YES completion:nil];
        return;
    }

    self.isDownloadingOverlays = YES;
    NSString *overlaysDir = [[[self firmwaresDirectory] stringByAppendingPathComponent:@"ut-overlays"]
                             stringByAppendingPathComponent:(entry.entryId ?: @"ut-virt")];

    [self showProgress:L(@"ubuntutouch_downloading_overlays")
                detail:[NSString stringWithFormat:@"0 / %lu", (unsigned long)overlayUrls.count]];
    self.cancelButton.hidden = NO;
    self.progressBar.progress = 0.0f;
    NSUInteger opToken = self.progressToken;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:overlaysDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30.0;
        cfg.timeoutIntervalForResource = 120.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

        BOOL (^isOpCancelled)(void) = ^BOOL {
            __block BOOL cancelled = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                cancelled = (!s || s.progressToken != opToken);
            });
            return cancelled;
        };

        NSString *dlErrorMsg = nil;
        NSUInteger totalCount = overlayUrls.count;
        for (NSUInteger idx = 0; idx < totalCount; idx++) {
            if (isOpCancelled()) {
                dlErrorMsg = @"cancelled";
                break;
            }
            NSString *urlStr = overlayUrls[idx];
            NSURL *debURL = [NSURL URLWithString:urlStr];
            NSString *fileName = debURL.lastPathComponent ?: [NSString stringWithFormat:@"overlay_%lu.deb", (unsigned long)idx];
            NSString *dstPath = [overlaysDir stringByAppendingPathComponent:fileName];
            NSString *partPath = [dstPath stringByAppendingString:@".part"];

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s || s.progressToken != opToken) return;
                s.progressBar.progress = (float)idx / (float)MAX(totalCount, 1);
                s.progressDetailLabel.text = [NSString stringWithFormat:@"[%lu / %lu] %@",
                                              (unsigned long)(idx + 1), (unsigned long)totalCount, fileName];
            });

            NSDictionary *existingAttrs = [fm attributesOfItemAtPath:dstPath error:nil];
            if (existingAttrs && [existingAttrs fileSize] > 0) {
                continue;
            }

            if (!debURL) {
                dlErrorMsg = [NSString stringWithFormat:@"Invalid overlay URL: %@", urlStr];
                break;
            }

            BOOL fetched = NO;
            NSString *lastErr = @"Download failed";
            for (int attempt = 0; attempt < 3; attempt++) {
                if (isOpCancelled()) {
                    dlErrorMsg = @"cancelled";
                    break;
                }
                if (attempt > 0) {
                    [NSThread sleepForTimeInterval:(attempt == 1 ? 1.5 : 3.0)];
                    if (isOpCancelled()) {
                        dlErrorMsg = @"cancelled";
                        break;
                    }
                }
                [fm removeItemAtPath:partPath error:nil];
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                __block NSURL *tmpLoc = nil;
                __block NSURLResponse *resp = nil;
                __block NSError *taskErr = nil;
                NSURLSessionDownloadTask *task = [session downloadTaskWithURL:debURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                    if (location && !error) {
                        NSError *mvErr = nil;
                        if ([fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:partPath] error:&mvErr] ||
                            [fm copyItemAtURL:location toURL:[NSURL fileURLWithPath:partPath] error:&mvErr]) {
                            tmpLoc = [NSURL fileURLWithPath:partPath];
                        } else {
                            taskErr = mvErr;
                        }
                    } else {
                        taskErr = error;
                    }
                    resp = response;
                    dispatch_semaphore_signal(sem);
                }];
                [task resume];
                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

                NSInteger statusCode = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
                if (statusCode >= 200 && statusCode < 300 && tmpLoc != nil) {
                    NSDictionary *partAttrs = [fm attributesOfItemAtPath:partPath error:nil];
                    if (partAttrs && [partAttrs fileSize] > 0) {
                        [fm removeItemAtPath:dstPath error:nil];
                        NSError *finalErr = nil;
                        if ([fm moveItemAtPath:partPath toPath:dstPath error:&finalErr]) {
                            fetched = YES;
                            break;
                        }
                        lastErr = finalErr.localizedDescription ?: @"Failed writing overlay .deb";
                    } else {
                        lastErr = [NSString stringWithFormat:@"Empty response for %@", fileName];
                    }
                } else {
                    [fm removeItemAtPath:partPath error:nil];
                    lastErr = taskErr.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, fileName];
                    if (statusCode > 0 && statusCode < 500 && statusCode != 429) {
                        break;
                    }
                }
            }
            if (dlErrorMsg) break;
            if (!fetched) {
                dlErrorMsg = lastErr;
                break;
            }
        }

        [session finishTasksAndInvalidate];

        if (dlErrorMsg || isOpCancelled()) {
            BOOL wasCancelled = !dlErrorMsg || [dlErrorMsg isEqualToString:@"cancelled"];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s) return;
                s.isDownloadingOverlays = NO;
                [s hideProgress];
                if (!wasCancelled) {
                    [s->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
                    UIAlertController *err = [UIAlertController alertControllerWithTitle:L(@"download_failed_title")
                                                                                 message:dlErrorMsg
                                                                          preferredStyle:UIAlertControllerStyleAlert];
                    [err addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                    [s presentViewController:err animated:YES completion:nil];
                }
            });
            return;
        }

        dispatch_sync(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.isDownloadingOverlays = NO;
            s.isPreparingBase = YES;
            s.cancelButton.hidden = YES;
            s.progressTitleLabel.text = L(@"ubuntutouch_building_rootfs");
            s.progressDetailLabel.text = L(@"extracting_android_images");
            s.progressBar.progress = 0.0f;
        });

        NSString *outDir = [[self basesDirectory] stringByAppendingPathComponent:(entry.entryId ?: @"ut-virt-15.04")];
        [fm removeItemAtPath:outDir error:nil];
        [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

        int rc = lighttouch_prepare_ubuntutouch_virt(
            tarURL.path.UTF8String,
            overlaysDir.UTF8String,
            (entry.version ?: @"15.04").UTF8String,
            outDir.UTF8String,
            firmware_progress_callback
        );

        NSString *prepErr = nil;
        if (rc != 0) {
            const char *le = lighttouch_firmware_last_error();
            prepErr = (le && *le) ? [NSString stringWithUTF8String:le] : [NSString stringWithFormat:@"Prep failed (%d)", rc];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.isPreparingBase = NO;
            [s hideProgress];
            if (rc == 0) {
                [s instantiateUbuntuTouchVirtContainerWithId:cid name:name entry:entry diskGB:diskGB];
            } else {
                [s->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
                UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"storage_build_failed")
                                                                              message:prepErr ?: @"Unknown error"
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                [s presentViewController:fail animated:YES completion:nil];
            }
        });
    });
}

- (void)instantiateUbuntuTouchVirtContainerWithId:(NSString *)cid
                                           name:(NSString *)name
                                          entry:(CatalogEntry *)entry
                                         diskGB:(int)diskGB {
    VMContainer *c = [[VMContainer alloc] init];
    c.containerId = cid;
    c.name = name;
    c.baseId = entry.entryId ?: @"ut-virt-15.04";
    c.productType = entry.productType ?: @"UbuntuTouchVirtARMv7";
    c.version = entry.version ?: @"15.04";
    c.build = entry.build ?: @"Ubuntu Touch (Virt)";
    c.platform = @"ubuntutouch";
    c.ramMB = entry.ramMB > 0 ? entry.ramMB : 1536;
    c.winrtDiskPath = @"userdata.qcow2";
    c.winrtIsoPath = nil;
    c.winrtBootFromIso = NO;
    c.winrtRtcDate = @"today";
    c.winrtEnableNet = YES;
    c.winrtEnableAudio = YES;
    c.createdAt = [[NSDate date] timeIntervalSince1970];

    NSString *baseRootfs = [[[self basesDirectory] stringByAppendingPathComponent:c.baseId]
                            stringByAppendingPathComponent:@"rootfs.ext4"];
    NSString *statePath = [c statePathWithRoot:[self containersDirectory]];
    NSString *stateRootfs = [statePath stringByAppendingPathComponent:@"rootfs.ext4"];
    NSString *userdataPath = [statePath stringByAppendingPathComponent:c.winrtDiskPath];
    uint64_t userdataBytes = (uint64_t)(diskGB >= 8 ? diskGB : 16) * 1024ULL * 1024ULL * 1024ULL;

    [self showProgress:L(@"ubuntutouch_building_rootfs") detail:name ?: c.containerId];
    self.cancelButton.hidden = YES;
    self.progressBar.progress = 0.5f;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:statePath withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:stateRootfs error:nil];

        NSError *opErr = nil;
        BOOL ok = [fm copyItemAtPath:baseRootfs toPath:stateRootfs error:&opErr];
        if (ok) {
            ok = ClassicCreateWinRTQcow2DiskImage(userdataPath, userdataBytes, &opErr);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s hideProgress];
            if (!ok) {
                [s->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
                UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"storage_build_failed")
                                                                              message:opErr.localizedDescription ?: @"Failed creating Ubuntu Touch container storage"
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                [s presentViewController:fail animated:YES completion:nil];
                return;
            }
            [c saveMetadataWithRoot:[s containersDirectory]];
            [s->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            [s scanContainers];

            UIAlertController *done = [UIAlertController alertControllerWithTitle:L(@"container_created_title")
                                                                          message:[NSString stringWithFormat:L(@"container_ready_msg_fmt"), name]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:L(@"boot_now") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [s bootContainer:c];
            }]];
            [done addAction:[UIAlertAction actionWithTitle:L(@"done") style:UIAlertActionStyleCancel handler:nil]];
            [s presentViewController:done animated:YES completion:nil];
        });
    });
}

- (void)executeContainerCreationForEntry:(CatalogEntry *)entry containerName:(NSString *)containerName installCydia:(BOOL)installCydia {
    if (self.isPreparingBase) return;
    // Generate unique container ID
    NSString *cid = [NSString stringWithFormat:@"vm-%@-%ld", entry.entryId, (long)[[NSDate date] timeIntervalSince1970] % 100000];
    if ([entry.platform isEqualToString:@"winrt"] || [entry.platform isEqualToString:@"chromeos"]) {
        [self createWinRTContainerWithId:cid name:containerName entry:entry];
        return;
    }
    if ([entry.platform isEqualToString:@"ubuntutouch"]) {
        int diskGB = (entry.diskGB >= 8 ? entry.diskGB : 16);
        [self createOrPrepareUbuntuTouchVirtForEntry:entry containerId:cid name:containerName diskGB:diskGB];
        return;
    }
    NSString *baseId = installCydia ? [NSString stringWithFormat:@"%@-jb", entry.entryId] : entry.entryId;

    // Check if Base already exists
    if ([self hasPreparedBaseForEntryId:baseId]) {
        // Fast Instant Creation!
        [self instantiateContainerWithId:cid name:containerName baseId:baseId entry:entry];
        return;
    }

    // Check if IPSW already exists locally
    NSString *localIPSW = [self findExistingIPSWForEntryId:entry.entryId];
    if (localIPSW) {
        NSURL *ipswURL = [NSURL fileURLWithPath:localIPSW];
        [self prepareBaseWithIPSW:ipswURL entry:entry installCydia:installCydia completion:^{
            [self instantiateContainerWithId:cid name:containerName baseId:baseId entry:entry];
        }];
        return;
    }

    // Otherwise, start download
    [self downloadAndPrepareEntry:entry containerId:cid containerName:containerName installCydia:installCydia];
}

- (nullable CatalogEntry *)loadCustomCatalogEntryForId:(NSString *)entryId {
    if (entryId.length == 0) return nil;
    NSString *metaName = [NSString stringWithFormat:@"%@.custom.json", entryId];
    for (NSString *dir in [self ipswSearchDirectories]) {
        NSString *p = [dir stringByAppendingPathComponent:metaName];
        NSData *data = [NSData dataWithContentsOfFile:p];
        if (!data) continue;
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        CatalogEntry *ce = [[CatalogEntry alloc] init];
        ce.entryId = d[@"id"] ?: entryId;
        ce.platform = d[@"platform"] ?: @"ios";
        ce.productType = d[@"product_type"] ?: @"";
        ce.version = d[@"version"] ?: @"";
        ce.build = d[@"build"] ?: @"";
        ce.sha1 = d[@"sha1"] ?: @"";
        ce.bytes = [d[@"bytes"] longLongValue];
        ce.apiLevel = [d[@"api_level"] intValue];
        ce.ramMB = [d[@"ram_mb"] intValue];
        ce.lcdWidth = [d[@"width"] intValue];
        ce.lcdHeight = [d[@"height"] intValue];
        ce.lcdDensity = [d[@"dpi"] intValue];
        ce.cpu = d[@"cpu"];
        ce.cmdline = d[@"cmdline"];
        ce.variant = d[@"variant"];
        return ce;
    }
    return nil;
}

- (nullable NSString *)findBestGoldfishBaseZipForAPILevel:(NSInteger)targetApi {
    NSString *bestPath = nil;
    NSInteger bestDiff = NSIntegerMax;
    for (CatalogEntry *ce in self.catalogEntries) {
        if (![ce.platform isEqualToString:@"android"]) continue;
        NSString *local = [self findExistingIPSWForEntryId:ce.entryId];
        if (local.length == 0) continue;
        NSInteger diff = labs((NSInteger)ce.apiLevel - targetApi);
        if (diff < bestDiff) {
            bestDiff = diff;
            bestPath = local;
        }
    }
    return bestPath;
}

- (nullable CatalogEntry *)catalogEntryWithId:(NSString *)entryId {
    if (entryId.length == 0) return nil;
    for (CatalogEntry *entry in self.catalogEntries) {
        if ([entry.entryId isEqualToString:entryId]) {
            return entry;
        }
    }
    return [self loadCustomCatalogEntryForId:entryId];
}

- (void)handleCompletedIPSWDownloadAtURL:(nullable NSURL *)localURL
                                   error:(nullable NSError *)error
                                metadata:(nullable NSDictionary *)metadata
                             fromPending:(BOOL)fromPending {
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground && !fromPending) {
        NSMutableDictionary *deferred = [NSMutableDictionary dictionary];
        if (localURL.path.length > 0) deferred[@"localPath"] = localURL.path;
        if (error) deferred[@"error"] = error;
        if (metadata) deferred[@"metadata"] = metadata;
        self.deferredBackgroundDownloadResult = deferred;
        return;
    }

    if (error || !localURL) {
        [self hideProgress];
        if (error && [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
            return;
        }
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
        if (!self.presentedViewController) {
            UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:L(@"download_failed_title")
                                                                              message:error.localizedDescription ?: L(@"download_failed_msg")
                                                                       preferredStyle:UIAlertControllerStyleAlert];
            [errAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:errAlert animated:YES completion:nil];
        }
        return;
    }

    BOOL managementOnly = [metadata[@"managementOnly"] boolValue];
    NSString *entryId = metadata[@"entryId"];
    NSString *cid = metadata[@"containerId"];
    NSString *name = metadata[@"containerName"];
    BOOL installCydia = [metadata[@"installCydia"] boolValue];
    NSString *displayTitle = metadata[@"displayTitle"] ?: entryId ?: @"Firmware";
    if (!self.isCatalogLoaded && entryId.length > 0) {
        __weak typeof(self) weakSelf = self;
        [self ensureCatalogLoadedThen:^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s handleCompletedIPSWDownloadAtURL:localURL error:error metadata:metadata fromPending:fromPending];
        }];
        return;
    }
    CatalogEntry *entry = [self catalogEntryWithId:entryId];
    if (entry && [entry.platform isEqualToString:@"firefoxos"] && ![self findExistingIPSWForEntryId:entry.entryId]) {
        [self startIPSWDownloadForEntry:entry metadata:metadata];
        return;
    }

    if (managementOnly || !entry || cid.length == 0 || name.length == 0) {
        [self hideProgress];
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
        if (fromPending) {
            if (!self.presentedViewController) {
                UIAlertController *done = [UIAlertController alertControllerWithTitle:L(@"ipsw_download_complete_title")
                                                                              message:[NSString stringWithFormat:L(@"ipsw_download_complete_msg"), displayTitle]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:done animated:YES completion:nil];
            }
        } else {
            [self promptFirmwareManagement:nil];
        }
        return;
    }

    if (entry && [entry.platform isEqualToString:@"ubuntutouch"]) {
        int diskGB = [metadata[@"diskGB"] intValue] >= 8 ? [metadata[@"diskGB"] intValue] : (entry.diskGB >= 8 ? entry.diskGB : 16);
        [self downloadOverlaysAndPrepareUbuntuTouchVirt:localURL entry:entry containerId:cid containerName:name diskGB:diskGB];
        return;
    }

    NSString *baseId = installCydia ? [NSString stringWithFormat:@"%@-jb", entry.entryId] : entry.entryId;
    [self prepareBaseWithIPSW:localURL entry:entry installCydia:installCydia completion:^{
        [self instantiateContainerWithId:cid name:name baseId:baseId entry:entry];
    }];
}

- (void)attachToActiveBackgroundDownload {
    IPSWDownloader *downloader = [IPSWDownloader sharedDownloader];
    NSDictionary *capturedMetadata = [downloader.activeMetadata copy];
    __weak typeof(self) weakSelf = self;
    [downloader attachProgress:^(int64_t bytesWritten, int64_t totalBytes, double frac, double speedMBs) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.progressBar.progress = (float)frac;
            strongSelf.progressDetailLabel.text = [NSString stringWithFormat:L(@"ipsw_bg_progress_detail"),
                                                   (double)bytesWritten / 1048576.0,
                                                   (double)totalBytes / 1048576.0,
                                                   speedMBs];
        });
    } completion:^(NSURL * _Nullable localURL, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleCompletedIPSWDownloadAtURL:localURL error:error metadata:capturedMetadata fromPending:NO];
        });
    }];
}

- (void)syncBackgroundDownloadUIState {
    if (self.activeEmulatorVC != nil) {
        return;
    }

    if (self.deferredBackgroundDownloadResult) {
        NSDictionary *deferred = self.deferredBackgroundDownloadResult;
        self.deferredBackgroundDownloadResult = nil;
        NSString *localPath = deferred[@"localPath"];
        NSURL *localURL = localPath.length > 0 ? [NSURL fileURLWithPath:localPath] : nil;
        NSError *err = deferred[@"error"];
        NSDictionary *meta = deferred[@"metadata"];
        [self handleCompletedIPSWDownloadAtURL:localURL error:err metadata:meta fromPending:YES];
        return;
    }

    IPSWDownloader *downloader = [IPSWDownloader sharedDownloader];
    NSDictionary *pending = [downloader consumePendingCompletedDownloadInfo];
    if (pending) {
        NSString *errMsg = pending[@"errorMessage"];
        NSString *localPath = pending[@"localPath"];
        if (errMsg.length > 0) {
            NSError *err = [NSError errorWithDomain:@"IPSWDownloader"
                                               code:1003
                                           userInfo:@{NSLocalizedDescriptionKey: errMsg}];
            [self handleCompletedIPSWDownloadAtURL:nil error:err metadata:pending[@"metadata"] fromPending:YES];
        } else if (localPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:localPath]) {
            [self handleCompletedIPSWDownloadAtURL:[NSURL fileURLWithPath:localPath]
                                             error:nil
                                          metadata:pending[@"metadata"]
                                       fromPending:YES];
        }
        return;
    }

    if (downloader.isDownloading) {
        NSString *title = downloader.displayTitle ?: downloader.downloadId ?: @"Firmware";
        NSString *detail = L(@"ipsw_bg_reattached_detail");
        if (downloader.lastTotalBytesExpected > 0 && downloader.lastTotalBytesWritten > 0) {
            detail = [NSString stringWithFormat:L(@"ipsw_bg_progress_detail"),
                      (double)downloader.lastTotalBytesWritten / 1048576.0,
                      (double)downloader.lastTotalBytesExpected / 1048576.0,
                      downloader.lastSpeedMBs];
        }
        [self showProgress:[NSString stringWithFormat:L(@"downloading_fmt"), title] detail:detail];
        self.cancelButton.hidden = NO;
        self.progressBar.progress = (float)downloader.lastFractionCompleted;
        [self attachToActiveBackgroundDownload];
    }
}

- (void)startIPSWDownloadForEntry:(CatalogEntry *)entry metadata:(NSDictionary *)metadata {
    [_haptic impactOccurred];
    NSString *downloadId = entry.entryId;
    NSURL *primary = [NSURL URLWithString:entry.url];
    NSURL *fallback = entry.fallbackUrl ? [NSURL URLWithString:entry.fallbackUrl] : nil;
    NSString *expectedSHA1 = entry.sha1;
    int64_t expectedBytes = entry.bytes;
    NSString *stepLabel = [self formattedOSVersion:entry.version forPlatform:entry.platform];

    if ([entry.platform isEqualToString:@"firefoxos"]) {
        if (![self findExistingGonkBaseZip]) {
            downloadId = @"android-19-aosp";
            primary = [NSURL URLWithString:entry.gonkUrl];
            fallback = nil;
            expectedSHA1 = entry.gonkSha1;
            expectedBytes = entry.gonkBytes;
            stepLabel = [NSString stringWithFormat:@"%@ (1/3 Gonk Base)", [self formattedOSVersion:entry.version forPlatform:entry.platform]];
        } else if (![self findExistingGaiaZipForEntryId:entry.entryId]) {
            downloadId = [NSString stringWithFormat:@"%@-gaia", entry.entryId];
            primary = [NSURL URLWithString:entry.gaiaUrl];
            fallback = nil;
            expectedSHA1 = entry.gaiaSha1;
            expectedBytes = entry.gaiaBytes;
            stepLabel = [NSString stringWithFormat:@"%@ (2/3 Gaia UI)", [self formattedOSVersion:entry.version forPlatform:entry.platform]];
        } else {
            downloadId = entry.entryId;
            primary = [NSURL URLWithString:entry.url];
            fallback = nil;
            expectedSHA1 = entry.sha1;
            expectedBytes = entry.b2gBytes > 0 ? entry.b2gBytes : entry.bytes;
            stepLabel = [NSString stringWithFormat:@"%@ (3/3 Gecko B2G)", [self formattedOSVersion:entry.version forPlatform:entry.platform]];
        }
    }

    NSString *title = [NSString stringWithFormat:@"%@ (%@)", [self humanReadableNameForId:entry.productType], stepLabel];
    [self showProgress:[NSString stringWithFormat:L(@"downloading_fmt"), stepLabel]
                detail:L(@"ipsw_bg_connecting_detail")];
    self.cancelButton.hidden = NO;

    __weak typeof(self) weakSelf = self;
    [[IPSWDownloader sharedDownloader] startDownloadWithId:downloadId
                                              displayTitle:title
                                                primaryURL:primary
                                               fallbackURL:fallback
                                              expectedSHA1:expectedSHA1
                                             expectedBytes:expectedBytes
                                                  metadata:metadata
                                                  progress:^(int64_t bytesWritten, int64_t totalBytes, double frac, double speedMBs) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.progressBar.progress = (float)frac;
            strongSelf.progressDetailLabel.text = [NSString stringWithFormat:L(@"ipsw_bg_progress_detail"),
                                                   (double)bytesWritten / 1048576.0,
                                                   (double)totalBytes / 1048576.0,
                                                   speedMBs];
        });
    } completion:^(NSURL * _Nullable localURL, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleCompletedIPSWDownloadAtURL:localURL error:error metadata:metadata fromPending:NO];
        });
    }];
}

- (void)downloadAndPrepareEntry:(CatalogEntry *)entry containerId:(NSString *)cid containerName:(NSString *)name installCydia:(BOOL)installCydia {
    NSString *displayTitle = [NSString stringWithFormat:@"%@ (%@)", [self humanReadableNameForId:entry.productType], [self formattedOSVersion:entry.version forPlatform:entry.platform]];
    NSDictionary *metadata = @{
        @"entryId": entry.entryId ?: @"",
        @"containerId": cid ?: @"",
        @"containerName": name ?: @"",
        @"installCydia": @(installCydia),
        @"managementOnly": @NO,
        @"displayTitle": displayTitle
    };
    [self startIPSWDownloadForEntry:entry metadata:metadata];
}

- (void)downloadCatalogIPSWForManagement:(CatalogEntry *)entry {
    NSString *displayTitle = [NSString stringWithFormat:@"%@ (%@)", [self humanReadableNameForId:entry.productType], [self formattedOSVersion:entry.version forPlatform:entry.platform]];
    NSDictionary *metadata = @{
        @"entryId": entry.entryId ?: @"",
        @"managementOnly": @YES,
        @"displayTitle": displayTitle
    };
    [self startIPSWDownloadForEntry:entry metadata:metadata];
}

static void firmware_progress_callback(int pct, const char *step_name) {
    static pthread_mutex_t sProgressLock = PTHREAD_MUTEX_INITIALIZER;
    static int sLastPct = -999;
    static CFTimeInterval sLastDispatch = 0;
    static char sLastStep[256] = {0};

    const char *safe_step = step_name ? step_name : "";
    CFTimeInterval now = CACurrentMediaTime();

    pthread_mutex_lock(&sProgressLock);
    BOOL stepChanged = (strncmp(sLastStep, safe_step, sizeof(sLastStep) - 1) != 0);
    BOOL pctChanged = (pct != sLastPct);
    if (!pctChanged && !stepChanged) {
        pthread_mutex_unlock(&sProgressLock);
        return;
    }
    if (!stepChanged && pct > 0 && pct < 100 && (now - sLastDispatch) < 0.12) {
        pthread_mutex_unlock(&sProgressLock);
        return;
    }
    sLastPct = pct;
    sLastDispatch = now;
    strncpy(sLastStep, safe_step, sizeof(sLastStep) - 1);
    sLastStep[sizeof(sLastStep) - 1] = '\0';
    pthread_mutex_unlock(&sProgressLock);

    NSString *step = step_name ? ([NSString stringWithUTF8String:step_name] ?: @"") : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sCurrentMainVC) {
            [sCurrentMainVC updateFirmwareProgress:@(pct) step:step];
        }
    });
}

- (void)updateFirmwareProgress:(NSNumber *)pctNum step:(NSString *)step {
    int pct = pctNum.intValue;
    if (pct < 0) {
        if (step.length > 0) {
            NSLog(@"[FirmwareKit] %@", step);
        }
        return;
    }
    self.progressBar.progress = (float)pct / 100.0f;
    if (step.length == 0) return;

    NSString *localized = step;
    if ([step hasPrefix:@"Verifying IPSW"] || [step hasPrefix:@"Checking"]) {
        localized = L(@"ipsw_verifying");
    } else if ([step hasPrefix:@"Decrypting"]) {
        localized = L(@"ipsw_extracting");
    } else if ([step hasPrefix:@"Writing the identity"]) {
        localized = L(@"ipsw_creating_boot_img");
    } else if ([step hasPrefix:@"Building the system"] || [step hasPrefix:@"Building the filesystem"]) {
        localized = L(@"ipsw_building_sys_data");
    } else if ([step hasPrefix:@"Writing the NAND"] || [step hasPrefix:@"Storing"] || [step hasPrefix:@"Packing"]) {
        localized = L(@"ipsw_writing_nand");
    } else if ([step hasPrefix:@"Creating the data-protection"]) {
        localized = L(@"ipsw_preparing_keybag");
    } else if ([step hasPrefix:@"Sealing"]) {
        localized = L(@"ipsw_validating_fs");
    }
    self.progressDetailLabel.text = [NSString stringWithFormat:@"%@ (%d%%)", localized, pct];
}

- (void)prepareBaseWithIPSW:(NSURL *)ipswURL entry:(CatalogEntry *)entry installCydia:(BOOL)installCydia completion:(void(^)(void))completion {
    if (self.isPreparingBase) {
        NSLog(@"[MainViewController] Ignoring overlapping prepareBaseWithIPSW for %@", entry.entryId);
        return;
    }
    if (ipswURL.path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:ipswURL.path]) {
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *msg = [NSString stringWithFormat:L(@"firmware_err_ipsw_not_found_fmt"), ipswURL.path ?: @"(null)"];
        UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"storage_build_failed")
                                                                      message:msg
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:fail animated:YES completion:nil];
        return;
    }

    self.isPreparingBase = YES;
    BOOL isFirefoxOS = ([entry.platform isEqualToString:@"firefoxos"] || [entry.entryId hasPrefix:@"fxos-"]);
    BOOL isAndroid = isFirefoxOS || ([entry.platform isEqualToString:@"android"] || [entry.entryId hasPrefix:@"android-"]);
    NSString *baseId = (!isAndroid && installCydia) ? [NSString stringWithFormat:@"%@-jb", entry.entryId] : entry.entryId;
    NSString *progressTitle = isAndroid
        ? L(@"building_android_storage")
        : (installCydia ? L(@"building_device_storage_cydia") : L(@"building_device_storage"));
    NSString *progressDetail = isAndroid ? L(@"extracting_android_images") : L(@"decrypting_rootfs_nand");
    [self showProgress:progressTitle detail:progressDetail];
    self.cancelButton.hidden = YES;
    self.progressBar.progress = 0.0f;

    NSString *catalogPath = [self catalogFilePath];
    NSString *guestToolsPath = [self guestToolsDirectory];
    NSString *outDir = [[self basesDirectory] stringByAppendingPathComponent:baseId];

    // Clean any prior incomplete preparation to avoid "not an empty directory" error
    [[NSFileManager defaultManager] removeItemAtPath:outDir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Ensure TZ matches current device timezone so firmware image creation seeds /var/db/timezone/localtime
    [NSTimeZone resetSystemTimeZone];
    NSString *tzName = [NSTimeZone localTimeZone].name;
    if (tzName.length > 0) {
        setenv("TZ", tzName.UTF8String, 1);
        tzset();
    }

    NSString *gonkZipPath = isFirefoxOS ? [self findExistingGonkBaseZip] : nil;
    NSString *gaiaZipPath = isFirefoxOS ? [self findExistingGaiaZipForEntryId:entry.entryId] : nil;
    NSString *b2gTarPath = isFirefoxOS ? ([self findExistingB2GTarForEntryId:entry.entryId] ?: ipswURL.path) : nil;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int ret = 0;
        if (isFirefoxOS) {
            ret = lighttouch_firefoxos_prepare(
                (gonkZipPath ?: @"").UTF8String,
                (b2gTarPath ?: @"").UTF8String,
                (gaiaZipPath ?: @"").UTF8String,
                outDir.UTF8String,
                firmware_progress_callback
            );
            if (ret == 0) {
                int metaW = entry.lcdWidth > 0 ? entry.lcdWidth : 750;
                int metaH = entry.lcdHeight > 0 ? entry.lcdHeight : 1334;
                int metaDpi = entry.lcdDensity > 0 ? entry.lcdDensity : 320;
                NSString *defCmdline = [NSString stringWithFormat:@"qemu=1 androidboot.hardware=goldfish console=ttyS0 android.qemud=1 android.checkjni=0 ndns=1 qemu.gles=1 qemu.sf.lcd_density=%d qemu.hw.mainkeys=0", metaDpi];
                NSInteger prepVer = [entry.entryId hasPrefix:@"fxos-2.6"] ? 6 : 4;
                NSDictionary *meta = @{
                    @"platform": @"firefoxos",
                    @"fxos_prep_version": @(prepVer),
                    @"entryId": entry.entryId ?: @"",
                    @"version": entry.version ?: @"",
                    @"variant": entry.variant ?: @"b2g",
                    @"api_level": @(entry.apiLevel > 0 ? entry.apiLevel : 19),
                    @"ram_mb": @(entry.ramMB > 0 ? entry.ramMB : 768),
                    @"cpu": entry.cpu.length > 0 ? entry.cpu : @"cortex-a8",
                    @"width": @(metaW),
                    @"height": @(metaH),
                    @"dpi": @(metaDpi),
                    @"cmdline": entry.cmdline ?: defCmdline
                };
                NSData *metaData = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
                if (metaData) {
                    [metaData writeToFile:[outDir stringByAppendingPathComponent:@"android-metadata.json"] atomically:YES];
                }
            }
        } else if (isAndroid) {
            NSInteger targetApi = entry.apiLevel > 0 ? entry.apiLevel : 19;
            NSString *baseZipPath = [self findBestGoldfishBaseZipForAPILevel:targetApi];
            ret = lighttouch_android_prepare_custom(
                ipswURL.path.UTF8String,
                (baseZipPath ?: @"").UTF8String,
                outDir.UTF8String,
                firmware_progress_callback
            );
            if (ret == 0) {
                int metaW = entry.lcdWidth > 0 ? entry.lcdWidth : 750;
                int metaH = entry.lcdHeight > 0 ? entry.lcdHeight : 1334;
                int metaDpi = entry.lcdDensity > 0 ? entry.lcdDensity : 320;
                NSString *defCmdline = [NSString stringWithFormat:@"qemu=1 androidboot.hardware=goldfish console=ttyS0 android.qemud=1 android.checkjni=0 ndns=1 qemu.gles=1 qemu.sf.lcd_density=%d qemu.hw.mainkeys=0", metaDpi];
                NSDictionary *meta = @{
                    @"platform": @"android",
                    @"entryId": entry.entryId ?: @"",
                    @"version": entry.version ?: @"",
                    @"variant": entry.variant ?: @"aosp",
                    @"api_level": @(entry.apiLevel),
                    @"ram_mb": @(entry.ramMB > 0 ? entry.ramMB : 512),
                    @"cpu": entry.cpu.length > 0 ? entry.cpu : @"cortex-a8",
                    @"width": @(metaW),
                    @"height": @(metaH),
                    @"dpi": @(metaDpi),
                    @"cmdline": entry.cmdline ?: defCmdline
                };
                NSData *metaData = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
                if (metaData) {
                    [metaData writeToFile:[outDir stringByAppendingPathComponent:@"android-metadata.json"] atomically:YES];
                }
            }
        } else {
            ret = lighttouch_firmware_create_with_options(
                catalogPath.UTF8String,
                entry.entryId.UTF8String,
                ipswURL.path.UTF8String,
                guestToolsPath.UTF8String,
                outDir.UTF8String,
                installCydia ? 1 : 0,
                firmware_progress_callback
            );
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.isPreparingBase = NO;
            [self hideProgress];
            if (ret == 0) {
                if (completion) completion();
            } else {
                [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
                const char *lastErr = lighttouch_firmware_last_error();
                NSString *detailMsg = (lastErr && strlen(lastErr) > 0) ? [NSString stringWithUTF8String:lastErr] : L(@"unknown_error_details");

                NSString *fullMsg = [NSString stringWithFormat:L(@"firmware_build_err_fmt"), ret, detailMsg];
                UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"storage_build_failed")
                                                                              message:fullMsg
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:fail animated:YES completion:nil];
            }
        });
    });
}

- (void)instantiateContainerWithId:(NSString *)cid name:(NSString *)name baseId:(NSString *)baseId entry:(CatalogEntry *)entry {
    VMContainer *c = [[VMContainer alloc] init];
    c.containerId = cid;
    c.name = name;
    c.baseId = baseId;
    c.productType = entry.productType ?: [self productTypeForId:baseId];
    c.version = entry.version ?: @"";
    c.build = entry.build ?: @"";
    c.platform = entry.platform.length > 0 ? entry.platform : ([baseId hasPrefix:@"fxos-"] ? @"firefoxos" : ([baseId hasPrefix:@"android-"] ? @"android" : @"ios"));
    if ([c.platform isEqualToString:@"android"] || [c.platform isEqualToString:@"firefoxos"]) {
        c.ramMB = entry.ramMB > 0 ? entry.ramMB : ([c.platform isEqualToString:@"firefoxos"] ? 768 : 512);
        c.lcdDensity = entry.lcdDensity > 0 ? entry.lcdDensity : 320;
        c.gpuMode = ([entry.cmdline containsString:@"qemu.gles=0"] ? -1 : 1);
    }
    c.createdAt = [[NSDate date] timeIntervalSince1970];

    // Create state directory
    NSString *statePath = [c statePathWithRoot:[self containersDirectory]];
    [[NSFileManager defaultManager] createDirectoryAtPath:statePath withIntermediateDirectories:YES attributes:nil error:nil];

    // Save container metadata
    [c saveMetadataWithRoot:[self containersDirectory]];

    [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self scanContainers];

    UIAlertController *done = [UIAlertController alertControllerWithTitle:L(@"container_created_title")
                                                                  message:[NSString stringWithFormat:L(@"container_ready_msg_fmt"), name]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:L(@"boot_now") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self bootContainer:c];
    }]];
    [done addAction:[UIAlertAction actionWithTitle:L(@"done") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

#pragma mark - Firmware Management (IPSW管理)

- (NSArray<VMContainer *> *)containersUsingEntryId:(NSString *)entryId {
    NSMutableArray<VMContainer *> *matches = [NSMutableArray array];
    NSString *jbId = [NSString stringWithFormat:@"%@-jb", entryId];
    for (VMContainer *c in self.containers) {
        if ([c.baseId isEqualToString:entryId] || [c.baseId isEqualToString:jbId]) {
            [matches addObject:c];
        }
    }
    return matches;
}

- (void)openSettings:(id)sender {
    [_haptic impactOccurred];
    SettingsViewController *settingsVC = [[SettingsViewController alloc] initWithMainViewController:self];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settingsVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)promptFirmwareManagement:(id)sender {
    [self promptFirmwareManagementFromViewController:nil];
}

- (void)promptFirmwareManagementFromViewController:(nullable UIViewController *)vc {
    [_haptic impactOccurred];
    UIViewController *presenter = vc ?: self;
    __weak typeof(self) weakSelf = self;
    [self ensureCatalogLoadedThen:^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        FirmwareManagementViewController *fwVC = [[FirmwareManagementViewController alloc] initWithMainVC:s];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fwVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [presenter presentViewController:nav animated:YES completion:nil];
    }];
}

- (NSUInteger)installedFirmwareCount {
    return [self scanDownloadedFirmwares].count;
}

- (NSUInteger)installedBootromCount {
    return [self scanInstalledBootromsFromDisk].count;
}

- (void)promptFirmwareActionsForFile:(FirmwareFile *)file {
    NSString *cleanName = [self humanReadableNameForId:file.entryId];
    NSArray<VMContainer *> *usedBy = [self containersUsingEntryId:file.entryId];
    NSMutableArray<NSString *> *usedNames = [NSMutableArray array];
    for (VMContainer *c in usedBy) {
        [usedNames addObject:c.name ?: c.containerId];
    }

    NSString *useDetail = usedBy.count > 0
        ? [NSString stringWithFormat:L(@"ipsw_in_use_fmt"), (unsigned long)usedBy.count, [usedNames componentsJoinedByString:L(@"comma_separator")]]
        : L(@"ipsw_in_use_none");

    NSString *msg = [NSString stringWithFormat:L(@"ipsw_detail_fmt"), file.fileName, (double)file.fileSizeBytes / (1024.0 * 1024.0), useDetail];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:cleanName
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:L(@"create_container_from_ipsw") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        CatalogEntry *ce = nil;
        for (CatalogEntry *c in self.catalogEntries) {
            if ([c.entryId isEqualToString:file.entryId]) {
                ce = c;
                break;
            }
        }
        if (!ce) {
            ce = [[CatalogEntry alloc] init];
            ce.entryId = file.entryId;
            ce.productType = file.productType;
            ce.version = file.version;
            ce.build = file.build;
        }
        [self promptContainerNameForEntry:ce deviceTitle:cleanName];
    }]];

    if (usedBy.count > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:L(@"cannot_delete_in_use") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UIAlertController *blocked = [UIAlertController alertControllerWithTitle:L(@"cannot_delete")
                                                                             message:[NSString stringWithFormat:L(@"ipsw_in_use_details_fmt"), [usedNames componentsJoinedByString:@"\n"]]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [blocked addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:blocked animated:YES completion:nil];
        }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:L(@"delete_ipsw_free_space") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:file.filePath error:nil];
            if (file.fileName.length > 0) {
                [fm removeItemAtPath:[[self firmwaresDirectory] stringByAppendingPathComponent:file.fileName] error:nil];
                [fm removeItemAtPath:[[self legacyIPSWDirectory] stringByAppendingPathComponent:file.fileName] error:nil];
            }
            [self promptFirmwareManagement:nil];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Local IPSW Picker

- (void)showDocumentPickerForIPSW {
    [self showDocumentPickerForIPSWForManagement:NO];
}

- (void)showDocumentPickerForIPSWForManagement:(BOOL)managementOnly {
    self.isPickingBootrom = NO;
    self.isImportingIPSWForManagement = managementOnly;
    NSArray *types = @[
        [UTType typeWithFilenameExtension:@"ipsw"] ?: UTTypeData,
        [UTType typeWithFilenameExtension:@"zip"] ?: UTTypeData,
        [UTType typeWithFilenameExtension:@"img"] ?: UTTypeData,
        [UTType typeWithFilenameExtension:@"gz"] ?: (UTTypeGZIP ?: UTTypeData)
    ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [TopPresentedViewController(self) presentViewController:picker animated:YES completion:nil];
}

#pragma mark - BootROM Management

- (void)promptBootromManagement:(id)sender {
    [self promptBootromManagementFromViewController:nil];
}

- (void)promptBootromManagementFromViewController:(nullable UIViewController *)vc {
    [_haptic impactOccurred];
    UIViewController *presenter = vc ?: self;
    BootromViewController *bVC = [[BootromViewController alloc] initWithMainVC:self];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:bVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)showBootromPicker {
    self.isPickingBootrom = YES;
    self.isImportingIPSWForManagement = NO;
    NSArray *types = @[ UTTypeItem, UTTypeData ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [TopPresentedViewController(self) presentViewController:picker animated:YES completion:nil];
}

- (void)installImportedBootromFromURL:(NSURL *)url
                             targetName:(NSString *)targetName
                               romLabel:(NSString *)romLabel
                                   size:(unsigned long long)sz {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = [self appDocumentsPath];
    NSString *romsDir = [docs stringByAppendingPathComponent:@"bootroms"];
    [fm createDirectoryAtPath:romsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *destDoc = [docs stringByAppendingPathComponent:targetName];
    NSString *destRoms = [romsDir stringByAppendingPathComponent:targetName];

    [fm removeItemAtPath:destDoc error:nil];
    [fm removeItemAtPath:destRoms error:nil];

    NSError *err = nil;
    BOOL ok = [fm copyItemAtPath:url.path toPath:destDoc error:&err];
    [fm copyItemAtPath:url.path toPath:destRoms error:nil];

    if (ok) {
        NSString *romType = @"s5l8900";
        self.cachedBootromPaths[romType] = destDoc;
        self.hasLoadedBootromCache = YES;
        [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
        [self updateRomButtonState];
        [self.tableView reloadData];
        if ([self.presentedViewController isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = ((UINavigationController *)self.presentedViewController).topViewController;
            if ([top isKindOfClass:[UITableViewController class]]) {
                [((UITableViewController *)top).tableView reloadData];
            }
        }
        NSString *msg = [NSString stringWithFormat:L(@"bootrom_imported_soc_msg"), romLabel, url.lastPathComponent, sz];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:L(@"bootrom_imported_title")
                                                                      message:msg
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter = self.presentedViewController ?: self;
        [presenter presentViewController:done animated:YES completion:nil];
    } else {
        [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
        UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"import_failed")
                                                                      message:err.localizedDescription
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter = self.presentedViewController ?: self;
        [presenter presentViewController:fail animated:YES completion:nil];
    }
}

- (void)handleImportedBootrom:(NSURL *)url {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:url.path error:nil];
    unsigned long long sz = [attrs fileSize];
    ClassicBootromSoC kind = ClassicClassifyBootromFile(url.path, nil);

    if (kind == ClassicBootromSoCS5L8900) {
        [self installImportedBootromFromURL:url targetName:@"bootrom_s5l8900" romLabel:L(@"bootrom_s5l8900_desc") size:sz];
        return;
    }

    [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
    UIAlertController *fail = [UIAlertController alertControllerWithTitle:L(@"bootrom_invalid_title")
                                                                  message:L(@"bootrom_invalid_msg")
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [fail addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *presenter = self.presentedViewController ?: self;
    [presenter presentViewController:fail animated:YES completion:nil];
}

- (void)handleImportedIPSWFromURL:(NSURL *)url presentingViewController:(nullable UIViewController *)presenter completion:(nullable void(^)(void))completion {
    UIViewController *hostVC = presenter ?: TopPresentedViewController(self);
    NSLog(@"[MainViewController] Processing imported IPSW: %@", url);

    [self showProgress:L(@"parsing_ipsw") detail:L(@"verifying_checksum")];
    self.cancelButton.hidden = YES;
    NSString *firmwaresDir = [self firmwaresDirectory];
    __weak typeof(self) weakSelf = self;
    [self ensureCatalogLoadedThen:^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        NSArray<CatalogEntry *> *catalogSnapshot = [s.catalogEntries copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *err = nil;
            NSString *sha1 = [IPSWDownloader computeSHA1ForFile:url error:&err];
            NSString *sha256 = [IPSWDownloader computeSHA256ForFile:url error:nil];
            CatalogEntry *matched = nil;
            NSString *matchedFileName = nil;
            for (CatalogEntry *ce in catalogSnapshot) {
                if ((ce.sha1.length == 64 && [ce.sha1 isEqualToString:sha256]) ||
                    (ce.sha1.length > 0 && [ce.sha1 isEqualToString:sha1])) {
                    matched = ce;
                    break;
                }
            }
            NSError *copyErr = nil;
            BOOL copied = NO;
            NSString *customInspectError = nil;
            NSDictionary *customMetaDict = nil;
            if (!matched) {
                NSString *extLower = url.pathExtension.lowercaseString;
                if ([extLower isEqualToString:@"ipsw"]) {
                    char *rawJson = lighttouch_ipsw_inspect(url.path.UTF8String);
                    if (rawJson) {
                        NSData *jData = [NSData dataWithBytes:rawJson length:strlen(rawJson)];
                        lighttouch_firmware_free_string(rawJson);
                        NSDictionary *info = [NSJSONSerialization JSONObjectWithData:jData options:0 error:nil];
                        if ([info isKindOfClass:[NSDictionary class]]) {
                            NSString *prodType = [info[@"product_type"] isKindOfClass:[NSString class]] ? info[@"product_type"] : @"";
                            NSString *boardCfg = [info[@"board_config"] isKindOfClass:[NSString class]] ? info[@"board_config"] : @"";
                            NSArray *boardCfgs = [info[@"board_configs"] isKindOfClass:[NSArray class]] ? info[@"board_configs"] : @[];
                            NSString *ver = [info[@"product_version"] isKindOfClass:[NSString class]] ? info[@"product_version"] : @"0.0";
                            NSString *bld = [info[@"product_build_version"] isKindOfClass:[NSString class]] ? info[@"product_build_version"] : @"custom";

                            NSMutableSet<NSString *> *supportedBoards = [NSMutableSet set];
                            for (CatalogEntry *ce in catalogSnapshot) {
                                if ([ce.platform isEqualToString:@"ios"] && ce.productType.length > 0) {
                                    // Map productType via board prefix or catalog entry
                                    if ([ce.entryId containsString:@"-" ]) {
                                        NSString *b = [[ce.entryId componentsSeparatedByString:@"-"] firstObject];
                                        if (b.length > 0) [supportedBoards addObject:b.lowercaseString];
                                    }
                                }
                            }
                            NSString *pickedBoard = nil;
                            if (boardCfg.length > 0 && [supportedBoards containsObject:boardCfg.lowercaseString]) {
                                pickedBoard = boardCfg.lowercaseString;
                            } else {
                                for (id bObj in boardCfgs) {
                                    if ([bObj isKindOfClass:[NSString class]] && [supportedBoards containsObject:[(NSString *)bObj lowercaseString]]) {
                                        pickedBoard = [(NSString *)bObj lowercaseString];
                                        break;
                                    }
                                }
                            }
                            CatalogEntry *templateEntry = nil;
                            for (CatalogEntry *ce in catalogSnapshot) {
                                if ([ce.platform isEqualToString:@"ios"] &&
                                    ((pickedBoard.length > 0 && [ce.entryId hasPrefix:[pickedBoard stringByAppendingString:@"-"]]) ||
                                     (prodType.length > 0 && [ce.productType isEqualToString:prodType]))) {
                                    templateEntry = ce;
                                    break;
                                }
                            }
                            if (templateEntry) {
                                NSString *tagBoard = pickedBoard ?: [[templateEntry.entryId componentsSeparatedByString:@"-"] firstObject];
                                NSCharacterSet *badChars = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
                                NSString *cleanVer = [[ver componentsSeparatedByCharactersInSet:badChars] componentsJoinedByString:@"_"];
                                NSString *cleanBld = [[bld componentsSeparatedByCharactersInSet:badChars] componentsJoinedByString:@"_"];
                                NSString *customId = [NSString stringWithFormat:@"custom-%@-%@-%@", tagBoard, cleanVer, cleanBld];

                                CatalogEntry *ce = [[CatalogEntry alloc] init];
                                ce.entryId = customId;
                                ce.platform = @"ios";
                                ce.productType = templateEntry.productType.length > 0 ? templateEntry.productType : prodType;
                                ce.version = ver;
                                ce.build = bld;
                                ce.sha1 = sha1 ?: @"";
                                unsigned long long fsize = [[[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil] fileSize];
                                ce.bytes = (int64_t)fsize;
                                matched = ce;
                                customMetaDict = @{
                                    @"id": customId,
                                    @"platform": @"ios",
                                    @"product_type": ce.productType ?: @"",
                                    @"version": ver,
                                    @"build": bld,
                                    @"sha1": ce.sha1,
                                    @"bytes": @(ce.bytes)
                                };
                            } else {
                                customInspectError = [NSString stringWithFormat:@"Unsupported device board %@ (%@) in IPSW Restore.plist.", boardCfg, prodType];
                            }
                        }
                    } else {
                        const char *le = lighttouch_firmware_last_error();
                        if (le && strlen(le) > 0) customInspectError = [NSString stringWithUTF8String:le];
                    }
                } else if ([extLower isEqualToString:@"zip"]) {
                    char *rawJson = lighttouch_android_inspect_zip(url.path.UTF8String);
                    if (rawJson) {
                        NSData *jData = [NSData dataWithBytes:rawJson length:strlen(rawJson)];
                        lighttouch_firmware_free_string(rawJson);
                        NSDictionary *info = [NSJSONSerialization JSONObjectWithData:jData options:0 error:nil];
                        if ([info isKindOfClass:[NSDictionary class]]) {
                            int api = [info[@"api_level"] intValue] > 0 ? [info[@"api_level"] intValue] : 19;
                            NSString *ver = [info[@"version"] isKindOfClass:[NSString class]] ? info[@"version"] : @"4.4";
                            NSString *romName = [info[@"rom_name"] isKindOfClass:[NSString class]] ? info[@"rom_name"] : @"";
                            if (romName.length == 0) {
                                romName = [url.lastPathComponent stringByDeletingPathExtension];
                            }
                            NSCharacterSet *badChars = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
                            NSString *cleanStem = [[[url.lastPathComponent stringByDeletingPathExtension] componentsSeparatedByCharactersInSet:badChars] componentsJoinedByString:@"_"];
                            if (cleanStem.length > 36) cleanStem = [cleanStem substringToIndex:36];
                            NSString *customId = [NSString stringWithFormat:@"custom-android-%d-%@", api, cleanStem];
                            int ramMB = (api >= 21) ? 1024 : ((api >= 19) ? 760 : 512);
                            NSString *cmdline = @"qemu=1 console=ttyS0 androidboot.console=ttyS0 androidboot.hardware=goldfish android.qemud=1 ndns=1 qemu.gles=1 qemu.sf.lcd_density=320 qemu.hw.mainkeys=0";
                            unsigned long long fsize = [[[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil] fileSize];

                            CatalogEntry *ce = [[CatalogEntry alloc] init];
                            ce.entryId = customId;
                            ce.platform = @"android";
                            ce.productType = @"AndroidARMv7";
                            ce.version = ver;
                            ce.build = romName;
                            ce.variant = @"custom";
                            ce.apiLevel = api;
                            ce.ramMB = ramMB;
                            ce.lcdWidth = 750;
                            ce.lcdHeight = 1334;
                            ce.lcdDensity = 320;
                            ce.cpu = @"cortex-a8";
                            ce.cmdline = cmdline;
                            ce.sha1 = sha1 ?: @"";
                            ce.bytes = (int64_t)fsize;
                            matched = ce;
                            customMetaDict = @{
                                @"id": customId,
                                @"platform": @"android",
                                @"product_type": @"AndroidARMv7",
                                @"version": ver,
                                @"build": romName,
                                @"variant": @"custom",
                                @"api_level": @(api),
                                @"ram_mb": @(ramMB),
                                @"width": @(750),
                                @"height": @(1334),
                                @"dpi": @(320),
                                @"cpu": @"cortex-a8",
                                @"cmdline": cmdline,
                                @"sha1": ce.sha1,
                                @"bytes": @(ce.bytes)
                            };
                        }
                    } else {
                        const char *le = lighttouch_firmware_last_error();
                        if (le && strlen(le) > 0) customInspectError = [NSString stringWithUTF8String:le];
                    }
                }
            }
            if (matched) {
                NSString *ext = ([matched.platform isEqualToString:@"firefoxos"] || [matched.platform isEqualToString:@"ubuntutouch"])
                    ? @"tar.gz"
                    : ([matched.platform isEqualToString:@"android"] ? @"zip" : @"ipsw");
                NSString *destName = matchedFileName ?: [NSString stringWithFormat:@"%@.%@", matched.entryId, ext];
                NSString *perm = [firmwaresDir stringByAppendingPathComponent:destName];
                NSString *tmpPerm = [firmwaresDir stringByAppendingPathComponent:[NSString stringWithFormat:@".importing-%@", destName]];
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtPath:tmpPerm error:nil];
                if ([fm copyItemAtPath:url.path toPath:tmpPerm error:&copyErr]) {
                    [fm removeItemAtPath:perm error:nil];
                    copied = [fm moveItemAtPath:tmpPerm toPath:perm error:&copyErr];
                }
                if (!copied) {
                    [fm removeItemAtPath:tmpPerm error:nil];
                } else if (customMetaDict) {
                    NSData *mData = [NSJSONSerialization dataWithJSONObject:customMetaDict options:NSJSONWritingPrettyPrinted error:nil];
                    if (mData) {
                        [mData writeToFile:[firmwaresDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.custom.json", matched.entryId]] atomically:YES];
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) ms = weakSelf;
                if (!ms) return;
                [ms hideProgress];
                if (matched && copied) {
                    [ms->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
                    if (completion) {
                        completion();
                    } else {
                        [ms promptContainerNameForEntry:matched deviceTitle:[ms humanReadableNameForId:matched.entryId]];
                    }
                } else if (matched) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"ipsw_read_failed")
                                                                                   message:copyErr.localizedDescription ?: L(@"ipsw_save_failed")
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                    [TopPresentedViewController(hostVC) presentViewController:alert animated:YES completion:nil];
                } else {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"unsupported_ipsw")
                                                                                   message:customInspectError ?: L(@"ipsw_sha1_mismatch")
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                    [TopPresentedViewController(hostVC) presentViewController:alert animated:YES completion:nil];
                }
            });
        });
    }];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    if (self.isPickingBootrom) {
        self.isPickingBootrom = NO;
        [self handleImportedBootrom:url];
        return;
    }

    BOOL managementOnly = self.isImportingIPSWForManagement;
    self.isImportingIPSWForManagement = NO;
    __weak typeof(self) weakSelf = self;
    [self handleImportedIPSWFromURL:url presentingViewController:nil completion:managementOnly ? ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s) [s promptFirmwareManagement:nil];
    } : nil];
}

#pragma mark - Progress Overlay UI

- (UIView *)progressOverlayHostView {
    return self.navigationController.view ?: self.view;
}

- (void)setNavigationBarControlsEnabled:(BOOL)enabled {
    self.navigationController.navigationBar.userInteractionEnabled = enabled;
    NSArray<UIBarButtonItem *> *left = self.navigationItem.leftBarButtonItems ?: @[];
    NSArray<UIBarButtonItem *> *right = self.navigationItem.rightBarButtonItems ?: @[];
    for (UIBarButtonItem *item in [left arrayByAddingObjectsFromArray:right]) {
        item.enabled = enabled;
        if ([item.customView isKindOfClass:[UIControl class]]) {
            ((UIControl *)item.customView).enabled = enabled;
        }
        item.customView.userInteractionEnabled = enabled;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.progressOverlay && !self.progressOverlay.hidden && self.progressOverlay.superview) {
        self.progressOverlay.frame = self.progressOverlay.superview.bounds;
    }
}

- (void)setupProgressOverlay {
    UIView *hostView = [self progressOverlayHostView];
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    self.progressOverlay = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.progressOverlay.frame = hostView.bounds;
    self.progressOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.progressOverlay.userInteractionEnabled = YES;
    self.progressOverlay.alpha = 0.0;
    self.progressOverlay.hidden = YES;
    [hostView addSubview:self.progressOverlay];

    UIVisualEffect *cardEffect = nil;
    BOOL isGlass = NO;
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (glassClass) {
        SEL sel = NSSelectorFromString(@"effectWithStyle:");
        if ([glassClass respondsToSelector:sel]) {
            UIVisualEffect *(*fn)(id, SEL, NSInteger) = (UIVisualEffect *(*)(id, SEL, NSInteger))[glassClass methodForSelector:sel];
            cardEffect = fn(glassClass, sel, 0);
            isGlass = (cardEffect != nil);
        }
    }
    if (!cardEffect) {
        cardEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    }

    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:cardEffect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 22.0;
    card.layer.masksToBounds = YES;
    if (!isGlass) {
        card.layer.borderWidth = 0.5;
        card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    }
    [self.progressOverlay.contentView addSubview:card];

    self.progressTitleLabel = [[UILabel alloc] init];
    self.progressTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressTitleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    self.progressTitleLabel.textColor = [UIColor whiteColor];
    self.progressTitleLabel.textAlignment = NSTextAlignmentCenter;
    [card.contentView addSubview:self.progressTitleLabel];

    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.tintColor = [UIColor systemBlueColor];
    [card.contentView addSubview:self.progressBar];

    self.progressDetailLabel = [[UILabel alloc] init];
    self.progressDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressDetailLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    self.progressDetailLabel.textColor = [UIColor secondaryLabelColor];
    self.progressDetailLabel.textAlignment = NSTextAlignmentCenter;
    self.progressDetailLabel.numberOfLines = 0;
    [card.contentView addSubview:self.progressDetailLabel];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cancelButton setTitle:L(@"cancel") forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(cancelCurrentOperation:) forControlEvents:UIControlEventTouchUpInside];
    [card.contentView addSubview:self.cancelButton];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.progressOverlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.progressOverlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300.0],

        [self.progressTitleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:20.0],
        [self.progressTitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [self.progressTitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],

        [self.progressBar.topAnchor constraintEqualToAnchor:self.progressTitleLabel.bottomAnchor constant:18.0],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],

        [self.progressDetailLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:12.0],
        [self.progressDetailLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [self.progressDetailLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],

        [self.cancelButton.topAnchor constraintEqualToAnchor:self.progressDetailLabel.bottomAnchor constant:16.0],
        [self.cancelButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [self.cancelButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16.0]
    ]];
}

- (void)showProgress:(NSString *)title detail:(NSString *)detail {
    self.progressToken++;
    [self.progressOverlay.layer removeAllAnimations];
    UIView *hostView = [self progressOverlayHostView];
    if (self.progressOverlay.superview != hostView) {
        [hostView addSubview:self.progressOverlay];
    }
    self.progressOverlay.frame = hostView.bounds;
    self.progressTitleLabel.text = title;
    self.progressDetailLabel.text = detail;
    self.progressBar.progress = 0.0f;
    self.progressOverlay.hidden = NO;
    [self setNavigationBarControlsEnabled:NO];
    [hostView bringSubviewToFront:self.progressOverlay];
    [UIView animateWithDuration:0.25 animations:^{
        self.progressOverlay.alpha = 1.0;
    }];
}

- (void)hideProgress {
    NSUInteger token = ++self.progressToken;
    [self.progressOverlay.layer removeAllAnimations];
    [self setNavigationBarControlsEnabled:YES];
    [UIView animateWithDuration:0.25 animations:^{
        self.progressOverlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (self.progressToken == token && self.progressOverlay.alpha < 0.05) {
            self.progressOverlay.hidden = YES;
        }
    }];
}

- (void)cancelCurrentOperation:(id)sender {
    if (self.isPreparingBase) {
        return;
    }
    self.isDownloadingOverlays = NO;
    self.progressToken += 1;
    [[IPSWDownloader sharedDownloader] cancel];
    [self hideProgress];
}

#pragma mark - Machine Execution

- (void)bootContainer:(VMContainer *)container {
    if (self.isCheckingJit || self.isPreparingBase) return;
    [_haptic impactOccurred];

    // Enforce single active container at a time
    if (self.activeEmulatorVC != nil || [self.presentedViewController isKindOfClass:[EmulatorViewController class]]) {
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeWarning];
        NSString *runningName = self.activeEmulatorVC.machineName ?: L(@"another_vm");
        UIAlertController *busy = [UIAlertController alertControllerWithTitle:L(@"already_running")
                                                                      message:[NSString stringWithFormat:L(@"vm_already_running_fmt"), runningName]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [busy addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:busy animated:YES completion:nil];
        return;
    }

    // Check BootROM requirement (S5L8900 for iPhone 2G / iPod touch 1G OS 1.x)
    NSString *requiredRom = [self requiredBootromTypeForIdentifier:container.baseId ?: container.productType];
    if (requiredRom && ![self hasInstalledBootromForIdentifier:container.baseId ?: container.productType]) {
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeWarning];
        NSString *romMsg = L(@"bootrom_required_s5l8900_msg");
        UIAlertController *romAlert = [UIAlertController alertControllerWithTitle:L(@"bootrom_required_title")
                                                                          message:romMsg
                                                                   preferredStyle:UIAlertControllerStyleAlert];

        [romAlert addAction:[UIAlertAction actionWithTitle:L(@"select_bootrom") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self showBootromPicker];
        }]];

        [romAlert addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:romAlert animated:YES completion:nil];
        return;
    }

    // Auto-upgrade any pre-v5 base affected by v3/v4 OpenGLES / sandbox_patch / N42 restore helper updates
    BOOL isWinRT = ([container.platform isEqualToString:@"winrt"] || [container.baseId hasPrefix:@"winrt-"] ||
                    [container.platform isEqualToString:@"chromeos"] || [container.baseId hasPrefix:@"chromeos-"] ||
                    [container.platform isEqualToString:@"ubuntutouch"] || [container.baseId hasPrefix:@"ut-virt-"]);
    if (!isWinRT && container.baseId.length > 0) {
        NSString *baseDir = [container basePathWithRoot:[self basesDirectory]];
        NSString *stateDir = [container statePathWithRoot:[self containersDirectory]];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isFirefoxOS = ([container.platform isEqualToString:@"firefoxos"] ||
                            [container.baseId hasPrefix:@"fxos-"]);
        BOOL isAndroid = (!isFirefoxOS &&
                          ([container.platform isEqualToString:@"android"] ||
                           [container.baseId hasPrefix:@"android-"] ||
                           [fm fileExistsAtPath:[baseDir stringByAppendingPathComponent:@"kernel-qemu"]]));
        BOOL isN42 = [container.baseId hasPrefix:@"n42ap-"];
        BOOL n42AlreadyInit = isN42 && [fm fileExistsAtPath:[stateDir stringByAppendingPathComponent:@".ppn_initialized"]];
        BOOL needsBaseUpgrade = isFirefoxOS
            ? ![self isFirefoxOSBasePrepV2Ready:baseDir entryId:container.baseId]
            : (!isAndroid && !n42AlreadyInit && ![self isBasePrepV11OrStableReady:baseDir entryId:container.baseId]);
        if (needsBaseUpgrade) {
            BOOL isJb = (!isFirefoxOS && [container.baseId hasSuffix:@"-jb"]);
            NSString *rawEntryId = isJb ? [container.baseId substringToIndex:container.baseId.length - 3] : container.baseId;
            __weak typeof(self) weakSelf = self;
            [self ensureCatalogLoadedThen:^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s || s.isPreparingBase) return;
                CatalogEntry *ce = [s catalogEntryWithId:rawEntryId];
                if (!ce) {
                    ce = [[CatalogEntry alloc] init];
                    ce.entryId = rawEntryId;
                    ce.platform = isFirefoxOS ? @"firefoxos" : container.platform;
                    ce.productType = container.productType ?: [s productTypeForId:rawEntryId];
                    ce.version = container.version ?: @"";
                    ce.build = container.build ?: @"";
                }
                NSString *localIPSW = [s findExistingIPSWForEntryId:rawEntryId];
                if (localIPSW) {
                    [s prepareBaseWithIPSW:[NSURL fileURLWithPath:localIPSW] entry:ce installCydia:isJb completion:^{
                        [fm removeItemAtPath:stateDir error:nil];
                        [fm createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:nil];
                        [s bootContainer:container];
                    }];
                } else {
                    UIAlertController *reb = [UIAlertController alertControllerWithTitle:L(@"base_rebuild_required")
                                                                                 message:L(@"base_rebuild_msg")
                                                                          preferredStyle:UIAlertControllerStyleAlert];
                    [reb addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                    [s presentViewController:reb animated:YES completion:nil];
                }
            }];
            return;
        }
    }

    if (self.hasConsumedEngineProcess) {
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeWarning];
        UIAlertController *restartAlert = [UIAlertController alertControllerWithTitle:L(@"restart_required_title")
                                                                                message:L(@"restart_required_msg")
                                                                         preferredStyle:UIAlertControllerStyleAlert];
        [restartAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:restartAlert animated:YES completion:nil];
        return;
    }

    // Run JIT / StikDebug probe off the main thread with timeout protection so disconnected/crashed StikDebug never freezes UI
    self.isCheckingJit = YES;
    self.tableView.userInteractionEnabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        bool timedOut = false;
        bool jitActive = ios_jit_is_available_detailed(1200, &timedOut);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.isCheckingJit = NO;
            s.tableView.userInteractionEnabled = YES;

            if (!jitActive) {
                [s->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeWarning];
                NSString *title = timedOut ? L(@"jit_timeout_title") : L(@"jit_required_title");
                NSString *msg = timedOut ? L(@"jit_timeout_msg") : L(@"jit_required_msg");
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                               message:msg
                                                                        preferredStyle:UIAlertControllerStyleAlert];

                [alert addAction:[UIAlertAction actionWithTitle:L(@"retry") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [s bootContainer:container];
                }]];

                [alert addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];

                [s presentViewController:alert animated:YES completion:nil];
                return;
            }

            if (s.hasConsumedEngineProcess) {
                [s->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeWarning];
                UIAlertController *restartAlert = [UIAlertController alertControllerWithTitle:L(@"restart_required_title")
                                                                                        message:L(@"restart_required_msg")
                                                                                 preferredStyle:UIAlertControllerStyleAlert];
                [restartAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleDefault handler:nil]];
                [s presentViewController:restartAlert animated:YES completion:nil];
                return;
            }

            [s launchEmulatorForContainer:container];
        });
    });
}

- (void)launchEmulatorForContainer:(VMContainer *)container {
    NSString *base = [container basePathWithRoot:[self basesDirectory]];
    NSString *state = [container statePathWithRoot:[self containersDirectory]];

    // Ensure state directory exists and is cleanly isolated
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];

    EmulatorViewController *emuVC = [[EmulatorViewController alloc] initWithMachineId:container.containerId
                                                                          machineName:container.name
                                                                         stateDirPath:state
                                                                          baseDirPath:base];
    emuVC.androidRamMB = container.ramMB;
    emuVC.androidLcdDensity = container.lcdDensity;
    emuVC.androidGpuMode = container.gpuMode;
    emuVC.platform = container.platform;
    emuVC.winrtDiskPath = container.winrtDiskPath;
    emuVC.winrtIsoPath = container.winrtIsoPath;
    emuVC.winrtBootFromIso = container.winrtBootFromIso;
    emuVC.winrtRtcDate = container.winrtRtcDate;
    emuVC.winrtEnableNet = container.winrtEnableNet;
    emuVC.winrtEnableAudio = container.winrtEnableAudio;
    __weak typeof(self) weakSelf = self;
    emuVC.onEngineProcessConsumed = ^{
        weakSelf.hasConsumedEngineProcess = YES;
    };
    emuVC.modalPresentationStyle = UIModalPresentationFullScreen;
    emuVC.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    self.activeEmulatorVC = emuVC;
    [self presentViewController:emuVC animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (UIView *)emptyStateViewForTableView:(UITableView *)tableView {
    if (!self.emptyStateView) {
        UIView *emptyView = [[UIView alloc] initWithFrame:tableView.bounds];

        NSString *emptyIconName = @"iphone";
        if (@available(iOS 16.0, *)) {
            emptyIconName = @"iphone.gen1";
        }
        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:emptyIconName]];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.tintColor = [UIColor systemBlueColor];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [emptyView addSubview:iv];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        titleLbl.text = L(@"no_containers");
        titleLbl.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
        titleLbl.textColor = [UIColor labelColor];
        titleLbl.textAlignment = NSTextAlignmentCenter;
        [emptyView addSubview:titleLbl];

        UILabel *subLbl = [[UILabel alloc] init];
        subLbl.translatesAutoresizingMaskIntoConstraints = NO;
        subLbl.text = L(@"no_containers_desc");
        subLbl.font = [UIFont systemFontOfSize:14.0];
        subLbl.textColor = [UIColor secondaryLabelColor];
        subLbl.textAlignment = NSTextAlignmentCenter;
        subLbl.numberOfLines = 0;
        [emptyView addSubview:subLbl];

        UIView *guideCard = [[UIView alloc] init];
        guideCard.translatesAutoresizingMaskIntoConstraints = NO;
        guideCard.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        guideCard.layer.cornerRadius = 14.0;
        [emptyView addSubview:guideCard];

        UILabel *guideLbl = [[UILabel alloc] init];
        guideLbl.translatesAutoresizingMaskIntoConstraints = NO;
        guideLbl.font = [UIFont systemFontOfSize:13.0];
        guideLbl.textColor = [UIColor secondaryLabelColor];
        guideLbl.numberOfLines = 0;
        guideLbl.text = L(@"how_to_use_footer");
        [guideCard addSubview:guideLbl];

        UIButton *createBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        createBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIButtonConfiguration *btnCfg = [UIButtonConfiguration filledButtonConfiguration];
        btnCfg.title = L(@"create_first_vm");
        btnCfg.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        btnCfg.imagePadding = 6.0;
        btnCfg.cornerStyle = UIButtonConfigurationCornerStyleLarge;
        btnCfg.contentInsets = NSDirectionalEdgeInsetsMake(12.0, 20.0, 12.0, 20.0);
        createBtn.configuration = btnCfg;
        [createBtn addTarget:self action:@selector(presentDeviceCreationWizard:) forControlEvents:UIControlEventTouchUpInside];
        [emptyView addSubview:createBtn];

        [NSLayoutConstraint activateConstraints:@[
            [iv.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor],
            [iv.centerYAnchor constraintEqualToAnchor:emptyView.centerYAnchor constant:-135.0],
            [iv.widthAnchor constraintEqualToConstant:44.0],
            [iv.heightAnchor constraintEqualToConstant:44.0],
            [titleLbl.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:10.0],
            [titleLbl.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor],
            [subLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:6.0],
            [subLbl.leadingAnchor constraintEqualToAnchor:emptyView.leadingAnchor constant:28.0],
            [subLbl.trailingAnchor constraintEqualToAnchor:emptyView.trailingAnchor constant:-28.0],
            [guideCard.topAnchor constraintEqualToAnchor:subLbl.bottomAnchor constant:16.0],
            [guideCard.leadingAnchor constraintEqualToAnchor:emptyView.leadingAnchor constant:24.0],
            [guideCard.trailingAnchor constraintEqualToAnchor:emptyView.trailingAnchor constant:-24.0],
            [guideLbl.topAnchor constraintEqualToAnchor:guideCard.topAnchor constant:12.0],
            [guideLbl.bottomAnchor constraintEqualToAnchor:guideCard.bottomAnchor constant:-12.0],
            [guideLbl.leadingAnchor constraintEqualToAnchor:guideCard.leadingAnchor constant:14.0],
            [guideLbl.trailingAnchor constraintEqualToAnchor:guideCard.trailingAnchor constant:-14.0],
            [createBtn.topAnchor constraintEqualToAnchor:guideCard.bottomAnchor constant:18.0],
            [createBtn.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor]
        ]];
        self.emptyStateView = emptyView;
    }
    return self.emptyStateView;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.hasCompletedInitialLoad && self.containers.count == 0) {
        tableView.backgroundView = nil;
        tableView.alwaysBounceVertical = NO;
        return 0;
    }
    if (self.containers.count == 0) {
        tableView.backgroundView = [self emptyStateViewForTableView:tableView];
        tableView.alwaysBounceVertical = NO;
    } else {
        tableView.backgroundView = nil;
        tableView.alwaysBounceVertical = YES;
    }
    return self.containers.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.containers.count > 0 ? L(@"vm_containers") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.containers.count > 0 ? L(@"main_footer") : nil;
}

- (void)playButtonTapped:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= 0 && idx < (NSInteger)self.containers.count) {
        [self bootContainer:self.containers[idx]];
    }
}

static UIImage *ClassicDeviceIconWithBadge(UIImage *symbol, UIColor *accentColor) {
    CGFloat sz = 44.0;
    CGFloat corner = 11.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(sz, sz) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, sz, sz);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:corner];
        [path addClip];

        CGContextRef c = ctx.CGContext;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat r1 = 0, g1 = 0, b1 = 0, a1 = 0;
        [accentColor getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
        
        UIColor *topColor = [UIColor colorWithRed:MIN(r1 * 1.15, 1.0) green:MIN(g1 * 1.15, 1.0) blue:MIN(b1 * 1.15, 1.0) alpha:0.18];
        UIColor *bottomColor = [UIColor colorWithRed:r1 * 0.9 green:g1 * 0.9 blue:b1 * 0.9 alpha:0.28];
        
        NSArray *colors = @[(id)topColor.CGColor, (id)bottomColor.CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(cs, (CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(0, sz), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(cs);

        // Subtle delicate border
        [[accentColor colorWithAlphaComponent:0.25] setStroke];
        path.lineWidth = 1.0;
        [path stroke];

        if (symbol) {
            UIImage *tinted = [symbol imageWithTintColor:accentColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            CGSize symSz = tinted.size;
            CGFloat x = (sz - symSz.width) * 0.5;
            CGFloat y = (sz - symSz.height) * 0.5;
            [tinted drawInRect:CGRectMake(x, y, symSz.width, symSz.height)];
        }
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"ContainerCell";
    static UIImage *sPlayImg = nil;
    static UIImage *sIphoneBadgeImg = nil;
    static UIImage *sIpadBadgeImg = nil;
    static UIImage *sIpodBadgeImg = nil;
    static UIImage *sAndroidBadgeImg = nil;
    static UIImage *sFirefoxBadgeImg = nil;
    static UIImage *sWinRTBadgeImg = nil;
    static UIImage *sChromeOSBadgeImg = nil;
    static UIImage *sUbuntuTouchBadgeImg = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIImageSymbolConfiguration *playCfg = [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightBold];
        sPlayImg = [UIImage systemImageNamed:@"play.fill" withConfiguration:playCfg];
        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:21.0 weight:UIImageSymbolWeightMedium];
        UIImage *rawIphone = [UIImage systemImageNamed:@"iphone" withConfiguration:symCfg];
        UIImage *rawIpad = [UIImage systemImageNamed:@"ipad" withConfiguration:symCfg];
        UIImage *rawIpod = [UIImage systemImageNamed:@"ipodtouch" withConfiguration:symCfg];
        UIImage *rawAndroid = [UIImage systemImageNamed:@"smartphone" withConfiguration:symCfg] ?: rawIphone;
        UIImage *rawFirefox = [UIImage systemImageNamed:@"flame.fill" withConfiguration:symCfg] ?: rawAndroid;
        UIImage *rawWinrt = [UIImage systemImageNamed:@"laptopcomputer" withConfiguration:symCfg] ?: rawIpad;
        UIImage *rawChromeOS = [UIImage systemImageNamed:@"globe" withConfiguration:symCfg] ?: rawWinrt;

        sIphoneBadgeImg = ClassicDeviceIconWithBadge(rawIphone, [UIColor systemBlueColor]);
        sIpadBadgeImg = ClassicDeviceIconWithBadge(rawIpad, [UIColor systemIndigoColor]);
        sIpodBadgeImg = ClassicDeviceIconWithBadge(rawIpod, [UIColor systemPurpleColor]);
        sAndroidBadgeImg = ClassicDeviceIconWithBadge(rawAndroid, [UIColor systemGreenColor]);
        sFirefoxBadgeImg = ClassicDeviceIconWithBadge(rawFirefox, [UIColor systemOrangeColor]);
        sWinRTBadgeImg = ClassicDeviceIconWithBadge(rawWinrt, [UIColor systemCyanColor]);
        sChromeOSBadgeImg = ClassicDeviceIconWithBadge(rawChromeOS, [UIColor systemTealColor]);
        sUbuntuTouchBadgeImg = ClassicDeviceIconWithBadge(rawIphone, [UIColor colorWithRed:0.91 green:0.33 blue:0.13 alpha:1.0]);
    });

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];

        UIButton *playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *playCfg = [UIButtonConfiguration filledButtonConfiguration];
        playCfg.image = sPlayImg;
        playCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        playCfg.baseBackgroundColor = [UIColor systemBlueColor];
        playCfg.baseForegroundColor = [UIColor whiteColor];
        playCfg.contentInsets = NSDirectionalEdgeInsetsMake(8.0, 9.0, 8.0, 7.0);
        playBtn.configuration = playCfg;
        playBtn.frame = CGRectMake(0, 0, 38, 38);
        playBtn.accessibilityLabel = L(@"boot_action");
        [playBtn addTarget:self action:@selector(playButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = playBtn;
    }

    if ([cell.accessoryView isKindOfClass:[UIButton class]]) {
        cell.accessoryView.tag = indexPath.row;
    }

    VMContainer *c = self.containers[indexPath.row];
    cell.textLabel.text = c.name;

    BOOL isChromeOS = ([c.platform isEqualToString:@"chromeos"] || [c.baseId hasPrefix:@"chromeos-"]);
    BOOL isUbuntuTouchVirt = ([c.platform isEqualToString:@"ubuntutouch"] || [c.baseId hasPrefix:@"ut-virt-"]);
    BOOL isWinRTOnly = ([c.platform isEqualToString:@"winrt"] || [c.baseId hasPrefix:@"winrt-"]);
    BOOL isWinRT = isWinRTOnly || isChromeOS || isUbuntuTouchVirt;
    BOOL isFirefoxOS = !isWinRT && ([c.platform isEqualToString:@"firefoxos"] || [c.baseId hasPrefix:@"fxos-"]);
    BOOL isAndroid = !isWinRT && (isFirefoxOS || ([c.platform isEqualToString:@"android"] || [c.baseId hasPrefix:@"android-"]));
    NSString *devClean = [self humanReadableNameForId:c.baseId];
    NSString *verPlatform = isChromeOS ? @"chromeos" : (isUbuntuTouchVirt ? @"ubuntutouch" : (isWinRTOnly ? @"winrt" : (isFirefoxOS ? @"firefoxos" : (isAndroid ? @"android" : c.platform))));
    NSString *verStr = c.version.length > 0 ? [self formattedOSVersion:c.version forPlatform:verPlatform] : @"";

    NSString *romTag = @"";
    BOOL romMissing = NO;
    if (!isAndroid && !isWinRT && [self requiredBootromTypeForIdentifier:c.baseId] != nil) {
        BOOL hasRom = [self hasInstalledBootromForIdentifier:c.baseId];
        romMissing = !hasRom;
        romTag = hasRom
            ? [NSString stringWithFormat:@" • %@", L(@"bootrom_ok")]
            : [NSString stringWithFormat:@" • %@", L(@"bootrom_missing")];
    }

    NSString *cydiaTag = (!isAndroid && !isWinRT && [c.baseId hasSuffix:@"-jb"]) ? @" • Cydia" : @"";
    NSString *variantTag = (isWinRT && c.winrtIsoPath.length > 0)
        ? [NSString stringWithFormat:@" • %@", c.winrtIsoPath.lastPathComponent]
        : ((isAndroid && c.build.length > 0) ? [NSString stringWithFormat:@" • %@", c.build] : @"");
    NSString *idTag = c.containerId.length > 0 ? [NSString stringWithFormat:@"\nID: %@", c.containerId] : @"";
    NSString *detailText = [NSString stringWithFormat:@"%@ • %@%@%@%@%@", devClean, verStr, variantTag, cydiaTag, romTag, idTag];
    if (romMissing) {
        NSMutableAttributedString *attrDetail = [[NSMutableAttributedString alloc] initWithString:detailText
                                                                                     attributes:@{
            NSForegroundColorAttributeName: [UIColor secondaryLabelColor]
        }];
        NSRange warnRange = [detailText rangeOfString:L(@"bootrom_missing")];
        if (warnRange.location != NSNotFound) {
            [attrDetail addAttribute:NSForegroundColorAttributeName value:[UIColor systemOrangeColor] range:warnRange];
            [attrDetail addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium] range:warnRange];
        }
        cell.detailTextLabel.attributedText = attrDetail;
    } else {
        cell.detailTextLabel.attributedText = nil;
        cell.detailTextLabel.text = detailText;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    // Modern cached badge icons based on device type
    if (isChromeOS) {
        cell.imageView.image = sChromeOSBadgeImg;
    } else if (isUbuntuTouchVirt) {
        cell.imageView.image = sUbuntuTouchBadgeImg;
    } else if (isWinRTOnly) {
        cell.imageView.image = sWinRTBadgeImg;
    } else if (isFirefoxOS) {
        cell.imageView.image = sFirefoxBadgeImg;
    } else if (isAndroid) {
        cell.imageView.image = sAndroidBadgeImg;
    } else if ([c.name containsString:@"iPad"] || [c.baseId containsString:@"iPad"]) {
        cell.imageView.image = sIpadBadgeImg;
    } else if ([c.name containsString:@"iPod"] || [c.baseId containsString:@"iPod"]) {
        cell.imageView.image = sIpodBadgeImg;
    } else {
        cell.imageView.image = sIphoneBadgeImg;
    }

    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row == destinationIndexPath.row) return;
    VMContainer *c = self.containers[sourceIndexPath.row];
    [self.containers removeObjectAtIndex:sourceIndexPath.row];
    [self.containers insertObject:c atIndex:destinationIndexPath.row];
    [self saveCustomContainerOrder];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    VMContainer *c = self.containers[indexPath.row];
    ContainerDetailViewController *detailVC = [[ContainerDetailViewController alloc] initWithContainer:c mainVC:self index:indexPath.row];
    [self.navigationController pushViewController:detailVC animated:YES];
}

// Leading swipe action: Rename container
- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    VMContainer *c = self.containers[indexPath.row];

    UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:L(@"rename") handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self promptRenameContainer:c];
        completionHandler(YES);
    }];
    renameAction.backgroundColor = [UIColor systemOrangeColor];
    renameAction.image = [UIImage systemImageNamed:@"pencil"];

    return [UISwipeActionsConfiguration configurationWithActions:@[renameAction]];
}

// Trailing swipe action: Delete container
- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    VMContainer *c = self.containers[indexPath.row];

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:L(@"delete") handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self confirmDeleteContainer:c indexPath:indexPath];
        completionHandler(YES);
    }];
    deleteAction.image = [UIImage systemImageNamed:@"trash.fill"];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

// Context menu (long-press): Boot / Copy ID / Rename / Delete
- (nullable UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    VMContainer *c = self.containers[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *bootAct = [UIAction actionWithTitle:L(@"boot_action") image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(__kindof UIAction *action) {
            [self bootContainer:c];
        }];
        UIAction *copyIdAct = [UIAction actionWithTitle:L(@"copy_container_id") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__kindof UIAction *action) {
            if (c.containerId.length > 0) {
                [UIPasteboard generalPasteboard].string = c.containerId;
                [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            }
        }];
        UIAction *renameAct = [UIAction actionWithTitle:L(@"rename_container_menu") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__kindof UIAction *action) {
            [self promptRenameContainer:c];
        }];
        UIAction *deleteAct = [UIAction actionWithTitle:L(@"delete") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__kindof UIAction *action) {
            [self confirmDeleteContainer:c indexPath:indexPath];
        }];
        deleteAct.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:c.name ?: @"" children:@[bootAct, copyIdAct, renameAct, deleteAct]];
    }];
}

#pragma mark - Rename & Delete Actions

- (void)promptRenameContainer:(VMContainer *)container {
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:L(@"rename_container_title")
                                                                    message:L(@"enter_new_name_prompt")
                                                             preferredStyle:UIAlertControllerStyleAlert];

    [prompt addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = container.name;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [prompt addAction:[UIAlertAction actionWithTitle:L(@"save") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *tf = prompt.textFields.firstObject;
        if (tf.text.length > 0) {
            container.name = tf.text;
            [container saveMetadataWithRoot:[self containersDirectory]];
            [self.tableView reloadData];
        }
    }]];

    [prompt addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)confirmDeleteContainer:(VMContainer *)container indexPath:(NSIndexPath *)indexPath {
    NSString *msg = [NSString stringWithFormat:L(@"delete_container_confirm_msg_fmt"), container.name];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"delete_container_confirm_title")
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:L(@"delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *cPath = [container containerPathWithRoot:[self containersDirectory]];
        [[NSFileManager defaultManager] removeItemAtPath:cPath error:nil];
        NSUInteger row = [self.containers indexOfObject:container];
        if (row != NSNotFound) {
            [self.containers removeObjectAtIndex:row];
            if (self.containers.count == 0) {
                [self.tableView reloadData];
            } else {
                [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
            }
        } else {
            [self scanContainers];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

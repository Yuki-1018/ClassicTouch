#import "MainViewController.h"
#import "EmulatorViewController.h"
#import "IPSWDownloader.h"
#import "ios_jit_helper.h"
#import "ios_bootrom_helper.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <stdlib.h>
#include <time.h>

#define L(key) NSLocalizedString((key), nil)

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
extern const char *lighttouch_firmware_last_error(void);
extern void lighttouch_firmware_free_string(char *s);

#pragma mark - Models

@interface VMContainer : NSObject
@property (nonatomic, copy) NSString *containerId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *baseId;
@property (nonatomic, copy) NSString *productType;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *build;
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

    NSDictionary *dict = @{
        @"id": self.containerId ?: @"",
        @"name": self.name ?: @"",
        @"baseId": self.baseId ?: @"",
        @"productType": self.productType ?: @"",
        @"version": self.version ?: @"",
        @"build": self.build ?: @"",
        @"createdAt": @(self.createdAt)
    };

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
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *fallbackUrl;
@property (nonatomic, copy) NSString *sha1;
@property (nonatomic, assign) int64_t bytes;
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
@property (nonatomic, strong) NSArray<CatalogEntry *> *catalogEntries;
@end

@interface ContainerDetailViewController : UITableViewController
@property (nonatomic, strong) VMContainer *container;
@property (nonatomic, weak) MainViewController *mainVC;
@property (nonatomic, assign) NSInteger containerIndex;
@property (nonatomic, copy) NSString *cachedDiskUsageText;
@end

@implementation ContainerDetailViewController

- (instancetype)initWithContainer:(VMContainer *)container mainVC:(MainViewController *)mainVC index:(NSInteger)index {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _container = container;
        _mainVC = mainVC;
        _containerIndex = index;
        _cachedDiskUsageText = @"計算中...";
    }
    return self;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        BOOL requiresBootrom = ([self.mainVC requiredBootromTypeForIdentifier:self.container.baseId] != nil);
        return requiresBootrom ? 6 : 5;
    }
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? L(@"section_info") : L(@"section_actions");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"コンテナ ID";
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
                ? [NSString stringWithFormat:@"%@ (%@)", [self.mainVC formattedOSVersion:self.container.version], self.container.build ?: @""]
                : @"-";
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"構成";
            cell.detailTextLabel.text = [self.container.baseId hasSuffix:@"-jb"] ? @"Cydia入り" : @"標準";
        } else if (indexPath.row == 4) {
            cell.textLabel.text = L(@"storage_used");
            cell.detailTextLabel.text = self.cachedDiskUsageText ?: @"-";
        } else {
            NSString *romType = [self.mainVC requiredBootromTypeForIdentifier:self.container.baseId];
            cell.textLabel.text = [romType isEqualToString:@"s5l8720"] ? @"BootROM (S5L8720)" : @"BootROM (S5L8900)";
            BOOL ok = [self.mainVC hasInstalledBootromForIdentifier:self.container.baseId];
            cell.detailTextLabel.text = ok ? L(@"installed") : L(@"not_installed");
            cell.detailTextLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
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
            UIAlertController *copiedAlert = [UIAlertController alertControllerWithTitle:@"コピー完了"
                                                                                 message:[NSString stringWithFormat:@"コンテナ ID をコピーしました:\n%@", self.container.containerId]
                                                                          preferredStyle:UIAlertControllerStyleAlert];
            [copiedAlert addAction:[UIAlertAction actionWithTitle:L(@"ok") style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:copiedAlert animated:YES completion:nil];
        }
        return;
    }
    if (indexPath.section != 1) return;

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
        if (logText.length == 0) {
            logText = L(@"no_serial_log");
        } else if (logText.length > 4000) {
            logText = [logText substringFromIndex:logText.length - 4000];
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
    return UIInterfaceOrientationMaskPortrait;
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
    if (section == 0) return 2;
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
        NSString *romType = (indexPath.row == 0) ? @"s5l8900" : @"s5l8720";
        NSString *path = [self.mainVC pathForInstalledBootromType:romType];
        cell.textLabel.text = (indexPath.row == 0) ? @"S5L8900 (iPhone 2G / iPod touch 1G)" : @"S5L8720 (iPod touch 2G)";
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

@interface FirmwareManagementViewController : UITableViewController
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
    return UIInterfaceOrientationMaskPortrait;
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
        cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)", [self.mainVC humanReadableNameForId:f.entryId], [self.mainVC formattedOSVersion:f.version]];
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
        @{@"title": @"iPhone 2G (iPhone OS 1.0〜3.1.3 / 要BootROM)", @"type": @"iPhone1,1"},
        @{@"title": @"iPhone 3GS (iPhone OS 3.0〜iOS 6.1.6)", @"type": @"iPhone2,1"},
        @{@"title": @"iPhone 4 (iOS 4.0〜7.1.2)", @"type": @"iPhone3,1"},
        @{@"title": @"iPod touch 1G (iPhone OS 1.1〜3.1.3 / 要BootROM)", @"type": @"iPod1,1"},
        @{@"title": @"iPod touch 2G (iPhone OS 2.1.1〜iOS 4.2.1 / 要BootROM)", @"type": @"iPod2,1"},
        @{@"title": @"iPod touch 3G (iPhone OS 3.1.1〜iOS 5.1.1)", @"type": @"iPod3,1"},
        @{@"title": @"iPod touch 4G (iOS 4.1〜6.1.6)", @"type": @"iPod4,1"},
        @{@"title": @"iPad 第1世代 (iPhone OS 3.2〜iOS 5.1.1)", @"type": @"iPad1,1"}
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

- (void)presentCatalogDownloadVersionPickerForProductType:(NSString *)prodType deviceTitle:(NSString *)deviceTitle sourceCell:(nullable UITableViewCell *)sourceCell {
    NSMutableArray<CatalogEntry *> *filtered = [NSMutableArray array];
    for (CatalogEntry *ce in self.mainVC.catalogEntries) {
        if ([ce.productType isEqualToString:prodType]) {
            [filtered addObject:ce];
        }
    }

    UIAlertController *versionSelect = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:L(@"select_os_title"), deviceTitle]
                                                                           message:L(@"download_catalog_version_msg")
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
    for (CatalogEntry *ce in filtered) {
        NSString *existing = [self.mainVC findExistingIPSWForEntryId:ce.entryId];
        NSString *tag = existing
            ? [NSString stringWithFormat:@" [%@]", L(@"downloaded_badge")]
            : [NSString stringWithFormat:@" (%.0f MB)", (double)ce.bytes / (1024.0 * 1024.0)];
        NSString *btnTitle = [NSString stringWithFormat:@"%@ (%@)%@", [self.mainVC formattedOSVersion:ce.version], ce.build, tag];
        [versionSelect addAction:[UIAlertAction actionWithTitle:btnTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (existing) {
                UIAlertController *redl = [UIAlertController alertControllerWithTitle:L(@"redownload_ipsw_title")
                                                                              message:[NSString stringWithFormat:L(@"redownload_ipsw_msg"), ce.version, ce.build]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [redl addAction:[UIAlertAction actionWithTitle:L(@"redownload_action") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
                    [self dismissViewControllerAnimated:YES completion:^{
                        [self.mainVC downloadCatalogIPSWForManagement:ce];
                    }];
                }]];
                [redl addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:redl animated:YES completion:nil];
            } else {
                [self dismissViewControllerAnimated:YES completion:^{
                    [self.mainVC downloadCatalogIPSWForManagement:ce];
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
            [self dismissViewControllerAnimated:YES completion:^{
                [self.mainVC showDocumentPickerForIPSWForManagement:YES];
            }];
        }
        return;
    }
    if (self.firmwares.count == 0) return;

    FirmwareFile *f = self.firmwares[indexPath.row];
    NSString *cleanName = [self.mainVC humanReadableNameForId:f.entryId];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:cleanName
                                                                   message:[NSString stringWithFormat:@"iOS %@ (%.1f MB)", f.version ?: @"", (double)f.fileSizeBytes / (1024.0 * 1024.0)]
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
        }
        [self dismissViewControllerAnimated:YES completion:^{
            [self.mainVC promptContainerNameForEntry:ce deviceTitle:cleanName];
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

@end

static __weak MainViewController *sCurrentMainVC = nil;

@implementation MainViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return NO;
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
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    _notifyHaptic = [[UINotificationFeedbackGenerator alloc] init];

    // Left Bar Button: Firmware (IPSW) Management with clear label + Reorder (Edit)
    UIButton *fwNavBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *fwCfg = [UIButtonConfiguration plainButtonConfiguration];
    fwCfg.image = [UIImage systemImageNamed:@"externaldrive" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightMedium]];
    fwCfg.title = @"IPSW";
    fwCfg.imagePadding = 4.0;
    fwCfg.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 4.0, 4.0, 4.0);
    fwNavBtn.configuration = fwCfg;
    fwNavBtn.accessibilityLabel = @"IPSW管理";
    [fwNavBtn addTarget:self action:@selector(promptFirmwareManagement:) forControlEvents:UIControlEventTouchUpInside];
    self.firmwareBtn = [[UIBarButtonItem alloc] initWithCustomView:fwNavBtn];
    self.navigationItem.leftBarButtonItems = @[self.firmwareBtn, self.editButtonItem];

    // Right Bar Buttons: Add Device (+ 作成) and BootROM (ROM)
    UIButton *addNavBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *addCfg = [UIButtonConfiguration tintedButtonConfiguration];
    addCfg.image = [UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightBold]];
    addCfg.title = @"作成";
    addCfg.imagePadding = 3.5;
    addCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    addCfg.contentInsets = NSDirectionalEdgeInsetsMake(5.0, 10.0, 5.0, 10.0);
    addNavBtn.configuration = addCfg;
    addNavBtn.accessibilityLabel = @"新規仮想マシンを作成";
    [addNavBtn addTarget:self action:@selector(presentDeviceCreationWizard:) forControlEvents:UIControlEventTouchUpInside];
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithCustomView:addNavBtn];

    self.romNavButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.romNavButton addTarget:self action:@selector(promptBootromManagement:) forControlEvents:UIControlEventTouchUpInside];
    self.romBtn = [[UIBarButtonItem alloc] initWithCustomView:self.romNavButton];
    self.navigationItem.rightBarButtonItems = @[addBtn, self.romBtn];

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
        UIAlertController *notice = [UIAlertController alertControllerWithTitle:@"ご利用前のご注意"
                                                                        message:@"• コンテナの初回起動時は初期セットアップ処理のため失敗することがあります。その場合は再起動またはコンテナの再作成をお試しください。\n\n• StikDebug で JIT を有効化する際は、スクリプトに「universal.js」を使用してください。"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:@"OK（今後は表示しない）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleTools = [self guestToolsDirectory];
    NSString *docTools = [[self appDocumentsPath] stringByAppendingPathComponent:@"guest-tools"];
    NSString *bundleVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"1";
    NSString *verKey = @"ClassicTouchGuestToolsBundleVer_v1";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if ([fm fileExistsAtPath:docTools] && [[defaults stringForKey:verKey] isEqualToString:bundleVer]) {
        return;
    }

    if (bundleTools && ![bundleTools isEqualToString:docTools] && [fm fileExistsAtPath:bundleTools]) {
        if (![fm fileExistsAtPath:docTools]) {
            [fm copyItemAtPath:bundleTools toPath:docTools error:nil];
        } else {
            NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:bundleTools error:nil];
            for (NSString *item in items) {
                NSString *src = [bundleTools stringByAppendingPathComponent:item];
                NSString *dst = [docTools stringByAppendingPathComponent:item];
                NSDictionary *srcAttr = [fm attributesOfItemAtPath:src error:nil];
                NSDictionary *dstAttr = [fm attributesOfItemAtPath:dst error:nil];
                if (!dstAttr || ![srcAttr[NSFileSize] isEqual:dstAttr[NSFileSize]] ||
                    [srcAttr[NSFileModificationDate] compare:dstAttr[NSFileModificationDate]] == NSOrderedDescending) {
                    [fm removeItemAtPath:dst error:nil];
                    [fm copyItemAtPath:src toPath:dst error:nil];
                }
            }
        }
        [defaults setObject:bundleVer forKey:verKey];
    }
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
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"guest-tools" ofType:nil];
    if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        return bundlePath;
    }
    bundlePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"guest-tools"];
    if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        return bundlePath;
    }
    bundlePath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"guest-tools"];
    if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        return bundlePath;
    }
    return [[self appDocumentsPath] stringByAppendingPathComponent:@"guest-tools"];
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

- (NSArray<FirmwareFile *> *)scanDownloadedFirmwares {
    NSMutableArray<FirmwareFile *> *res = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *searchDirs = @[ [self firmwaresDirectory], [self legacyIPSWDirectory] ];

    NSMutableSet<NSString *> *seenFiles = [NSMutableSet set];
    for (NSString *dir in searchDirs) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            if ([f.pathExtension.lowercaseString isEqualToString:@"ipsw"]) {
                if ([seenFiles containsObject:f]) continue;
                [seenFiles addObject:f];

                NSString *full = [dir stringByAppendingPathComponent:f];
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                NSString *entryId = [f stringByDeletingPathExtension];

                FirmwareFile *ff = [[FirmwareFile alloc] init];
                ff.fileName = f;
                ff.filePath = full;
                ff.entryId = entryId;
                ff.fileSizeBytes = attrs.fileSize;

                // Match with catalog entry
                for (CatalogEntry *ce in self.catalogEntries) {
                    if ([ce.entryId isEqualToString:entryId]) {
                        ff.version = ce.version;
                        ff.build = ce.build;
                        ff.productType = ce.productType;
                        break;
                    }
                }
                [res addObject:ff];
            }
        }
    }
    return [res copy];
}

- (nullable NSString *)findExistingIPSWForEntryId:(NSString *)entryId {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *p1 = [[self firmwaresDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipsw", entryId]];
    if ([fm fileExistsAtPath:p1]) return p1;
    NSString *p2 = [[self legacyIPSWDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipsw", entryId]];
    if ([fm fileExistsAtPath:p2]) return p2;
    return nil;
}

- (BOOL)hasPreparedBaseForEntryId:(NSString *)entryId {
    NSString *base = [[self basesDirectory] stringByAppendingPathComponent:entryId];
    NSString *lock = [base stringByAppendingPathComponent:@"lock.json"];
    return [[NSFileManager defaultManager] fileExistsAtPath:lock];
}

#pragma mark - BootROM State

- (nullable NSString *)requiredBootromTypeForIdentifier:(NSString *)identifier {
    if (!identifier.length) return nil;
    if ([identifier containsString:@"m68"] || [identifier containsString:@"iPhone1,1"] ||
        [identifier containsString:@"n45"] || [identifier containsString:@"iPod1,1"]) {
        return @"s5l8900";
    }
    if ([identifier containsString:@"n72"] || [identifier containsString:@"iPod2,1"]) {
        return @"s5l8720";
    }
    return nil;
}

- (nullable NSString *)scanPathForInstalledBootromTypeOnDisk:(NSString *)romType {
    if (!romType.length) return nil;
    NSString *docs = [self appDocumentsPath];
    NSString *romsDir = [docs stringByAppendingPathComponent:@"bootroms"];
    NSArray<NSString *> *names = nil;

    if ([romType isEqualToString:@"s5l8900"]) {
        names = @[@"bootrom_s5l8900", @"bootrom_s5l8900.bin", @"s5l8900.bin", @"s5l8900-bootrom.bin", @"bootrom.bin"];
    } else if ([romType isEqualToString:@"s5l8720"]) {
        names = @[@"bootrom_240_4", @"bootrom_240_4.bin", @"bootrom.bin"];
    } else {
        return nil;
    }

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
    NSString *s5l8720 = [self scanPathForInstalledBootromTypeOnDisk:@"s5l8720"];
    if (s5l8720) map[@"s5l8720"] = s5l8720;
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
    return ([self pathForInstalledBootromType:@"s5l8900"] != nil ||
            [self pathForInstalledBootromType:@"s5l8720"] != nil);
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
    self.romNavButton.accessibilityLabel = installed ? @"BootROM: 選択済み" : @"BootROM: 未選択";
}

#pragma mark - Device & OS Names

- (NSString *)formattedOSVersion:(NSString *)version {
    if (!version || version.length == 0) return @"";
    if ([version hasPrefix:@"1."] || [version isEqualToString:@"1"] ||
        [version hasPrefix:@"2."] || [version isEqualToString:@"2"] ||
        [version hasPrefix:@"3."] || [version isEqualToString:@"3"]) {
        return [NSString stringWithFormat:@"iPhone OS %@", version];
    }
    return [NSString stringWithFormat:@"iOS %@", version];
}

- (NSString *)humanReadableNameForId:(NSString *)sub {
    if ([sub containsString:@"iPad1,1"] || [sub containsString:@"k48ap"]) return @"iPad (第1世代)";
    if ([sub containsString:@"iPhone1,1"] || [sub containsString:@"m68ap"]) return @"iPhone (初代 2G)";
    if ([sub containsString:@"iPhone2,1"] || [sub containsString:@"n88ap"]) return @"iPhone 3GS";
    if ([sub containsString:@"iPhone3,1"] || [sub containsString:@"n90ap"]) return @"iPhone 4";
    if ([sub containsString:@"iPod1,1"] || [sub containsString:@"n45ap"]) return @"iPod touch (第1世代)";
    if ([sub containsString:@"iPod2,1"] || [sub containsString:@"n72ap"]) return @"iPod touch (第2世代)";
    if ([sub containsString:@"iPod3,1"] || [sub containsString:@"n18ap"]) return @"iPod touch (第3世代)";
    if ([sub containsString:@"iPod4,1"] || [sub containsString:@"n81ap"]) return @"iPod touch (第4世代)";
    return sub;
}

- (NSString *)productTypeForId:(NSString *)sub {
    if ([sub containsString:@"iPad1,1"] || [sub containsString:@"k48ap"]) return @"iPad1,1";
    if ([sub containsString:@"iPhone1,1"] || [sub containsString:@"m68ap"]) return @"iPhone1,1";
    if ([sub containsString:@"iPhone2,1"] || [sub containsString:@"n88ap"]) return @"iPhone2,1";
    if ([sub containsString:@"iPhone3,1"] || [sub containsString:@"n90ap"]) return @"iPhone3,1";
    if ([sub containsString:@"iPod1,1"] || [sub containsString:@"n45ap"]) return @"iPod1,1";
    if ([sub containsString:@"iPod2,1"] || [sub containsString:@"n72ap"]) return @"iPod2,1";
    if ([sub containsString:@"iPod3,1"] || [sub containsString:@"n18ap"]) return @"iPod3,1";
    if ([sub containsString:@"iPod4,1"] || [sub containsString:@"n81ap"]) return @"iPod4,1";
    return @"";
}

#pragma mark - Step-by-Step Creation Wizard (端末 -> OS -> コンテナ名)

- (BOOL)supportsCydiaForEntry:(CatalogEntry *)entry {
    NSString *pt = entry.productType ?: @"";
    NSString *eid = entry.entryId ?: @"";
    BOOL supportedBoard = ([pt isEqualToString:@"iPhone2,1"] || [eid containsString:@"n88ap"] ||
                           [pt isEqualToString:@"iPhone3,1"] || [eid containsString:@"n90ap"] ||
                           [pt isEqualToString:@"iPod3,1"] || [eid containsString:@"n18ap"] ||
                           [pt isEqualToString:@"iPod4,1"] || [eid containsString:@"n81ap"] ||
                           [pt isEqualToString:@"iPad1,1"] || [eid containsString:@"k48ap"]);
    if (!supportedBoard) return NO;
    NSInteger major = [[entry.version componentsSeparatedByString:@"."].firstObject integerValue];
    return major >= 2;
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
    UIAlertController *deviceSelect = [UIAlertController alertControllerWithTitle:@"新規コンテナ作成: 端末の選択"
                                                                          message:@"エミュレートするAppleデバイスを選択してください:"
                                                                   preferredStyle:UIAlertControllerStyleActionSheet];

    NSDictionary *devices = @{
        @"iPhone 2G (iPhone OS 1.0〜3.1.3 / 要BootROM)": @"iPhone1,1",
        @"iPhone 3GS (iPhone OS 3.0〜iOS 6.1.6)": @"iPhone2,1",
        @"iPhone 4 (iOS 4.0〜7.1.2)": @"iPhone3,1",
        @"iPod touch 1G (iPhone OS 1.1〜3.1.3 / 要BootROM)": @"iPod1,1",
        @"iPod touch 2G (iPhone OS 2.1.1〜iOS 4.2.1 / 要BootROM)": @"iPod2,1",
        @"iPod touch 3G (iPhone OS 3.1.1〜iOS 5.1.1)": @"iPod3,1",
        @"iPod touch 4G (iOS 4.1〜6.1.6)": @"iPod4,1",
        @"iPad 第1世代 (iPhone OS 3.2〜iOS 5.1.1)": @"iPad1,1"
    };

    NSArray *deviceOrder = @[
        @"iPhone 2G (iPhone OS 1.0〜3.1.3 / 要BootROM)",
        @"iPhone 3GS (iPhone OS 3.0〜iOS 6.1.6)",
        @"iPhone 4 (iOS 4.0〜7.1.2)",
        @"iPod touch 1G (iPhone OS 1.1〜3.1.3 / 要BootROM)",
        @"iPod touch 2G (iPhone OS 2.1.1〜iOS 4.2.1 / 要BootROM)",
        @"iPod touch 3G (iPhone OS 3.1.1〜iOS 5.1.1)",
        @"iPod touch 4G (iOS 4.1〜6.1.6)",
        @"iPad 第1世代 (iPhone OS 3.2〜iOS 5.1.1)"
    ];

    for (NSString *title in deviceOrder) {
        NSString *prodType = devices[title];
        [deviceSelect addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self showVersionPickerForProductType:prodType deviceTitle:title];
        }]];
    }

    [deviceSelect addAction:[UIAlertAction actionWithTitle:@"ローカルIPSWファイルを選択..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showDocumentPickerForIPSW];
    }]];

    [deviceSelect addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];

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

    UIAlertController *versionSelect = [UIAlertController alertControllerWithTitle:@"OSバージョンの選択"
                                                                           message:[NSString stringWithFormat:@"%@\nインストールするiOSバージョンを選択してください:", deviceTitle]
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];

    for (CatalogEntry *ce in filtered) {
        NSString *jbId = [NSString stringWithFormat:@"%@-jb", ce.entryId];
        BOOL baseExists = [self hasPreparedBaseForEntryId:ce.entryId];
        BOOL jbExists = [self hasPreparedBaseForEntryId:jbId];
        NSString *localIPSW = [self findExistingIPSWForEntryId:ce.entryId];

        NSString *tag = @"";
        if (baseExists && jbExists) {
            tag = @" [準備済み / Cydia]";
        } else if (jbExists) {
            tag = @" [Cydia準備済み]";
        } else if (baseExists) {
            tag = @" [準備済み]";
        } else if (localIPSW) {
            tag = @" [取得済み]";
        } else {
            tag = [NSString stringWithFormat:@" (%.0f MB)", (double)ce.bytes / (1024.0 * 1024.0)];
        }

        NSString *btnTitle = [NSString stringWithFormat:@"%@ (%@)%@", [self formattedOSVersion:ce.version], ce.build, tag];
        [versionSelect addAction:[UIAlertAction actionWithTitle:btnTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self promptContainerNameForEntry:ce deviceTitle:deviceTitle];
        }]];
    }

    [versionSelect addAction:[UIAlertAction actionWithTitle:@"機種選択に戻る" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self presentDeviceCreationWizard:nil];
    }]];
    [versionSelect addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    if (versionSelect.popoverPresentationController) {
        versionSelect.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    }
    [self presentViewController:versionSelect animated:YES completion:nil];
}

- (void)promptContainerNameForEntry:(CatalogEntry *)entry deviceTitle:(NSString *)deviceTitle {
    // Step 3: Enter Container Name (UTM-like) & Cydia option
    NSString *cleanDevice = [self humanReadableNameForId:entry.entryId];
    NSString *defaultName = [NSString stringWithFormat:@"%@ (%@)", cleanDevice, [self formattedOSVersion:entry.version]];
    BOOL canCydia = [self supportsCydiaForEntry:entry];

    NSString *msg = canCydia
        ? @"名前を入力し、構成を選択してください（名前はあとで変更できます）。\n※「Cydia入り」は脱獄環境・ツール追加向けで、初回のみ約10MBの追加データを使用します。"
        : @"仮想マシンの名前を入力してください（あとから変更できます）:";

    UIAlertController *namePrompt = [UIAlertController alertControllerWithTitle:@"仮想マシンの名前と構成"
                                                                        message:msg
                                                                 preferredStyle:UIAlertControllerStyleAlert];

    [namePrompt addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = defaultName;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    if (canCydia) {
        NSString *stockTitle = [self hasPreparedBaseForEntryId:entry.entryId] ? @"標準で作成 [準備済み]" : @"標準で作成（おすすめ）";
        NSString *jbId = [NSString stringWithFormat:@"%@-jb", entry.entryId];
        NSString *jbTitle = [self hasPreparedBaseForEntryId:jbId] ? @"Cydia入りで作成 [準備済み]" : @"Cydia入りで作成（脱獄）";

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
    } else {
        [namePrompt addAction:[UIAlertAction actionWithTitle:@"作成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UITextField *tf = namePrompt.textFields.firstObject;
            NSString *chosenName = tf.text.length > 0 ? tf.text : defaultName;
            [self executeContainerCreationForEntry:entry containerName:chosenName installCydia:NO];
        }]];
    }

    [namePrompt addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:namePrompt animated:YES completion:nil];
}

- (void)executeContainerCreationForEntry:(CatalogEntry *)entry containerName:(NSString *)containerName installCydia:(BOOL)installCydia {
    // Generate unique container ID
    NSString *cid = [NSString stringWithFormat:@"vm-%@-%ld", entry.entryId, (long)[[NSDate date] timeIntervalSince1970] % 100000];
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

- (nullable CatalogEntry *)catalogEntryWithId:(NSString *)entryId {
    if (entryId.length == 0) return nil;
    for (CatalogEntry *entry in self.catalogEntries) {
        if ([entry.entryId isEqualToString:entryId]) {
            return entry;
        }
    }
    return nil;
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
    NSString *displayTitle = metadata[@"displayTitle"] ?: entryId ?: @"IPSW";
    if (!self.isCatalogLoaded && !managementOnly && entryId.length > 0) {
        __weak typeof(self) weakSelf = self;
        [self ensureCatalogLoadedThen:^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s handleCompletedIPSWDownloadAtURL:localURL error:error metadata:metadata fromPending:fromPending];
        }];
        return;
    }
    CatalogEntry *entry = [self catalogEntryWithId:entryId];

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
        NSString *title = downloader.displayTitle ?: downloader.downloadId ?: @"IPSW";
        NSString *detail = L(@"ipsw_bg_reattached_detail");
        if (downloader.lastTotalBytesExpected > 0 && downloader.lastTotalBytesWritten > 0) {
            detail = [NSString stringWithFormat:L(@"ipsw_bg_progress_detail"),
                      (double)downloader.lastTotalBytesWritten / 1048576.0,
                      (double)downloader.lastTotalBytesExpected / 1048576.0,
                      downloader.lastSpeedMBs];
        }
        [self showProgress:[NSString stringWithFormat:@"ダウンロード中: %@", title] detail:detail];
        self.progressBar.progress = (float)downloader.lastFractionCompleted;
        [self attachToActiveBackgroundDownload];
    }
}

- (void)startIPSWDownloadForEntry:(CatalogEntry *)entry metadata:(NSDictionary *)metadata {
    [_haptic impactOccurred];
    NSString *title = [NSString stringWithFormat:@"%@ (%@)", [self humanReadableNameForId:entry.productType], [self formattedOSVersion:entry.version]];
    [self showProgress:[NSString stringWithFormat:@"ダウンロード中: %@", [self formattedOSVersion:entry.version]]
                detail:L(@"ipsw_bg_connecting_detail")];

    NSURL *primary = [NSURL URLWithString:entry.url];
    NSURL *fallback = entry.fallbackUrl ? [NSURL URLWithString:entry.fallbackUrl] : nil;

    __weak typeof(self) weakSelf = self;
    [[IPSWDownloader sharedDownloader] startDownloadWithId:entry.entryId
                                              displayTitle:title
                                                primaryURL:primary
                                               fallbackURL:fallback
                                              expectedSHA1:entry.sha1
                                             expectedBytes:entry.bytes
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
    NSString *displayTitle = [NSString stringWithFormat:@"%@ (%@)", [self humanReadableNameForId:entry.productType], [self formattedOSVersion:entry.version]];
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
    NSString *displayTitle = [NSString stringWithFormat:@"%@ (%@)", [self humanReadableNameForId:entry.productType], [self formattedOSVersion:entry.version]];
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
    if (pct >= 0) {
        self.progressBar.progress = (float)pct / 100.0f;
    }
    self.progressDetailLabel.text = step;
}

- (void)prepareBaseWithIPSW:(NSURL *)ipswURL entry:(CatalogEntry *)entry installCydia:(BOOL)installCydia completion:(void(^)(void))completion {
    NSString *baseId = installCydia ? [NSString stringWithFormat:@"%@-jb", entry.entryId] : entry.entryId;
    NSString *progressTitle = installCydia ? @"デバイスストレージを構築中 (Cydia入り)..." : @"デバイスストレージを構築中...";
    [self showProgress:progressTitle detail:@"ルートファイルシステムの復号・NANDフォーマット..."];
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

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int ret = lighttouch_firmware_create_with_options(
            catalogPath.UTF8String,
            entry.entryId.UTF8String,
            ipswURL.path.UTF8String,
            guestToolsPath.UTF8String,
            outDir.UTF8String,
            installCydia ? 1 : 0,
            firmware_progress_callback
        );

        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideProgress];
            if (ret == 0) {
                if (completion) completion();
            } else {
                [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeError];
                const char *lastErr = lighttouch_firmware_last_error();
                NSString *detailMsg = (lastErr && strlen(lastErr) > 0) ? [NSString stringWithUTF8String:lastErr] : @"詳細不明のエラー";

                NSString *fullMsg = [NSString stringWithFormat:@"ファームウェア構築エラー (コード: %d)\n\n【エラー詳細】\n%@", ret, detailMsg];
                UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"ストレージ構築失敗"
                                                                              message:fullMsg
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [fail addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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
    c.createdAt = [[NSDate date] timeIntervalSince1970];

    // Create state directory
    NSString *statePath = [c statePathWithRoot:[self containersDirectory]];
    [[NSFileManager defaultManager] createDirectoryAtPath:statePath withIntermediateDirectories:YES attributes:nil error:nil];

    // Save container metadata
    [c saveMetadataWithRoot:[self containersDirectory]];

    [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self scanContainers];

    UIAlertController *done = [UIAlertController alertControllerWithTitle:@"コンテナ作成完了！"
                                                                  message:[NSString stringWithFormat:@"仮想マシン「%@」が準備完了しました。", name]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"今すぐ起動" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self bootContainer:c];
    }]];
    [done addAction:[UIAlertAction actionWithTitle:@"完了" style:UIAlertActionStyleCancel handler:nil]];
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

- (void)promptFirmwareManagement:(id)sender {
    [_haptic impactOccurred];
    __weak typeof(self) weakSelf = self;
    [self ensureCatalogLoadedThen:^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        FirmwareManagementViewController *vc = [[FirmwareManagementViewController alloc] initWithMainVC:s];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [s presentViewController:nav animated:YES completion:nil];
    }];
}

- (void)promptFirmwareActionsForFile:(FirmwareFile *)file {
    NSString *cleanName = [self humanReadableNameForId:file.entryId];
    NSArray<VMContainer *> *usedBy = [self containersUsingEntryId:file.entryId];
    NSMutableArray<NSString *> *usedNames = [NSMutableArray array];
    for (VMContainer *c in usedBy) {
        [usedNames addObject:c.name ?: c.containerId];
    }

    NSString *useDetail = usedBy.count > 0
        ? [NSString stringWithFormat:@"使用中のコンテナ (%lu件): %@", (unsigned long)usedBy.count, [usedNames componentsJoinedByString:@"、"]]
        : @"使用中のコンテナ: なし（削除可能）";

    NSString *msg = [NSString stringWithFormat:@"ファイル: %@\n容量: %.1f MB\n%@", file.fileName, (double)file.fileSizeBytes / (1024.0 * 1024.0), useDetail];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:cleanName
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"このIPSWから新規コンテナを作成..." style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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
        [alert addAction:[UIAlertAction actionWithTitle:@"使用中のため削除不可" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UIAlertController *blocked = [UIAlertController alertControllerWithTitle:@"削除できません"
                                                                             message:[NSString stringWithFormat:@"このファームウェアは以下のコンテナで使用されています:\n%@\n\n先に対象のコンテナを削除してから再度お試しください。", [usedNames componentsJoinedByString:@"\n"]]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [blocked addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:blocked animated:YES completion:nil];
        }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"このIPSWファイルを削除 (空き容量を解放)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:file.filePath error:nil];
            if (file.fileName.length > 0) {
                [fm removeItemAtPath:[[self firmwaresDirectory] stringByAppendingPathComponent:file.fileName] error:nil];
                [fm removeItemAtPath:[[self legacyIPSWDirectory] stringByAppendingPathComponent:file.fileName] error:nil];
            }
            [self promptFirmwareManagement:nil];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
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
        [UTType typeWithFilenameExtension:@"zip"] ?: UTTypeData
    ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - BootROM Management

- (void)promptBootromManagement:(id)sender {
    [_haptic impactOccurred];
    BootromViewController *vc = [[BootromViewController alloc] initWithMainVC:self];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showBootromPicker {
    self.isPickingBootrom = YES;
    self.isImportingIPSWForManagement = NO;
    NSArray *types = @[ UTTypeItem, UTTypeData ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
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
        NSString *romType = [targetName containsString:@"8900"] ? @"s5l8900" : @"s5l8720";
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
        [self installImportedBootromFromURL:url targetName:@"bootrom_s5l8900" romLabel:@"S5L8900 (iPhone 2G / iPod touch 1G)" size:sz];
        return;
    }
    if (kind == ClassicBootromSoCS5L8720) {
        [self installImportedBootromFromURL:url targetName:@"bootrom_240_4" romLabel:@"S5L8720 iBoot-240.4 (iPod touch 2G)" size:sz];
        return;
    }
    if (kind == ClassicBootromSoCAmbiguous) {
        UIAlertController *pick = [UIAlertController alertControllerWithTitle:@"BootROM の種類を選択"
                                                                      message:@"64 KB の ARM BootROM として検証されました。どちらの SoC 用として登録しますか？"
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [pick addAction:[UIAlertAction actionWithTitle:@"S5L8900 (iPhone 2G / iPod touch 1G)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self installImportedBootromFromURL:url targetName:@"bootrom_s5l8900" romLabel:@"S5L8900 (iPhone 2G / iPod touch 1G)" size:sz];
        }]];
        [pick addAction:[UIAlertAction actionWithTitle:@"S5L8720 (iPod touch 2G)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self installImportedBootromFromURL:url targetName:@"bootrom_240_4" romLabel:@"S5L8720 iBoot-240.4 (iPod touch 2G)" size:sz];
        }]];
        [pick addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *presenter = self.presentedViewController ?: self;
        [presenter presentViewController:pick animated:YES completion:nil];
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
    NSLog(@"[MainViewController] Selected local IPSW: %@", url);

    [self showProgress:@"IPSWファイルを解析中..." detail:@"チェックサムを照合中..."];
    __weak typeof(self) weakSelf = self;
    [self ensureCatalogLoadedThen:^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        NSArray<CatalogEntry *> *catalogSnapshot = [s.catalogEntries copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *err = nil;
            NSString *sha1 = [IPSWDownloader computeSHA1ForFile:url error:&err];
            CatalogEntry *matched = nil;
            for (CatalogEntry *ce in catalogSnapshot) {
                if ([ce.sha1 isEqualToString:sha1]) {
                    matched = ce;
                    break;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) ms = weakSelf;
                if (!ms) return;
                [ms hideProgress];
                if (matched) {
                    // Copy to Firmwares/
                    NSString *perm = [[ms firmwaresDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipsw", matched.entryId]];
                    [[NSFileManager defaultManager] removeItemAtPath:perm error:nil];
                    [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:perm error:nil];

                    if (managementOnly) {
                        [ms->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
                        [ms promptFirmwareManagement:nil];
                    } else {
                        [ms promptContainerNameForEntry:matched deviceTitle:[ms humanReadableNameForId:matched.entryId]];
                    }
                } else {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未対応のIPSW"
                                                                                   message:@"選択されたIPSWのSHA1がカタログに一致しませんでした。"
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [ms presentViewController:alert animated:YES completion:nil];
                }
            });
        });
    }];
}

#pragma mark - Progress Overlay UI

- (void)setupProgressOverlay {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    self.progressOverlay = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.progressOverlay.frame = self.view.bounds;
    self.progressOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.progressOverlay.alpha = 0.0;
    self.progressOverlay.hidden = YES;
    [self.view addSubview:self.progressOverlay];

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
    [self.cancelButton setTitle:@"キャンセル" forState:UIControlStateNormal];
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
    self.progressTitleLabel.text = title;
    self.progressDetailLabel.text = detail;
    self.progressBar.progress = 0.0f;
    self.progressOverlay.hidden = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self.progressOverlay.alpha = 1.0;
    }];
}

- (void)hideProgress {
    [UIView animateWithDuration:0.25 animations:^{
        self.progressOverlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.progressOverlay.hidden = YES;
    }];
}

- (void)cancelCurrentOperation:(id)sender {
    [[IPSWDownloader sharedDownloader] cancel];
    [self hideProgress];
}

#pragma mark - Machine Execution

- (void)bootContainer:(VMContainer *)container {
    if (self.isCheckingJit) return;
    [_haptic impactOccurred];

    // Enforce single active container at a time
    if (self.activeEmulatorVC != nil || [self.presentedViewController isKindOfClass:[EmulatorViewController class]]) {
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeWarning];
        NSString *runningName = self.activeEmulatorVC.machineName ?: @"別の仮想マシン";
        UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"すでに起動中です"
                                                                      message:[NSString stringWithFormat:@"仮想マシン「%@」が起動中です。\n一度に起動できるのは1台までです。", runningName]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [busy addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:busy animated:YES completion:nil];
        return;
    }

    // Check BootROM requirement per SoC family (S5L8900 vs S5L8720)
    NSString *requiredRom = [self requiredBootromTypeForIdentifier:container.baseId ?: container.productType];
    if (requiredRom && ![self hasInstalledBootromForIdentifier:container.baseId ?: container.productType]) {
        [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeWarning];
        NSString *romMsg = [requiredRom isEqualToString:@"s5l8720"]
            ? L(@"bootrom_required_s5l8720_msg")
            : L(@"bootrom_required_s5l8900_msg");
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
        guideLbl.text = @"はじめての使い方\n1. 下のボタンから機種と OS を選択\n2. 起動前に StikDebug（universal.js）で JIT を有効化\n3. 作成した端末の ▶ を押して起動\n※ iPhone 2G / iPod 1G・2G のみ右上の ROM から BootROM が必要です";
        [guideCard addSubview:guideLbl];

        UIButton *createBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        createBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIButtonConfiguration *btnCfg = [UIButtonConfiguration filledButtonConfiguration];
        btnCfg.title = @"最初の仮想マシンを作成";
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
        return 0;
    }
    if (self.containers.count == 0) {
        tableView.backgroundView = [self emptyStateViewForTableView:tableView];
    } else {
        tableView.backgroundView = nil;
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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"ContainerCell";
    static UIImage *sPlayImg = nil;
    static UIImage *sIphoneImg = nil;
    static UIImage *sIpadImg = nil;
    static UIImage *sIpodImg = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIImageSymbolConfiguration *playCfg = [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightBold];
        sPlayImg = [UIImage systemImageNamed:@"play.fill" withConfiguration:playCfg];
        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:24.0 weight:UIImageSymbolWeightRegular];
        sIphoneImg = [UIImage systemImageNamed:@"iphone" withConfiguration:symCfg];
        sIpadImg = [UIImage systemImageNamed:@"ipad" withConfiguration:symCfg];
        sIpodImg = [UIImage systemImageNamed:@"ipodtouch" withConfiguration:symCfg];
    });

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        cell.detailTextLabel.numberOfLines = 0;
        cell.imageView.tintColor = [UIColor systemBlueColor];

        UIButton *playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [playBtn setImage:sPlayImg forState:UIControlStateNormal];
        playBtn.tintColor = [UIColor systemBlueColor];
        playBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.14];
        playBtn.layer.cornerRadius = 17.0;
        playBtn.frame = CGRectMake(0, 0, 34, 34);
        playBtn.accessibilityLabel = @"起動";
        [playBtn addTarget:self action:@selector(playButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = playBtn;
    }

    if ([cell.accessoryView isKindOfClass:[UIButton class]]) {
        cell.accessoryView.tag = indexPath.row;
    }

    VMContainer *c = self.containers[indexPath.row];
    cell.textLabel.text = c.name;

    NSString *devClean = [self humanReadableNameForId:c.baseId];
    NSString *verStr = c.version.length > 0 ? [self formattedOSVersion:c.version] : @"";

    NSString *romTag = @"";
    BOOL romMissing = NO;
    if ([self requiredBootromTypeForIdentifier:c.baseId] != nil) {
        BOOL hasRom = [self hasInstalledBootromForIdentifier:c.baseId];
        romMissing = !hasRom;
        romTag = hasRom
            ? [NSString stringWithFormat:@" / %@", L(@"bootrom_ok")]
            : [NSString stringWithFormat:@" / %@", L(@"bootrom_missing")];
    }

    NSString *cydiaTag = [c.baseId hasSuffix:@"-jb"] ? @" / Cydia" : @"";
    NSString *idTag = c.containerId.length > 0 ? [NSString stringWithFormat:@"\nID: %@", c.containerId] : @"";
    NSString *detailText = [NSString stringWithFormat:@"%@ / %@%@%@%@", devClean, verStr, cydiaTag, romTag, idTag];
    if (romMissing) {
        NSMutableAttributedString *attrDetail = [[NSMutableAttributedString alloc] initWithString:detailText
                                                                                     attributes:@{
            NSForegroundColorAttributeName: [UIColor secondaryLabelColor]
        }];
        NSRange warnRange = [detailText rangeOfString:L(@"bootrom_missing")];
        if (warnRange.location != NSNotFound) {
            [attrDetail addAttribute:NSForegroundColorAttributeName value:[UIColor systemOrangeColor] range:warnRange];
        }
        cell.detailTextLabel.attributedText = attrDetail;
    } else {
        cell.detailTextLabel.attributedText = nil;
        cell.detailTextLabel.text = detailText;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    // Cached SF Symbol icons based on device
    if ([c.name containsString:@"iPad"] || [c.baseId containsString:@"iPad"]) {
        cell.imageView.image = sIpadImg;
    } else if ([c.name containsString:@"iPod"] || [c.baseId containsString:@"iPod"]) {
        cell.imageView.image = sIpodImg;
    } else {
        cell.imageView.image = sIphoneImg;
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

    UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"名前変更" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
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

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"削除" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
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
        UIAction *bootAct = [UIAction actionWithTitle:@"起動" image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(__kindof UIAction *action) {
            [self bootContainer:c];
        }];
        UIAction *copyIdAct = [UIAction actionWithTitle:@"コンテナ ID をコピー" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__kindof UIAction *action) {
            if (c.containerId.length > 0) {
                [UIPasteboard generalPasteboard].string = c.containerId;
                [self->_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            }
        }];
        UIAction *renameAct = [UIAction actionWithTitle:@"名前を変更" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__kindof UIAction *action) {
            [self promptRenameContainer:c];
        }];
        UIAction *deleteAct = [UIAction actionWithTitle:@"削除" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__kindof UIAction *action) {
            [self confirmDeleteContainer:c indexPath:indexPath];
        }];
        deleteAct.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:c.name ?: @"" children:@[bootAct, copyIdAct, renameAct, deleteAct]];
    }];
}

#pragma mark - Rename & Delete Actions

- (void)promptRenameContainer:(VMContainer *)container {
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"コンテナ名の変更"
                                                                    message:@"新しい名前を入力してください:"
                                                             preferredStyle:UIAlertControllerStyleAlert];

    [prompt addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = container.name;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [prompt addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *tf = prompt.textFields.firstObject;
        if (tf.text.length > 0) {
            container.name = tf.text;
            [container saveMetadataWithRoot:[self containersDirectory]];
            [self.tableView reloadData];
        }
    }]];

    [prompt addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)confirmDeleteContainer:(VMContainer *)container indexPath:(NSIndexPath *)indexPath {
    NSString *msg = [NSString stringWithFormat:@"仮想マシン「%@」を削除しますか？\nコンテナ内の保存データ・設定が削除されます（ベースイメージは保持されます）。", container.name];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"コンテナの削除"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
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

    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

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

#import "SettingsViewController.h"
#import "MainViewController.h"
#import "ios_jit_helper.h"
#include <dlfcn.h>

static inline NSString *SettingsL(NSString *key) {
    NSString *val = [[NSBundle mainBundle] localizedStringForKey:key value:nil table:nil];
    if (val && ![val isEqualToString:key]) return val;
    return NSLocalizedString(key, nil);
}

static BOOL SettingsCheckJITAvailable(void) {
    if (ios_jit_is_rx_rw_split()) {
        return YES;
    }
    if (ios_jit_is_debugger_attached()) {
        return YES;
    }
    bool timedOut = false;
    return ios_jit_is_available_detailed(300, &timedOut);
}

typedef NS_ENUM(NSInteger, SettingsSection) {
    SettingsSectionFirmwareRom = 0,
    SettingsSectionSystem,
    SettingsSectionCarrier,
    SettingsSectionEmulation,
    SettingsSectionMenuBar,
    SettingsSectionAbout,
    SettingsSectionCount
};

typedef NS_ENUM(NSInteger, FirmwareRomRow) {
    FirmwareRomRowIPSW = 0,
    FirmwareRomRowBootROM,
    FirmwareRomRowCount
};

typedef NS_ENUM(NSInteger, SystemRow) {
    SystemRowJIT = 0,
    SystemRowCount
};

typedef NS_ENUM(NSInteger, CarrierRow) {
    CarrierRowName = 0,
    CarrierRowCount
};

typedef NS_ENUM(NSInteger, EmulationRow) {
    EmulationRowClipboard = 0,
    EmulationRowRotation,
    EmulationRowCount
};

typedef NS_ENUM(NSInteger, MenuBarRow) {
    MenuBarRowPosition = 0,
    MenuBarRowCount
};

typedef NS_ENUM(NSInteger, AboutRow) {
    AboutRowVersion = 0,
    AboutRowArch,
    AboutRowCore,
    AboutRowLicense,
    AboutRowCount
};

static UIImage *SettingsBadgeIcon(NSString *symbolName, UIColor *bgColor) {
    CGFloat sz = 30.0;
    CGFloat corner = 7.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(sz, sz) format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        CGRect rect = CGRectMake(0, 0, sz, sz);
        UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:corner];
        [bgColor setFill];
        [bgPath fill];
        
        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
        UIImage *sym = [[UIImage systemImageNamed:symbolName withConfiguration:symCfg] imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (sym) {
            CGSize symSz = sym.size;
            CGRect symRect = CGRectMake((sz - symSz.width) / 2.0, (sz - symSz.height) / 2.0, symSz.width, symSz.height);
            [sym drawInRect:symRect];
        }
    }];
}

@interface SettingsViewController ()
@property (nonatomic, strong) UIImpactFeedbackGenerator *haptic;
@property (nonatomic, strong) UINotificationFeedbackGenerator *notifyHaptic;
@end

@implementation SettingsViewController

- (instancetype)initWithMainViewController:(MainViewController *)mainVC {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _mainVC = mainVC;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = SettingsL(@"settings_title");
    
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    _notifyHaptic = [[UINotificationFeedbackGenerator alloc] init];
    
    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                              target:self
                                                                              action:@selector(dismissTapped:)];
    self.navigationItem.rightBarButtonItem = doneItem;
    
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithDefaultBackground];
    appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    
    self.tableView.showsVerticalScrollIndicator = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)dismissTapped:(id)sender {
    [_haptic impactOccurred];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return SettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((SettingsSection)section) {
        case SettingsSectionFirmwareRom: return FirmwareRomRowCount;
        case SettingsSectionSystem:      return SystemRowCount;
        case SettingsSectionCarrier:     return CarrierRowCount;
        case SettingsSectionEmulation:   return EmulationRowCount;
        case SettingsSectionMenuBar:     return MenuBarRowCount;
        case SettingsSectionAbout:       return AboutRowCount;
        default:                         return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((SettingsSection)section) {
        case SettingsSectionFirmwareRom: return SettingsL(@"settings_firmware_rom_header");
        case SettingsSectionSystem:      return SettingsL(@"settings_system_header");
        case SettingsSectionCarrier:     return SettingsL(@"settings_carrier_header");
        case SettingsSectionEmulation:   return SettingsL(@"settings_emulation_header");
        case SettingsSectionMenuBar:     return SettingsL(@"settings_menubar_header");
        case SettingsSectionAbout:       return SettingsL(@"settings_about_header");
        default:                         return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch ((SettingsSection)section) {
        case SettingsSectionCarrier: return SettingsL(@"settings_carrier_footer");
        default:                     return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SettingsSection sec = (SettingsSection)indexPath.section;
    
    if (sec == SettingsSectionFirmwareRom) {
        static NSString *subId = @"FirmwareRomCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:subId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:subId];
            cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        if (indexPath.row == FirmwareRomRowIPSW) {
            cell.textLabel.text = SettingsL(@"settings_ipsw_management");
            NSUInteger count = self.mainVC ? [self.mainVC installedFirmwareCount] : 0;
            cell.detailTextLabel.text = [NSString stringWithFormat:SettingsL(@"settings_ipsw_subtitle_fmt"), (unsigned long)count];
            cell.imageView.image = SettingsBadgeIcon(@"externaldrive.fill", [UIColor systemBlueColor]);
        } else if (indexPath.row == FirmwareRomRowBootROM) {
            cell.textLabel.text = SettingsL(@"settings_bootrom_management");
            NSUInteger count = self.mainVC ? [self.mainVC installedBootromCount] : 0;
            if (count > 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:SettingsL(@"settings_bootrom_subtitle_fmt"), (unsigned long)count];
            } else {
                cell.detailTextLabel.text = SettingsL(@"settings_bootrom_subtitle_none");
            }
            cell.imageView.image = SettingsBadgeIcon(@"memorychip.fill", [UIColor systemIndigoColor]);
        }
        return cell;
    }
    
    if (sec == SettingsSectionSystem) {
        if (indexPath.row == SystemRowJIT) {
            static NSString *jitId = @"JITCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:jitId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:jitId];
                cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
                cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            BOOL jitActive = SettingsCheckJITAvailable();
            cell.textLabel.text = SettingsL(@"settings_jit_title");
            cell.detailTextLabel.text = SettingsL(@"settings_jit_desc");
            
            UILabel *statusLbl = (UILabel *)cell.accessoryView;
            if (!statusLbl || ![statusLbl isKindOfClass:[UILabel class]]) {
                statusLbl = [[UILabel alloc] init];
                statusLbl.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
                cell.accessoryView = statusLbl;
            }
            if (jitActive) {
                statusLbl.text = SettingsL(@"settings_jit_active");
                statusLbl.textColor = [UIColor systemGreenColor];
                cell.imageView.image = SettingsBadgeIcon(@"bolt.fill", [UIColor systemGreenColor]);
            } else {
                statusLbl.text = SettingsL(@"settings_jit_disabled");
                statusLbl.textColor = [UIColor systemOrangeColor];
                cell.imageView.image = SettingsBadgeIcon(@"bolt.slash.fill", [UIColor systemOrangeColor]);
            }
            [statusLbl sizeToFit];
            return cell;
        }
    }
    
    if (sec == SettingsSectionCarrier) {
        static NSString *valId = @"CarrierCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:valId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:valId];
            cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.textLabel.text = SettingsL(@"settings_carrier_title");
        NSString *carrier = [[NSUserDefaults standardUserDefaults] stringForKey:@"ClassicTouch_CarrierName"];
        if (!carrier || carrier.length == 0) {
            carrier = @"ClassicTouch";
        }
        cell.detailTextLabel.text = carrier;
        cell.imageView.image = SettingsBadgeIcon(@"antenna.radiowaves.left.and.right", [UIColor systemGreenColor]);
        return cell;
    }
    
    if (sec == SettingsSectionEmulation) {
        static NSString *switchId = @"SwitchCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:switchId];
        UISwitch *toggle = nil;
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:switchId];
            cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            
            toggle = [[UISwitch alloc] init];
            [toggle addTarget:self action:@selector(switchValueChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        } else {
            toggle = (UISwitch *)cell.accessoryView;
        }
        toggle.tag = indexPath.row;
        
        if (indexPath.row == EmulationRowClipboard) {
            cell.textLabel.text = SettingsL(@"settings_clipboard_sharing");
            cell.detailTextLabel.text = SettingsL(@"settings_clipboard_sharing_desc");
            cell.imageView.image = SettingsBadgeIcon(@"doc.on.clipboard.fill", [UIColor systemTealColor]);
            id obj = [[NSUserDefaults standardUserDefaults] objectForKey:@"ClassicTouch_ClipboardSyncEnabled"];
            toggle.on = (obj == nil) ? YES : [obj boolValue];
        } else {
            cell.textLabel.text = SettingsL(@"settings_rotate_host");
            cell.detailTextLabel.text = SettingsL(@"settings_rotate_host_desc");
            cell.imageView.image = SettingsBadgeIcon(@"crop.rotate", [UIColor systemOrangeColor]);
            id obj = [[NSUserDefaults standardUserDefaults] objectForKey:@"ClassicTouch_iPadLandscapeRotate"];
            toggle.on = (obj == nil) ? NO : [obj boolValue];
        }
        return cell;
    }
    
    if (sec == SettingsSectionMenuBar) {
        static NSString *menuId = @"MenuBarCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:menuId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:menuId];
            cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.textLabel.text = SettingsL(@"settings_menubar_pos");
        NSInteger pos = [[NSUserDefaults standardUserDefaults] integerForKey:@"ClassicTouch_MenuBarPosition"];
        cell.detailTextLabel.text = (pos == 1) ? SettingsL(@"settings_menubar_top") : SettingsL(@"settings_menubar_bottom");
        cell.imageView.image = SettingsBadgeIcon(@"menubar.dock.rectangle", [UIColor systemPinkColor]);
        return cell;
    }
    
    if (sec == SettingsSectionAbout) {
        static NSString *aboutId = @"AboutCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:aboutId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:aboutId];
            cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        if (indexPath.row == AboutRowVersion) {
            cell.textLabel.text = SettingsL(@"settings_version");
            cell.detailTextLabel.text = @"2.0.0 (Build 60)";
            cell.imageView.image = SettingsBadgeIcon(@"info.circle.fill", [UIColor systemGrayColor]);
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == AboutRowArch) {
            cell.textLabel.text = SettingsL(@"settings_architecture");
            cell.detailTextLabel.text = @"ARM64";
            cell.imageView.image = SettingsBadgeIcon(@"cpu", [UIColor systemGrayColor]);
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == AboutRowCore) {
            cell.textLabel.text = SettingsL(@"settings_emulator_core");
            cell.detailTextLabel.text = @"QEMU Core";
            cell.imageView.image = SettingsBadgeIcon(@"gearshape.2.fill", [UIColor systemGrayColor]);
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == AboutRowLicense) {
            cell.textLabel.text = SettingsL(@"settings_license_title");
            cell.detailTextLabel.text = SettingsL(@"settings_license_subtitle");
            cell.imageView.image = SettingsBadgeIcon(@"doc.plaintext", [UIColor systemIndigoColor]);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        return cell;
    }
    
    return [[UITableViewCell alloc] init];
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_haptic impactOccurred];
    
    SettingsSection sec = (SettingsSection)indexPath.section;
    
    if (sec == SettingsSectionFirmwareRom) {
        if (indexPath.row == FirmwareRomRowIPSW) {
            if (self.mainVC) {
                [self.mainVC promptFirmwareManagementFromViewController:self];
            }
        } else if (indexPath.row == FirmwareRomRowBootROM) {
            if (self.mainVC) {
                [self.mainVC promptBootromManagementFromViewController:self];
            }
        }
    } else if (sec == SettingsSectionSystem) {
        if (indexPath.row == SystemRowJIT) {
            [self showJITInfoAlert];
        }
    } else if (sec == SettingsSectionCarrier) {
        [self promptCarrierSelectionFromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (sec == SettingsSectionMenuBar) {
        [self promptMenuBarPositionSelectionFromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (sec == SettingsSectionAbout) {
        if (indexPath.row == AboutRowLicense) {
            [self showLicenseViewer];
        }
    }
}

#pragma mark - Information Alerts

- (void)showJITInfoAlert {
    BOOL jitActive = SettingsCheckJITAvailable();
    NSString *statusStr = jitActive ? SettingsL(@"settings_jit_active") : SettingsL(@"settings_jit_disabled");
    
    NSString *msg = [NSString stringWithFormat:SettingsL(@"settings_jit_info_fmt"), statusStr];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SettingsL(@"settings_jit_title")
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SettingsL(@"ok") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Setting Actions

- (void)switchValueChanged:(UISwitch *)sender {
    [_haptic impactOccurred];
    if (sender.tag == EmulationRowClipboard) {
        [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:@"ClassicTouch_ClipboardSyncEnabled"];
    } else if (sender.tag == EmulationRowRotation) {
        [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:@"ClassicTouch_iPadLandscapeRotate"];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)promptCarrierSelectionFromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:SettingsL(@"settings_carrier_preset_sheet_title")
                                                                   message:SettingsL(@"settings_carrier_footer")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray<NSString *> *presets = @[
        @"ClassicTouch",
        @"SoftBank",
        @"docomo",
        @"au",
        @"NTT DOCOMO",
        @"AT&T",
        @"Verizon"
    ];
    
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"ClassicTouch_CarrierName"] ?: @"ClassicTouch";
    
    for (NSString *name in presets) {
        NSString *title = [name isEqualToString:current] ? [NSString stringWithFormat:@"✓ %@", name] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self applyCarrierName:name];
        }]];
    }
    
    [sheet addAction:[UIAlertAction actionWithTitle:SettingsL(@"settings_carrier_preset_custom") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self promptCustomCarrierName];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:SettingsL(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    
    if (sheet.popoverPresentationController && cell) {
        sheet.popoverPresentationController.sourceView = cell;
        sheet.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptCustomCarrierName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SettingsL(@"settings_carrier_title")
                                                                   message:SettingsL(@"settings_carrier_custom_prompt")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"ClassicTouch_CarrierName"] ?: @"ClassicTouch";
        textField.text = current;
        textField.placeholder = @"ClassicTouch";
        textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:SettingsL(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:SettingsL(@"ok") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0) {
            text = @"ClassicTouch";
        }
        [self applyCarrierName:text];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyCarrierName:(NSString *)carrierName {
    [_notifyHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [[NSUserDefaults standardUserDefaults] setObject:carrierName forKey:@"ClassicTouch_CarrierName"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SettingsSectionCarrier] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)promptMenuBarPositionSelectionFromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:SettingsL(@"settings_menubar_pos")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSInteger current = [[NSUserDefaults standardUserDefaults] integerForKey:@"ClassicTouch_MenuBarPosition"];
    
    NSString *bottomTitle = (current == 0) ? [NSString stringWithFormat:@"✓ %@", SettingsL(@"settings_menubar_bottom")] : SettingsL(@"settings_menubar_bottom");
    NSString *topTitle = (current == 1) ? [NSString stringWithFormat:@"✓ %@", SettingsL(@"settings_menubar_top")] : SettingsL(@"settings_menubar_top");
    
    [sheet addAction:[UIAlertAction actionWithTitle:bottomTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"ClassicTouch_MenuBarPosition"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SettingsSectionMenuBar] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:topTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"ClassicTouch_MenuBarPosition"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SettingsSectionMenuBar] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:SettingsL(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    
    if (sheet.popoverPresentationController && cell) {
        sheet.popoverPresentationController.sourceView = cell;
        sheet.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - License Viewer

- (void)showLicenseViewer {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = SettingsL(@"settings_license_title");
    vc.view.backgroundColor = [UIColor systemBackgroundColor];
    
    UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.selectable = YES;
    tv.alwaysBounceVertical = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.textColor = [UIColor labelColor];
    tv.backgroundColor = [UIColor systemBackgroundColor];
    tv.textContainerInset = UIEdgeInsetsMake(16, 16, 24, 16);
    
    NSString *licensePath = [[NSBundle mainBundle] pathForResource:@"LICENSE" ofType:@"txt"];
    if (!licensePath || ![[NSFileManager defaultManager] fileExistsAtPath:licensePath]) {
        licensePath = [[NSBundle mainBundle] pathForResource:@"LICENSE" ofType:nil];
    }
    if (licensePath && [[NSFileManager defaultManager] fileExistsAtPath:licensePath]) {
        NSError *err = nil;
        NSString *licenseText = [NSString stringWithContentsOfFile:licensePath encoding:NSUTF8StringEncoding error:&err];
        tv.text = (licenseText && !err) ? licenseText : @"";
    }
    
    [vc.view addSubview:tv];
    
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissLicenseModal:)];
    vc.navigationItem.rightBarButtonItem = done;
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)dismissLicenseModal:(id)sender {
    [_haptic impactOccurred];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

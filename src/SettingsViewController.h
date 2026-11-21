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

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class MainViewController;

@interface SettingsViewController : UITableViewController

@property (nonatomic, weak) MainViewController *mainVC;

- (instancetype)initWithMainViewController:(MainViewController *)mainVC;

@end

NS_ASSUME_NONNULL_END

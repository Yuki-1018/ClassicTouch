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

@interface EmulatorViewController : UIViewController

@property (nonatomic, copy) NSString *machineId;
@property (nonatomic, copy) NSString *machineName;
@property (nonatomic, copy) NSString *stateDirPath;
@property (nonatomic, copy) NSString *baseDirPath;
@property (nonatomic, assign) NSInteger screenWidth;
@property (nonatomic, assign) NSInteger screenHeight;
@property (nonatomic, assign) NSInteger screenScale;
@property (nonatomic, assign) BOOL iPadLandscapeRotationEnabled;
@property (nonatomic, assign) BOOL clipboardSyncEnabled;
@property (nonatomic, copy, nullable) void (^onEngineProcessConsumed)(void);

- (instancetype)initWithMachineId:(NSString *)machineId
                      machineName:(NSString *)machineName
                     stateDirPath:(NSString *)stateDirPath
                      baseDirPath:(NSString *)baseDirPath;

- (void)stopEmulation;
- (void)pullNotificationCenter;
- (void)pullControlCenter;

@end

NS_ASSUME_NONNULL_END

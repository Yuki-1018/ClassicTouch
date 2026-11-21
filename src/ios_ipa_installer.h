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

#import <Foundation/Foundation.h>

@class IOSUsbMuxBridge;

NS_ASSUME_NONNULL_BEGIN

@interface IOSIpaInfo : NSObject
@property (nonatomic, readonly, copy) NSString *bundleId;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy, nullable) NSString *version;
@property (nonatomic, readonly, copy, nullable) NSString *shortVersion;
@property (nonatomic, readonly, copy, nullable) NSString *minimumOS;
@property (nonatomic, readonly, assign) uint64_t ipaBytes;
@property (nonatomic, readonly, assign) uint64_t unpackedBytes;
@end

typedef NS_ENUM(NSInteger, IOSIpaInstallStage) {
    IOSIpaInstallStageConnecting = 0,
    IOSIpaInstallStagePreflight,
    IOSIpaInstallStageUploading,
    IOSIpaInstallStageSubmitted,
    IOSIpaInstallStageUnpacking,
    IOSIpaInstallStageInstalling,
    IOSIpaInstallStageVerifying,
};

typedef BOOL (^IOSIpaProgressBlock)(IOSIpaInstallStage stage, NSString *statusText, float progress /* -1 if indeterminate */);

@interface IOSIpaInstaller : NSObject

+ (void)installIPAFromURL:(NSURL *)ipaURL
                   bridge:(IOSUsbMuxBridge *)bridge
             stateDirPath:(NSString *)stateDirPath
                 progress:(nullable IOSIpaProgressBlock)progress
               completion:(void (^)(IOSIpaInfo * _Nullable info, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

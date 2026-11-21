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

NS_ASSUME_NONNULL_BEGIN

@interface IOSNetworkProxy : NSObject

@property (nonatomic, readonly, copy) NSString *socketPath;
@property (nonatomic, readonly) NSData *certificateDER;
@property (nonatomic, readonly, copy) NSString *certificateFingerprint;

+ (nullable instancetype)startWithIdentityDirectory:(NSString *)identityDir
                                         socketPath:(NSString *)socketPath
                                       errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

- (void)stop;

@end

NS_ASSUME_NONNULL_END

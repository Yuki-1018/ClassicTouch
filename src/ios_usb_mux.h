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

@interface IOSUsbMuxBridge : NSObject

@property (nonatomic, readonly, copy) NSString *tcpAddress;
@property (nonatomic, readonly, assign) BOOL deviceAttached;
@property (nonatomic, readonly, copy, nullable) NSString *deviceUDID;

+ (nullable instancetype)startWithError:(NSError * _Nullable * _Nullable)error;

/// Opens a tunneled TCP stream to `port` inside the emulated guest.
/// Returns a connected POSIX socket descriptor (>= 0) owned by the caller, or -1 on error.
- (int)connectToGuestPort:(uint16_t)port timeout:(NSTimeInterval)timeout error:(NSError * _Nullable * _Nullable)error;

- (void)stop;

@end

NS_ASSUME_NONNULL_END

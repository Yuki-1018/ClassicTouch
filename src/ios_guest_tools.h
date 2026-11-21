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

/// Inflates an `ITPACK01` archive, returning the concatenated payload and optionally its manifest `entries`.
FOUNDATION_EXPORT NSData * _Nullable ClassicInflateITPack(NSString *path, NSArray<NSDictionary *> * _Nullable * _Nullable outEntries);

/// Returns a directory containing pristine guest-tool binaries, extracting `guest-tools/host-tools.itpack`
/// on demand so iOS sideloaders cannot alter embedded guest Mach-O signatures or entitlements.
FOUNDATION_EXPORT NSString *ClassicGuestToolsDirectory(void);

NS_ASSUME_NONNULL_END

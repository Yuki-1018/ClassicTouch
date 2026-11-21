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
#import "AppDelegate.h"
#import "ios_jit_helper.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        // Earliest possible JIT init before UIKit sets up thread environments
        ios_jit_init_protection();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}

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

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>

@protocol IOSMotionManagerDelegate <NSObject>
- (void)didUpdateAccelerationX:(double)x y:(double)y z:(double)z;
- (void)didUpdateGyroscopeX:(double)x y:(double)y z:(double)z;
@end

@interface IOSMotionManager : NSObject
@property (nonatomic, weak) id<IOSMotionManagerDelegate> delegate;
+ (instancetype)sharedManager;
- (void)startMonitoringAtInterval:(NSTimeInterval)interval;
- (void)stopMonitoring;
@end

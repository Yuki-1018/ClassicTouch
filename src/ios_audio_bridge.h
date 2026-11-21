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
#import <AVFoundation/AVFoundation.h>

@interface IOSAudioBridge : NSObject
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) int channels;
+ (instancetype)sharedBridge;
- (BOOL)start;
- (void)stop;
- (BOOL)startPlaybackWithSampleRate:(double)sampleRate channels:(int)channels;
- (void)stopPlayback;
- (void)pushPCMData:(const int16_t *)samples count:(size_t)frameCount;
@end

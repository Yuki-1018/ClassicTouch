//
// ClassicTouch - Native Classic iOS Emulator for Modern iOS & iPadOS
//
// Copyright (c) 2026 ClassicTouch Authors.
// Based on LightTouch / LightTouchMac by Blake Lucas and Sam Henri Gold.
// SPDX-License-Identifier: GPL-2.0-only
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; version 2 of the License.
//

#pragma once
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreVideo/CoreVideo.h>

@protocol IOSMetalViewDelegate <NSObject>
- (void)metalViewTouchesChanged:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event phase:(int)phase;
@end

@interface IOSMetalView : MTKView <UIGestureRecognizerDelegate>
@property (nonatomic, weak) id<IOSMetalViewDelegate> touchDelegate;
@property (nonatomic, copy) void (^onTouchEvent)(int touchId, int phase, float x, float y);
@property (nonatomic, copy) void (^onZoomChanged)(CGFloat scale, CGPoint offset);
@property (nonatomic, assign, readonly) double fps;
@property (nonatomic, assign, readonly) NSUInteger totalFramesRendered;
@property (nonatomic, assign) NSInteger displayRotationDegrees;
@property (nonatomic, assign) BOOL zoomModeEnabled;
@property (nonatomic, assign) CGFloat zoomScale;
@property (nonatomic, assign) CGPoint panOffset;
- (CGRect)activeScreenRect;
- (void)resetZoom;
- (void)purgeTextureCaches;
- (void)updateFramePixels:(const void *)bgraPixels width:(int)w height:(int)h stride:(int)stride;
- (void)updateFrameIOSurface:(void *)iosurfaceRef width:(int)w height:(int)h;
@end

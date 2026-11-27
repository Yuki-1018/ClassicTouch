//
// AndroidMetalView - Goldfish MetalDisplay + FrameMailbox view.
// Dedicated Android renderer leaving IOSMetalView untouched for iOS guests.
//

#pragma once
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "ios_metal_view.h"

@interface AndroidMetalView : MTKView <MTKViewDelegate, UIGestureRecognizerDelegate>
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
- (void)updateDirtyPixels:(const void *)bgraPixels
                        x:(int)x
                        y:(int)y
                    width:(int)w
                   height:(int)h
                   stride:(int)stride
                fullWidth:(int)fullW
               fullHeight:(int)fullH;
@end

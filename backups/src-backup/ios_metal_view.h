#pragma once
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreVideo/CoreVideo.h>

@protocol IOSMetalViewDelegate <NSObject>
- (void)metalViewTouchesChanged:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event phase:(int)phase;
@end

@interface IOSMetalView : MTKView
@property (nonatomic, weak) id<IOSMetalViewDelegate> touchDelegate;
@property (nonatomic, copy) void (^onTouchEvent)(int touchId, int phase, float x, float y);
@property (nonatomic, assign, readonly) double fps;
@property (nonatomic, assign, readonly) NSUInteger totalFramesRendered;
@property (nonatomic, assign) NSInteger displayRotationDegrees;
- (CGRect)activeScreenRect;
- (void)updateFramePixels:(const void *)bgraPixels width:(int)w height:(int)h stride:(int)stride;
@end

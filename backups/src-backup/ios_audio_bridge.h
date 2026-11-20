#pragma once
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface IOSAudioBridge : NSObject
+ (instancetype)sharedBridge;
- (BOOL)start;
- (void)stop;
- (BOOL)startPlaybackWithSampleRate:(double)sampleRate channels:(int)channels;
- (void)stopPlayback;
- (void)pushPCMData:(const int16_t *)samples count:(size_t)frameCount;
@end

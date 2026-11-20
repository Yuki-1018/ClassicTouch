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

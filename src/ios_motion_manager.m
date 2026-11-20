#import "ios_motion_manager.h"

@interface IOSMotionManager () {
    CMMotionManager *_motionManager;
    NSOperationQueue *_motionQueue;
}
@end

@implementation IOSMotionManager

+ (instancetype)sharedManager {
    static IOSMotionManager *sInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstance = [[IOSMotionManager alloc] init];
    });
    return sInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        _motionManager = [[CMMotionManager alloc] init];
        _motionQueue = [[NSOperationQueue alloc] init];
        _motionQueue.maxConcurrentOperationCount = 1;
    }
    return self;
}

- (void)startMonitoringAtInterval:(NSTimeInterval)interval {
    NSTimeInterval targetInterval = interval > 0 ? interval : (1.0 / 60.0);
    
    if (_motionManager.isAccelerometerAvailable && !_motionManager.isAccelerometerActive) {
        _motionManager.accelerometerUpdateInterval = targetInterval;
        __weak typeof(self) weakSelf = self;
        [_motionManager startAccelerometerUpdatesToQueue:_motionQueue withHandler:^(CMAccelerometerData *data, NSError *error) {
            if (data) {
                // CMAcceleration in g units; guest accelerometer expects m/s^2 or g vector in portrait frame
                [weakSelf.delegate didUpdateAccelerationX:data.acceleration.x
                                                        y:data.acceleration.y
                                                        z:data.acceleration.z];
            }
        }];
    }
    
    if (_motionManager.isGyroAvailable && !_motionManager.isGyroActive) {
        _motionManager.gyroUpdateInterval = targetInterval;
        __weak typeof(self) weakSelf = self;
        [_motionManager startGyroUpdatesToQueue:_motionQueue withHandler:^(CMGyroData *data, NSError *error) {
            if (data) {
                [weakSelf.delegate didUpdateGyroscopeX:data.rotationRate.x
                                                     y:data.rotationRate.y
                                                     z:data.rotationRate.z];
            }
        }];
    }
}

- (void)stopMonitoring {
    if (_motionManager.isAccelerometerActive) {
        [_motionManager stopAccelerometerUpdates];
    }
    if (_motionManager.isGyroActive) {
        [_motionManager stopGyroUpdates];
    }
}

@end

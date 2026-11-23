#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AEADBClient : NSObject

@property (nonatomic, readonly, getter=isReady) BOOL ready;

- (instancetype)initWithEngineHandle:(nullable void *)engineHandle;
- (void)installAPKAtURL:(NSURL *)apkURL
               progress:(nullable void (^)(NSString *statusText, float progress))progress
             completion:(nullable void (^)(BOOL success, NSString *message))completion;
- (void)cancelInstall;

@end

NS_ASSUME_NONNULL_END

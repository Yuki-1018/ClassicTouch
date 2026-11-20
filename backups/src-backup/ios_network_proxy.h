#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IOSNetworkProxy : NSObject

@property (nonatomic, readonly, copy) NSString *socketPath;
@property (nonatomic, readonly) NSData *certificateDER;
@property (nonatomic, readonly, copy) NSString *certificateFingerprint;

+ (nullable instancetype)startWithIdentityDirectory:(NSString *)identityDir
                                         socketPath:(NSString *)socketPath
                                       errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

- (void)stop;

@end

NS_ASSUME_NONNULL_END

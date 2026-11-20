#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const kIPSWBackgroundSessionIdentifier;

typedef void (^IPSWDownloadProgressBlock)(int64_t bytesWritten, int64_t totalBytes, double fractionCompleted, double speedMBs);
typedef void (^IPSWDownloadCompletionBlock)(NSURL * _Nullable localURL, NSError * _Nullable error);

@interface IPSWDownloader : NSObject <NSURLSessionDownloadDelegate>

@property (nonatomic, copy, readonly, nullable) NSString *downloadId;
@property (nonatomic, copy, readonly, nullable) NSString *displayTitle;
@property (nonatomic, copy, readonly, nullable) NSString *expectedSHA1;
@property (nonatomic, assign, readonly) int64_t expectedBytes;
@property (nonatomic, copy, readonly, nullable) NSDictionary *activeMetadata;
@property (nonatomic, assign, readonly) BOOL isDownloading;
@property (nonatomic, assign, readonly) int64_t lastTotalBytesWritten;
@property (nonatomic, assign, readonly) int64_t lastTotalBytesExpected;
@property (nonatomic, assign, readonly) double lastFractionCompleted;
@property (nonatomic, assign, readonly) double lastSpeedMBs;

+ (instancetype)sharedDownloader;
+ (void)requestNotificationPermissionIfNeeded;

- (void)startDownloadWithId:(NSString *)downloadId
               displayTitle:(NSString *)displayTitle
                 primaryURL:(NSURL *)primaryURL
                fallbackURL:(nullable NSURL *)fallbackURL
               expectedSHA1:(nullable NSString *)sha1
              expectedBytes:(int64_t)expectedBytes
                   metadata:(nullable NSDictionary *)metadata
                   progress:(nullable IPSWDownloadProgressBlock)progressBlock
                 completion:(nullable IPSWDownloadCompletionBlock)completionBlock;

- (void)attachProgress:(nullable IPSWDownloadProgressBlock)progressBlock
            completion:(nullable IPSWDownloadCompletionBlock)completionBlock;

- (void)clearCallbacks;
- (void)cancel;

- (void)handleEventsForBackgroundURLSession:(NSString *)identifier
                          completionHandler:(void (^)(void))completionHandler;

- (nullable NSDictionary *)consumePendingCompletedDownloadInfo;

+ (NSString *)computeSHA1ForFile:(NSURL *)fileURL error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

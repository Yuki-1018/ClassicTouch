#import "IPSWDownloader.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

NSString * const kIPSWBackgroundSessionIdentifier = @"com.yuki1018.classictouch.ipsw-download";

static NSString * const kActiveDownloadDefaultsKey = @"ClassicTouchActiveIPSWDownload_v1";
static NSString * const kPendingCompletedDefaultsKey = @"ClassicTouchPendingCompletedIPSW_v1";

@interface IPSWDownloader ()
@property (nonatomic, copy, nullable) NSString *downloadId;
@property (nonatomic, copy, nullable) NSString *displayTitle;
@property (nonatomic, strong, nullable) NSURL *primaryURL;
@property (nonatomic, strong, nullable) NSURL *fallbackURL;
@property (nonatomic, copy, nullable) NSString *expectedSHA1;
@property (nonatomic, assign) int64_t expectedBytes;
@property (nonatomic, copy, nullable) NSDictionary *activeMetadata;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSession *foregroundSession;
@property (nonatomic, strong) NSOperationQueue *delegateQueue;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic, copy, nullable) IPSWDownloadProgressBlock progressBlock;
@property (nonatomic, copy, nullable) IPSWDownloadCompletionBlock completionBlock;
@property (nonatomic, copy, nullable) void (^backgroundCompletionHandler)(void);

@property (nonatomic, assign) BOOL isDownloading;
@property (nonatomic, assign) BOOL usingFallback;
@property (nonatomic, assign) BOOL usingForegroundFallback;
@property (nonatomic, assign) BOOL backgroundSessionUnavailable;
@property (nonatomic, assign) UIBackgroundTaskIdentifier foregroundBgTaskId;
@property (nonatomic, assign) NSTimeInterval lastProgressTime;
@property (nonatomic, assign) NSTimeInterval lastUiProgressTime;
@property (nonatomic, assign) int64_t lastBytesWritten;
@property (nonatomic, assign) int64_t lastTotalBytesWritten;
@property (nonatomic, assign) int64_t lastTotalBytesExpected;
@property (nonatomic, assign) double lastFractionCompleted;
@property (nonatomic, assign) double lastSpeedMBs;
@property (nonatomic, strong) dispatch_group_t notificationGroup;
@end

@implementation IPSWDownloader

+ (instancetype)sharedDownloader {
    static IPSWDownloader *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initPrivate];
    });
    return sharedInstance;
}

+ (void)requestNotificationPermissionIfNeeded {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                  completionHandler:^(BOOL granted, NSError * _Nullable error) {
                if (error) {
                    NSLog(@"[IPSWDownloader] Notification authorization request error: %@", error);
                } else {
                    NSLog(@"[IPSWDownloader] Notification permission granted: %d", granted);
                }
            }];
        }
    }];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _notificationGroup = dispatch_group_create();
        _foregroundBgTaskId = UIBackgroundTaskInvalid;
        _delegateQueue = [[NSOperationQueue alloc] init];
        _delegateQueue.maxConcurrentOperationCount = 1;
        _delegateQueue.name = @"com.yuki1018.classictouch.ipsw-download.queue";

        [self restoreActiveStateFromDefaults];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:kIPSWBackgroundSessionIdentifier];
        config.sessionSendsLaunchEvents = YES;
        config.discretionary = NO;
        config.waitsForConnectivity = YES;
        config.allowsCellularAccess = YES;
        config.timeoutIntervalForRequest = 60.0;
        config.timeoutIntervalForResource = 3600.0 * 12.0;

        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:_delegateQueue];

        __weak typeof(self) weakSelf = self;
        [_session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *dataTasks,
                                                  NSArray<NSURLSessionUploadTask *> *uploadTasks,
                                                  NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            @synchronized(strongSelf) {
                if (downloadTasks.count > 0) {
                    strongSelf.downloadTask = downloadTasks.firstObject;
                    strongSelf.isDownloading = YES;
                    return;
                }
            }
            // Wait briefly in case UIKit is about to deliver handleEventsForBackgroundURLSession:
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf) return;
                [innerSelf.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *d2,
                                                                   NSArray<NSURLSessionUploadTask *> *u2,
                                                                   NSArray<NSURLSessionDownloadTask *> *dl2) {
                    @synchronized(innerSelf) {
                        if (dl2.count > 0) {
                            innerSelf.downloadTask = dl2.firstObject;
                            innerSelf.isDownloading = YES;
                        } else if (innerSelf.downloadTask == nil && innerSelf.backgroundCompletionHandler == nil && innerSelf.isDownloading) {
                            innerSelf.isDownloading = NO;
                            [innerSelf clearPersistedActiveState];
                        }
                    }
                }];
            });
        }];
    }
    return self;
}

- (instancetype)init {
    return [IPSWDownloader sharedDownloader];
}

#pragma mark - State Persistence

- (void)restoreActiveStateFromDefaults {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kActiveDownloadDefaultsKey];
    if (![saved isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString *downloadId = saved[@"downloadId"];
    NSString *primaryStr = saved[@"primaryURL"];
    if (![downloadId isKindOfClass:[NSString class]] || downloadId.length == 0 ||
        ![primaryStr isKindOfClass:[NSString class]] || primaryStr.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kActiveDownloadDefaultsKey];
        return;
    }

    _downloadId = [downloadId copy];
    NSString *title = saved[@"displayTitle"];
    _displayTitle = ([title isKindOfClass:[NSString class]] && title.length > 0) ? [title copy] : [downloadId copy];
    _primaryURL = [NSURL URLWithString:primaryStr];
    NSString *fallbackStr = saved[@"fallbackURL"];
    _fallbackURL = ([fallbackStr isKindOfClass:[NSString class]] && fallbackStr.length > 0) ? [NSURL URLWithString:fallbackStr] : nil;
    NSString *sha1 = saved[@"expectedSHA1"];
    _expectedSHA1 = [sha1 isKindOfClass:[NSString class]] ? [sha1 lowercaseString] : nil;
    _expectedBytes = [saved[@"expectedBytes"] longLongValue];
    _usingFallback = [saved[@"usingFallback"] boolValue];
    NSDictionary *meta = saved[@"metadata"];
    _activeMetadata = [meta isKindOfClass:[NSDictionary class]] ? [meta copy] : nil;
    _lastTotalBytesExpected = _expectedBytes;
    _isDownloading = YES;
}

- (void)persistActiveState {
    if (self.downloadId.length == 0 || !self.primaryURL) {
        return;
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"downloadId"] = self.downloadId;
    dict[@"displayTitle"] = self.displayTitle ?: self.downloadId;
    dict[@"primaryURL"] = self.primaryURL.absoluteString;
    if (self.fallbackURL.absoluteString.length > 0) {
        dict[@"fallbackURL"] = self.fallbackURL.absoluteString;
    }
    if (self.expectedSHA1.length > 0) {
        dict[@"expectedSHA1"] = self.expectedSHA1;
    }
    dict[@"expectedBytes"] = @(self.expectedBytes);
    dict[@"usingFallback"] = @(self.usingFallback);
    if (self.activeMetadata.count > 0) {
        dict[@"metadata"] = self.activeMetadata;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:dict forKey:kActiveDownloadDefaultsKey];
    [defaults synchronize];
}

- (void)clearPersistedActiveState {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kActiveDownloadDefaultsKey];
    [defaults synchronize];
}

- (void)storePendingCompletedInfo:(NSDictionary *)info {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:info forKey:kPendingCompletedDefaultsKey];
    [defaults synchronize];
}

- (nullable NSDictionary *)consumePendingCompletedDownloadInfo {
    @synchronized(self) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary *info = [defaults dictionaryForKey:kPendingCompletedDefaultsKey];
        if (info) {
            [defaults removeObjectForKey:kPendingCompletedDefaultsKey];
            [defaults synchronize];
        }
        return info;
    }
}

#pragma mark - Paths

- (NSString *)firmwaresDirectoryPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = [paths.firstObject stringByAppendingPathComponent:@"Firmwares"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)legacyIPSWFilePathForId:(NSString *)downloadId {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *ipswDir = [paths.firstObject stringByAppendingPathComponent:@"ipsw"];
    return [ipswDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipsw", downloadId]];
}

#pragma mark - Public Control

- (void)startDownloadWithId:(NSString *)downloadId
               displayTitle:(NSString *)displayTitle
                 primaryURL:(NSURL *)primaryURL
                fallbackURL:(nullable NSURL *)fallbackURL
               expectedSHA1:(nullable NSString *)sha1
              expectedBytes:(int64_t)expectedBytes
                   metadata:(nullable NSDictionary *)metadata
                   progress:(nullable IPSWDownloadProgressBlock)progressBlock
                 completion:(nullable IPSWDownloadCompletionBlock)completionBlock {
    [IPSWDownloader requestNotificationPermissionIfNeeded];

    @synchronized(self) {
        if (self.downloadTask) {
            [self.downloadTask cancel];
            self.downloadTask = nil;
        }
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPendingCompletedDefaultsKey];

        self.downloadId = [downloadId copy];
        self.displayTitle = displayTitle.length > 0 ? [displayTitle copy] : [downloadId copy];
        self.primaryURL = primaryURL;
        self.fallbackURL = fallbackURL;
        self.expectedSHA1 = [sha1 lowercaseString];
        self.expectedBytes = expectedBytes;
        self.activeMetadata = metadata ? [metadata copy] : nil;
        self.usingFallback = NO;
        self.usingForegroundFallback = self.backgroundSessionUnavailable;
        self.isDownloading = YES;
        self.progressBlock = progressBlock;
        self.completionBlock = completionBlock;

        self.lastProgressTime = [NSDate timeIntervalSinceReferenceDate];
        self.lastBytesWritten = 0;
        self.lastTotalBytesWritten = 0;
        self.lastTotalBytesExpected = expectedBytes;
        self.lastFractionCompleted = 0.0;
        self.lastSpeedMBs = 0.0;

        [self persistActiveState];

        if (self.usingForegroundFallback) {
            [self beginForegroundBackgroundTaskLocked];
        } else {
            [self endForegroundBackgroundTaskLocked];
        }

        NSURL *targetURL = self.primaryURL;
        NSURLSession *targetSession = [self activeSessionForNewTaskLocked];
        NSLog(@"[IPSWDownloader] Starting %@ download from: %@",
              self.usingForegroundFallback ? @"foreground-fallback" : @"background",
              targetURL);
        self.downloadTask = [targetSession downloadTaskWithURL:targetURL];
        self.downloadTask.taskDescription = self.downloadId;
        [self.downloadTask resume];
    }
}

- (void)attachProgress:(nullable IPSWDownloadProgressBlock)progressBlock
            completion:(nullable IPSWDownloadCompletionBlock)completionBlock {
    @synchronized(self) {
        self.progressBlock = progressBlock;
        self.completionBlock = completionBlock;
    }
}

- (void)clearCallbacks {
    @synchronized(self) {
        self.progressBlock = nil;
        self.completionBlock = nil;
    }
}

- (void)cancel {
    @synchronized(self) {
        if (self.downloadTask) {
            [self.downloadTask cancel];
            self.downloadTask = nil;
        }
        self.isDownloading = NO;
        self.progressBlock = nil;
        self.completionBlock = nil;
        self.activeMetadata = nil;
        self.lastTotalBytesWritten = 0;
        self.lastFractionCompleted = 0.0;
        self.lastSpeedMBs = 0.0;
        [self endForegroundBackgroundTaskLocked];
        [self clearPersistedActiveState];
    }
}

- (void)handleEventsForBackgroundURLSession:(NSString *)identifier
                          completionHandler:(void (^)(void))completionHandler {
    if (![identifier isEqualToString:kIPSWBackgroundSessionIdentifier]) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }
    @synchronized(self) {
        self.backgroundCompletionHandler = completionHandler;
    }
}

#pragma mark - Notifications

- (void)scheduleCompletionNotificationSuccess:(BOOL)success
                                 displayTitle:(NSString *)displayTitle
                                   downloadId:(NSString *)downloadId
                                 errorMessage:(nullable NSString *)errorMessage {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    NSString *label = displayTitle.length > 0 ? displayTitle : (downloadId ?: @"IPSW");

    if (success) {
        content.title = NSLocalizedString(@"ipsw_notif_done_title", nil);
        content.body = [NSString stringWithFormat:NSLocalizedString(@"ipsw_notif_done_body", nil), label];
    } else {
        content.title = NSLocalizedString(@"ipsw_notif_fail_title", nil);
        content.body = [NSString stringWithFormat:NSLocalizedString(@"ipsw_notif_fail_body", nil),
                        label, errorMessage ?: NSLocalizedString(@"download_failed_msg", nil)];
    }
    content.sound = [UNNotificationSound defaultSound];

    NSString *notifId = [NSString stringWithFormat:@"com.yuki1018.classictouch.ipsw.%@.%@",
                         success ? @"done" : @"fail",
                         downloadId ?: [[NSUUID UUID] UUIDString]];

    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:notifId content:content trigger:trigger];

    dispatch_group_enter(self.notificationGroup);
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                             withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[IPSWDownloader] Failed to schedule local notification: %@", error);
        }
        dispatch_group_leave(self.notificationGroup);
    }];
}

#pragma mark - Internal Completion / Retry

- (NSURLSession *)ensureForegroundSessionLocked {
    if (!self.foregroundSession) {
        NSURLSessionConfiguration *fgConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        fgConfig.allowsCellularAccess = YES;
        fgConfig.waitsForConnectivity = YES;
        fgConfig.timeoutIntervalForRequest = 60.0;
        fgConfig.timeoutIntervalForResource = 3600.0 * 12.0;
        fgConfig.HTTPMaximumConnectionsPerHost = 4;
        self.foregroundSession = [NSURLSession sessionWithConfiguration:fgConfig
                                                               delegate:self
                                                          delegateQueue:self.delegateQueue];
    }
    return self.foregroundSession;
}

- (NSURLSession *)activeSessionForNewTaskLocked {
    if (self.usingForegroundFallback) {
        return [self ensureForegroundSessionLocked];
    }
    return self.session;
}

- (void)beginForegroundBackgroundTaskLocked {
    if (self.foregroundBgTaskId != UIBackgroundTaskInvalid) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    UIBackgroundTaskIdentifier taskId = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"IPSWForegroundDownload" expirationHandler:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        @synchronized(strongSelf) {
            [strongSelf endForegroundBackgroundTaskLocked];
        }
    }];
    self.foregroundBgTaskId = taskId;
}

- (void)endForegroundBackgroundTaskLocked {
    UIBackgroundTaskIdentifier taskId = self.foregroundBgTaskId;
    if (taskId == UIBackgroundTaskInvalid) {
        return;
    }
    self.foregroundBgTaskId = UIBackgroundTaskInvalid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] endBackgroundTask:taskId];
    });
}

- (BOOL)trySwitchToForegroundSessionWithResumeDataLocked:(nullable NSData *)resumeData {
    if (self.usingForegroundFallback) {
        return NO;
    }
    NSURL *targetURL = (self.usingFallback && self.fallbackURL) ? self.fallbackURL : self.primaryURL;
    if (!targetURL && resumeData.length == 0) {
        return NO;
    }
    self.usingForegroundFallback = YES;
    self.backgroundSessionUnavailable = YES;
    self.isDownloading = YES;
    self.lastProgressTime = [NSDate timeIntervalSinceReferenceDate];
    self.lastBytesWritten = 0;
    self.lastSpeedMBs = 0.0;
    [self beginForegroundBackgroundTaskLocked];

    NSURLSession *fg = [self ensureForegroundSessionLocked];
    if (resumeData.length > 0) {
        NSLog(@"[IPSWDownloader] Background session failed; resuming in-process foreground session (%lu bytes)",
              (unsigned long)resumeData.length);
        self.downloadTask = [fg downloadTaskWithResumeData:resumeData];
    } else {
        NSLog(@"[IPSWDownloader] Background session failed; retrying in-process foreground session from: %@", targetURL);
        self.downloadTask = [fg downloadTaskWithURL:targetURL];
    }
    self.downloadTask.taskDescription = self.downloadId;
    [self.downloadTask resume];
    return YES;
}

- (BOOL)tryStartFallbackDownloadLocked {
    if (self.usingFallback || !self.fallbackURL) {
        return NO;
    }
    self.usingFallback = YES;
    self.isDownloading = YES;
    self.lastProgressTime = [NSDate timeIntervalSinceReferenceDate];
    self.lastBytesWritten = 0;
    self.lastTotalBytesWritten = 0;
    self.lastTotalBytesExpected = self.expectedBytes;
    self.lastFractionCompleted = 0.0;
    self.lastSpeedMBs = 0.0;
    [self persistActiveState];

    NSLog(@"[IPSWDownloader] Switching to fallback mirror: %@", self.fallbackURL);
    self.downloadTask = [[self activeSessionForNewTaskLocked] downloadTaskWithURL:self.fallbackURL];
    self.downloadTask.taskDescription = self.downloadId;
    [self.downloadTask resume];
    return YES;
}

- (void)finishWithURL:(nullable NSURL *)destURL error:(nullable NSError *)error cancelled:(BOOL)cancelled {
    NSString *finishedId = nil;
    NSString *finishedTitle = nil;
    NSDictionary *metadataCopy = nil;
    IPSWDownloadCompletionBlock completion = nil;

    @synchronized(self) {
        finishedId = [self.downloadId copy];
        finishedTitle = [self.displayTitle copy];
        metadataCopy = [self.activeMetadata copy];
        completion = [self.completionBlock copy];

        self.downloadTask = nil;
        self.isDownloading = NO;
        self.progressBlock = nil;
        self.completionBlock = nil;
        self.activeMetadata = nil;
        [self endForegroundBackgroundTaskLocked];
        [self clearPersistedActiveState];
    }

    if (!cancelled) {
        [self scheduleCompletionNotificationSuccess:(error == nil && destURL != nil)
                                       displayTitle:finishedTitle ?: finishedId
                                         downloadId:finishedId ?: @""
                                       errorMessage:error.localizedDescription];
    }

    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(destURL, error);
        });
    } else if (!cancelled && finishedId.length > 0) {
        NSMutableDictionary *pending = [NSMutableDictionary dictionary];
        pending[@"downloadId"] = finishedId;
        if (finishedTitle.length > 0) {
            pending[@"displayTitle"] = finishedTitle;
        }
        if (destURL.path.length > 0) {
            pending[@"localPath"] = destURL.path;
        }
        if (error.localizedDescription.length > 0) {
            pending[@"errorMessage"] = error.localizedDescription;
        }
        if (metadataCopy.count > 0) {
            pending[@"metadata"] = metadataCopy;
        }
        [self storePendingCompletedInfo:pending];
    }
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    IPSWDownloadProgressBlock progress = nil;
    int64_t expected = 0;
    double frac = 0.0;
    double speedCopy = 0.0;

    @synchronized(self) {
        if (self.downloadTask && downloadTask != self.downloadTask) {
            return;
        }
        if (!self.downloadTask) {
            self.downloadTask = downloadTask;
            self.isDownloading = YES;
        }

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval dt = now - self.lastProgressTime;
        if (dt >= 0.5) {
            int64_t bytesInInterval = totalBytesWritten - self.lastBytesWritten;
            self.lastSpeedMBs = (double)bytesInInterval / (1024.0 * 1024.0 * dt);
            self.lastProgressTime = now;
            self.lastBytesWritten = totalBytesWritten;
        } else if (self.lastSpeedMBs == 0.0 && dt > 0.05 && totalBytesWritten > 0) {
            self.lastSpeedMBs = (double)totalBytesWritten / (1024.0 * 1024.0 * dt);
        }

        expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : self.expectedBytes;
        frac = expected > 0 ? (double)totalBytesWritten / (double)expected : 0.0;
        if (frac > 1.0) frac = 1.0;

        self.lastTotalBytesWritten = totalBytesWritten;
        self.lastTotalBytesExpected = expected;
        self.lastFractionCompleted = frac;
        speedCopy = self.lastSpeedMBs;
        if (self.progressBlock && (frac >= 1.0 || (now - self.lastUiProgressTime) >= 0.10)) {
            self.lastUiProgressTime = now;
            progress = [self.progressBlock copy];
        }
    }

    if (progress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(totalBytesWritten, expected, frac, speedCopy);
        });
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSLog(@"[IPSWDownloader] Finished downloading temporary file to %@", location);

    NSString *currentId = nil;
    NSString *expectedSHA1 = nil;

    @synchronized(self) {
        if (self.downloadTask && downloadTask != self.downloadTask) {
            NSLog(@"[IPSWDownloader] Ignoring stale downloadTask completion");
            return;
        }
        if (!self.downloadId) {
            [self restoreActiveStateFromDefaults];
        }
        currentId = [self.downloadId copy] ?: [downloadTask.taskDescription copy];
        expectedSHA1 = [self.expectedSHA1 copy];
    }

    if (currentId.length == 0) {
        NSError *err = [NSError errorWithDomain:@"IPSWDownloader"
                                           code:1002
                                       userInfo:@{NSLocalizedDescriptionKey: @"Download identifier missing after relaunch."}];
        [self finishWithURL:nil error:err cancelled:NO];
        return;
    }

    // Move location synchronously before returning (iOS deletes `location` once this delegate returns).
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *firmwaresDir = [self firmwaresDirectoryPath];
    NSString *stagingPath = [firmwaresDir stringByAppendingPathComponent:[NSString stringWithFormat:@".downloading-%@.ipsw", currentId]];
    NSURL *stagingURL = [NSURL fileURLWithPath:stagingPath];
    [fm removeItemAtURL:stagingURL error:nil];

    NSError *moveError = nil;
    if (![fm moveItemAtURL:location toURL:stagingURL error:&moveError]) {
        if (![fm copyItemAtURL:location toURL:stagingURL error:&moveError]) {
            NSLog(@"[IPSWDownloader] Failed to persist temporary download: %@", moveError);
            [self finishWithURL:nil error:moveError cancelled:NO];
            return;
        }
    }

    // Verify SHA-1 if expected
    if (expectedSHA1.length > 0) {
        NSError *hashError = nil;
        NSString *actualSHA1 = [IPSWDownloader computeSHA1ForFile:stagingURL error:&hashError];
        if (hashError || ![actualSHA1 isEqualToString:expectedSHA1]) {
            NSLog(@"[IPSWDownloader] SHA1 mismatch! Expected: %@, Actual: %@", expectedSHA1, actualSHA1);
            [fm removeItemAtURL:stagingURL error:nil];

            BOOL switched = NO;
            @synchronized(self) {
                switched = [self tryStartFallbackDownloadLocked];
            }
            if (switched) {
                return;
            }

            NSError *mismatchError = [NSError errorWithDomain:@"IPSWDownloader"
                                                         code:1001
                                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"SHA1 mismatch: expected %@, got %@", expectedSHA1, actualSHA1]}];
            [self finishWithURL:nil error:mismatchError cancelled:NO];
            return;
        }
        NSLog(@"[IPSWDownloader] SHA1 verification succeeded: %@", actualSHA1);
    }

    // Move to Documents/Firmwares/<id>.ipsw
    NSString *destPath = [firmwaresDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipsw", currentId]];
    NSURL *destURL = [NSURL fileURLWithPath:destPath];
    [fm removeItemAtURL:destURL error:nil];

    NSError *finalMoveError = nil;
    if (![fm moveItemAtURL:stagingURL toURL:destURL error:&finalMoveError]) {
        NSLog(@"[IPSWDownloader] Failed to move IPSW to Firmwares: %@", finalMoveError);
        [fm removeItemAtURL:stagingURL error:nil];
        [self finishWithURL:nil error:finalMoveError cancelled:NO];
        return;
    }

    // Clean up any legacy duplicate in Documents/ipsw/
    NSString *legacyPath = [self legacyIPSWFilePathForId:currentId];
    if ([fm fileExistsAtPath:legacyPath]) {
        [fm removeItemAtPath:legacyPath error:nil];
    }

    [self finishWithURL:destURL error:nil cancelled:NO];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) {
        return;
    }

    @synchronized(self) {
        if (self.downloadTask && task != self.downloadTask) {
            return;
        }
    }

    if (error.code == NSURLErrorCancelled) {
        [self finishWithURL:nil error:error cancelled:YES];
        return;
    }

    NSLog(@"[IPSWDownloader] Download error (session=%@): %@",
          (session == self.foregroundSession) ? @"foreground" : @"background",
          error);
    BOOL switched = NO;
    @synchronized(self) {
        if (session == self.session && !self.usingForegroundFallback) {
            NSData *resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
            switched = [self trySwitchToForegroundSessionWithResumeDataLocked:resumeData];
        }
        if (!switched) {
            switched = [self tryStartFallbackDownloadLocked];
        }
    }
    if (switched) {
        return;
    }

    [self finishWithURL:nil error:error cancelled:NO];
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    void (^handler)(void) = nil;
    @synchronized(self) {
        handler = [self.backgroundCompletionHandler copy];
        self.backgroundCompletionHandler = nil;
    }
    if (handler) {
        dispatch_group_notify(self.notificationGroup, dispatch_get_main_queue(), ^{
            handler();
        });
    }
}

#pragma mark - SHA1

+ (NSString *)computeSHA1ForFile:(NSURL *)fileURL error:(NSError **)error {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:error];
    if (!handle) return nil;

    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);

    const NSUInteger chunkSize = 1024 * 1024; // 1 MB
    while (1) {
        @autoreleasepool {
            NSData *data = [handle readDataOfLength:chunkSize];
            if (data.length == 0) break;
            CC_SHA1_Update(&ctx, data.bytes, (CC_LONG)data.length);
        }
    }
    [handle closeFile];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex lowercaseString];
}

@end

#import "AppDelegate.h"
#import "MainViewController.h"
#import "IPSWDownloader.h"
#import "ios_jit_helper.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <time.h>

static void ClassicSyncHostTimezoneEnv(void) {
    NSString *tzName = [NSTimeZone localTimeZone].name;
    if (tzName.length > 0) {
        setenv("TZ", tzName.UTF8String, 1);
        tzset();
    }
}

@implementation AppDelegate

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if ([top isKindOfClass:NSClassFromString(@"EmulatorViewController")] && !top.isBeingDismissed) {
        return [top supportedInterfaceOrientations];
    }
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [NSTimeZone resetSystemTimeZone];
    ClassicSyncHostTimezoneEnv();

    // Initialize JIT memory protections & TXM signal traps
    ios_jit_init_protection();

    // Configure local notifications
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    MainViewController *mainVC = [[MainViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:mainVC];
    nav.navigationBar.prefersLargeTitles = YES;

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // Defer background URLSession XPC handshake until after first window presentation
    dispatch_async(dispatch_get_main_queue(), ^{
        [IPSWDownloader sharedDownloader];
    });
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // Sync storage buffers before backgrounding
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Flush dirty buffers
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [NSTimeZone resetSystemTimeZone];
    ClassicSyncHostTimezoneEnv();
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    // Flush translation block caches when iOS signals memory pressure.
    typedef void (*qemu_flush_tb_fn)(void);
    qemu_flush_tb_fn flush_fn = (qemu_flush_tb_fn)dlsym(RTLD_DEFAULT, "qemu_ios_ui_flush_tb");
    if (flush_fn) {
        NSLog(@"[AppDelegate] Memory warning received! Flushing TB cache...");
        flush_fn();
    } else {
        NSLog(@"[AppDelegate] Memory warning received!");
    }
}

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    [[IPSWDownloader sharedDownloader] handleEventsForBackgroundURLSession:identifier completionHandler:completionHandler];
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionList);
}

@end

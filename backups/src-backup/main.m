#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "ios_jit_helper.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        // Earliest possible JIT init before UIKit sets up thread environments
        ios_jit_init_protection();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}

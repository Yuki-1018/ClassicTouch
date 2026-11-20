#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Inflates an `ITPACK01` archive, returning the concatenated payload and optionally its manifest `entries`.
FOUNDATION_EXPORT NSData * _Nullable ClassicInflateITPack(NSString *path, NSArray<NSDictionary *> * _Nullable * _Nullable outEntries);

/// Returns a directory containing pristine guest-tool binaries, extracting `guest-tools/host-tools.itpack`
/// on demand so iOS sideloaders cannot alter embedded guest Mach-O signatures or entitlements.
FOUNDATION_EXPORT NSString *ClassicGuestToolsDirectory(void);

NS_ASSUME_NONNULL_END

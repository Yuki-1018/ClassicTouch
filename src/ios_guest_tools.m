#import "ios_guest_tools.h"
#import <CommonCrypto/CommonDigest.h>
#include <pthread.h>
#include <string.h>
#include <zlib.h>

static NSString *ClassicSHA256Hex(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

NSData *ClassicInflateITPack(NSString *path, NSArray<NSDictionary *> **outEntries) {
    NSData *blob = [NSData dataWithContentsOfFile:path];
    if (blob.length < 16 || memcmp(blob.bytes, "ITPACK01", 8) != 0) {
        return nil;
    }
    const uint8_t *p = (const uint8_t *)blob.bytes;
    uint32_t idxLen = (uint32_t)p[8] | ((uint32_t)p[9] << 8) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 24);
    if ((uint64_t)12 + idxLen >= blob.length) {
        return nil;
    }

    NSData *idxData = [NSData dataWithBytesNoCopy:(void *)(p + 12) length:idxLen freeWhenDone:NO];
    NSDictionary *idxJson = [NSJSONSerialization JSONObjectWithData:idxData options:0 error:nil];
    NSArray *entries = [idxJson isKindOfClass:[NSDictionary class]] ? idxJson[@"entries"] : nil;
    if (![entries isKindOfClass:[NSArray class]]) {
        return nil;
    }

    uint64_t total = 0;
    for (NSDictionary *e in entries) {
        if (![e isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        total += [e[@"size"] unsignedLongLongValue];
    }
    if (total == 0 || total > (64ULL << 20)) {
        return nil;
    }

    NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)total];
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    zs.next_in = (Bytef *)(p + 12 + idxLen);
    zs.avail_in = (uInt)(blob.length - 12 - idxLen);
    zs.next_out = (Bytef *)payload.mutableBytes;
    zs.avail_out = (uInt)total;
    if (inflateInit(&zs) != Z_OK) {
        return nil;
    }
    int zrc = inflate(&zs, Z_FINISH);
    inflateEnd(&zs);
    if ((zrc != Z_STREAM_END && zrc != Z_OK) || zs.total_out != total) {
        return nil;
    }

    if (outEntries) {
        *outEntries = entries;
    }
    return payload;
}

static NSString *ClassicFindBundleGuestToolsDir(void) {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"guest-tools" ofType:nil];
    if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
        return p;
    }
    p = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"guest-tools"];
    if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
        return p;
    }
    p = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"guest-tools"];
    if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
        return p;
    }
    return nil;
}

NSString *ClassicGuestToolsDirectory(void) {
    static pthread_mutex_t sLock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&sLock);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *docTools = [docs stringByAppendingPathComponent:@"guest-tools"];
    NSString *bundleTools = ClassicFindBundleGuestToolsDir();
    NSString *packPath = bundleTools ? [bundleTools stringByAppendingPathComponent:@"host-tools.itpack"] : nil;

    if (!packPath || ![fm fileExistsAtPath:packPath]) {
        NSString *fallback = bundleTools ?: docTools;
        pthread_mutex_unlock(&sLock);
        return fallback;
    }

    NSData *packBytes = [NSData dataWithContentsOfFile:packPath];
    NSString *bundleVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"1";
    NSArray<NSString *> *bundleEntries = [[fm contentsOfDirectoryAtPath:bundleTools error:nil]
                                          sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *extraBundleFiles = [NSMutableArray array];
    for (NSString *name in bundleEntries) {
        if ([name isEqualToString:@"host-tools.itpack"] || [name hasPrefix:@"."]) {
            continue;
        }
        BOOL isDir = NO;
        NSString *src = [bundleTools stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:src isDirectory:&isDir] && !isDir) {
            [extraBundleFiles addObject:name];
        }
    }

    NSString *expectedStamp = packBytes ? [NSString stringWithFormat:@"v2:%@:%@", bundleVer, ClassicSHA256Hex(packBytes)] : bundleVer;
    NSString *stampPath = [docTools stringByAppendingPathComponent:@".host-tools.stamp"];
    NSString *existingStamp = [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil];

    BOOL upToDate = [existingStamp isEqualToString:expectedStamp] &&
                    [fm fileExistsAtPath:[docTools stringByAppendingPathComponent:@"it_initialize"]] &&
                    [fm fileExistsAtPath:[docTools stringByAppendingPathComponent:@"it_mobilegestalt"]];
    if (upToDate) {
        for (NSString *name in extraBundleFiles) {
            if (![fm fileExistsAtPath:[docTools stringByAppendingPathComponent:name]]) {
                upToDate = NO;
                break;
            }
        }
    }
    if (upToDate) {
        pthread_mutex_unlock(&sLock);
        return docTools;
    }

    NSArray<NSDictionary *> *entries = nil;
    NSData *payload = ClassicInflateITPack(packPath, &entries);
    if (!payload || !entries) {
        NSLog(@"[GuestTools] Failed to inflate host-tools.itpack at %@", packPath);
        NSString *fallback = bundleTools ?: docTools;
        pthread_mutex_unlock(&sLock);
        return fallback;
    }

    NSString *staging = [docs stringByAppendingPathComponent:@"guest-tools.staging"];
    [fm removeItemAtPath:staging error:nil];
    [fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil];

    uint64_t offset = 0;
    const uint8_t *raw = (const uint8_t *)payload.bytes;
    BOOL ok = YES;
    for (NSDictionary *e in entries) {
        NSString *name = [e[@"name"] isKindOfClass:[NSString class]] ? e[@"name"] : @"";
        NSUInteger sz = (NSUInteger)[e[@"size"] unsignedLongLongValue];
        NSString *wantSha = [e[@"sha256"] isKindOfClass:[NSString class]] ? e[@"sha256"] : nil;
        NSNumber *modeNum = [e[@"mode"] isKindOfClass:[NSNumber class]] ? e[@"mode"] : nil;

        if (name.length == 0 || [name hasPrefix:@"/"] || [name containsString:@".."] ||
            [name containsString:@"/"] || offset + sz > payload.length) {
            ok = NO;
            break;
        }
        NSData *entryData = [NSData dataWithBytes:(raw + offset) length:sz];
        offset += sz;
        if (wantSha.length > 0 && ![ClassicSHA256Hex(entryData) isEqualToString:wantSha]) {
            NSLog(@"[GuestTools] SHA-256 mismatch extracting %@", name);
            ok = NO;
            break;
        }
        NSString *dst = [staging stringByAppendingPathComponent:name];
        if (![entryData writeToFile:dst atomically:YES]) {
            ok = NO;
            break;
        }
        NSUInteger mode = modeNum ? modeNum.unsignedIntegerValue : 0755;
        [fm setAttributes:@{NSFilePosixPermissions: @(mode)} ofItemAtPath:dst error:nil];
    }

    if (ok && offset == payload.length) {
        for (NSString *name in extraBundleFiles) {
            NSString *src = [bundleTools stringByAppendingPathComponent:name];
            NSString *dst = [staging stringByAppendingPathComponent:name];
            NSError *copyErr = nil;
            [fm removeItemAtPath:dst error:nil];
            if (![fm copyItemAtPath:src toPath:dst error:&copyErr]) {
                NSLog(@"[GuestTools] Failed copying %@ -> %@: %@", src, dst, copyErr);
                ok = NO;
                break;
            }
        }
    }

    if (ok && offset == payload.length) {
        [expectedStamp writeToFile:[staging stringByAppendingPathComponent:@".host-tools.stamp"]
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:nil];
        [fm removeItemAtPath:docTools error:nil];
        NSError *moveErr = nil;
        if (![fm moveItemAtPath:staging toPath:docTools error:&moveErr]) {
            NSLog(@"[GuestTools] Failed moving staging -> %@: %@", docTools, moveErr);
        } else {
            NSLog(@"[GuestTools] Extracted %lu pristine guest tool(s) from host-tools.itpack", (unsigned long)entries.count);
        }
    } else {
        [fm removeItemAtPath:staging error:nil];
    }

    pthread_mutex_unlock(&sLock);
    return [fm fileExistsAtPath:docTools] ? docTools : (bundleTools ?: docTools);
}

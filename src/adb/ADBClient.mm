#import "ADBClient.h"
#import "ADBKey.h"
#import "Client.hpp"

#include <atomic>
#include <dlfcn.h>
#include <exception>
#include <filesystem>
#include <span>
#include <string>
#include <vector>

typedef bool (*AEADBConnectedFn)(void);
typedef void (*AEADBDisconnectFn)(void);
typedef size_t (*AEADBReadFn)(uint8_t *out_buf, size_t max_bytes);
typedef size_t (*AEADBWriteFn)(const uint8_t *data, size_t len);

@interface AEADBClient () {
    AEADBConnectedFn _fnConnected;
    AEADBDisconnectFn _fnDisconnect;
    AEADBReadFn _fnRead;
    AEADBWriteFn _fnWrite;
    std::atomic<bool> _cancelRequested;
    std::atomic<bool> _inFlight;
    dispatch_queue_t _queue;
}
@end

@implementation AEADBClient

- (instancetype)initWithEngineHandle:(nullable void *)engineHandle {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.classictouch.adb.install", DISPATCH_QUEUE_SERIAL);
        _cancelRequested.store(false);
        _inFlight.store(false);
        if (engineHandle) {
            _fnConnected = (AEADBConnectedFn)dlsym(engineHandle, "qemu_android_adb_connected");
            _fnDisconnect = (AEADBDisconnectFn)dlsym(engineHandle, "qemu_android_adb_disconnect");
            _fnRead = (AEADBReadFn)dlsym(engineHandle, "qemu_android_adb_read");
            _fnWrite = (AEADBWriteFn)dlsym(engineHandle, "qemu_android_adb_write");
        }
    }
    return self;
}

- (BOOL)isReady {
    return (_fnConnected != NULL && _fnRead != NULL && _fnWrite != NULL && _fnConnected());
}

- (void)cancelInstall {
    _cancelRequested.store(true);
}

- (void)installAPKAtURL:(NSURL *)apkURL
               progress:(nullable void (^)(NSString *statusText, float progress))progress
             completion:(nullable void (^)(BOOL success, NSString *message))completion {
    if (_inFlight.exchange(true)) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, NSLocalizedString(@"apk_install_in_progress", nil));
            });
        }
        return;
    }

    _cancelRequested.store(false);
    NSURL *sourceURL = apkURL;
    __weak AEADBClient *weakSelf = self;

    auto reportProgress = ^(NSString *text, float value) {
        if (!progress) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(text, value);
        });
    };

    auto finish = ^(BOOL success, NSString *msg) {
        __strong AEADBClient *s = weakSelf;
        if (s) s->_inFlight.store(false);
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success, msg);
        });
    };

    dispatch_async(_queue, ^{
        __strong AEADBClient *s = weakSelf;
        if (!s || !s->_fnConnected || !s->_fnRead || !s->_fnWrite) {
            finish(NO, NSLocalizedString(@"apk_install_not_ready", nil));
            return;
        }
        if (!s->_fnConnected()) {
            finish(NO, NSLocalizedString(@"apk_install_not_ready", nil));
            return;
        }

        NSError *keyErr = nil;
        SecKeyRef privKey = [AEADBKey loadOrCreatePrivateKeyWithError:&keyErr];
        if (!privKey) {
            finish(NO, keyErr.localizedDescription ?: @"Failed to prepare ADB RSA key.");
            return;
        }

        std::string sourcePath = sourceURL.path.UTF8String ?: "";
        if (sourcePath.empty()) {
            CFRelease(privKey);
            finish(NO, NSLocalizedString(@"apk_invalid_extension", nil));
            return;
        }

        try {
            emu::adb::Transport io;
            io.connected = [s]() -> bool {
                return s->_fnConnected && s->_fnConnected();
            };
            io.cancelled = [s]() -> bool {
                return s->_cancelRequested.load();
            };
            io.read = [s](std::span<uint8_t> buf) -> size_t {
                return s->_fnRead ? s->_fnRead(buf.data(), buf.size()) : 0;
            };
            io.write = [s](std::span<const uint8_t> buf) -> size_t {
                return s->_fnWrite ? s->_fnWrite(buf.data(), buf.size()) : 0;
            };
            io.signToken = [privKey](std::span<const uint8_t> token) -> std::vector<uint8_t> {
                NSData *tokenData = [NSData dataWithBytes:token.data() length:token.size()];
                NSError *err = nil;
                NSData *sig = [AEADBKey signToken:tokenData withPrivateKey:privKey error:&err];
                if (!sig) return {};
                const uint8_t *p = (const uint8_t *)sig.bytes;
                return std::vector<uint8_t>(p, p + sig.length);
            };
            io.publicKey = [privKey]() -> std::vector<uint8_t> {
                NSError *err = nil;
                NSData *pub = [AEADBKey androidPublicKeyForPrivateKey:privKey error:&err];
                if (!pub) return {};
                const uint8_t *p = (const uint8_t *)pub.bytes;
                return std::vector<uint8_t>(p, p + pub.length);
            };

            emu::adb::Client client(std::move(io));
            reportProgress(NSLocalizedString(@"apk_connecting_adb", nil), 0.05f);
            client.connect();

            std::string remotePath = "/data/local/tmp/ct_install.apk";
            reportProgress(NSLocalizedString(@"apk_pushing", nil), 0.12f);
            client.push(std::filesystem::path(sourcePath), remotePath,
                        [&](uint64_t sent, uint64_t total) {
                float frac = (total > 0) ? (float)sent / (float)total : 0.0f;
                float mapped = 0.12f + 0.63f * frac;
                NSString *txt = [NSString stringWithFormat:NSLocalizedString(@"apk_pushing_pct_fmt", nil),
                                 (int)(frac * 100.0f)];
                reportProgress(txt, mapped);
            });

            reportProgress(NSLocalizedString(@"apk_installing", nil), 0.85f);
            std::string output = client.shell("pm install -r " + remotePath + "; rm -f " + remotePath);
            NSString *nsOut = [NSString stringWithUTF8String:output.c_str()] ?: @"";
            NSString *trimmed = [nsOut stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

            if (s->_fnDisconnect) {
                s->_fnDisconnect();
            }
            CFRelease(privKey);

            if ([trimmed containsString:@"Success"]) {
                NSString *apkName = sourceURL.lastPathComponent ?: @"app.apk";
                NSString *msg = [NSString stringWithFormat:NSLocalizedString(@"apk_install_success_msg_fmt", nil), apkName];
                finish(YES, msg);
            } else {
                NSString *errText = trimmed.length > 0 ? trimmed : @"pm install returned no output";
                finish(NO, errText);
            }
        } catch (const std::exception &ex) {
            if (s->_fnDisconnect) {
                s->_fnDisconnect();
            }
            CFRelease(privKey);
            NSString *errMsg = [NSString stringWithUTF8String:ex.what()] ?: @"ADB install error";
            finish(NO, errMsg);
        } catch (...) {
            if (s->_fnDisconnect) {
                s->_fnDisconnect();
            }
            CFRelease(privKey);
            finish(NO, @"Unknown C++ error during APK install");
        }
    });
}

@end

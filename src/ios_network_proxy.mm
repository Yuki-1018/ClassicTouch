//
// ClassicTouch - Native Classic iOS Emulator for Modern iOS & iPadOS
//
// Copyright (c) 2026 ClassicTouch Authors.
// SPDX-License-Identifier: GPL-2.0-only
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; version 2 of the License.
//

#import "ios_network_proxy.h"
#include "Network.hpp"
#include <exception>
#include <memory>
#include <string>
#include <unistd.h>

@interface IOSNetworkProxy () {
    std::unique_ptr<lt::network::Proxy> _proxy;
}
@property (nonatomic, readwrite, copy) NSString *socketPath;
@property (nonatomic, readwrite, strong) NSData *certificateDER;
@property (nonatomic, readwrite, copy) NSString *certificateFingerprint;
@end

@implementation IOSNetworkProxy

+ (nullable instancetype)startWithIdentityDirectory:(NSString *)identityDir
                                         socketPath:(NSString *)socketPath
                                       errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    if (!identityDir.length || !socketPath.length) {
        if (errorMessage) *errorMessage = @"Invalid proxy directory or socket path";
        return nil;
    }

    // Strip /private prefix if present to stay well within sockaddr_un sun_path limit (104 bytes)
    NSString *effectiveSocketPath = socketPath;
    if ([effectiveSocketPath hasPrefix:@"/private/var/"]) {
        effectiveSocketPath = [@"/var/" stringByAppendingString:[effectiveSocketPath substringFromIndex:@"/private/var/".length]];
    }

    const char *sockCStr = effectiveSocketPath.fileSystemRepresentation;
    if (!sockCStr || strlen(sockCStr) >= 103) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Proxy socket path exceeds sun_path limit (%zu >= 103): %@", sockCStr ? strlen(sockCStr) : 0, effectiveSocketPath];
        return nil;
    }

    NSString *sockDir = [effectiveSocketPath stringByDeletingLastPathComponent];
    if (sockDir.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:sockDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    unlink(sockCStr);

    try {
        lt::network::Configuration cfg;
        cfg.mode = lt::network::Mode::direct;
        cfg.local_network = false;

        auto proxy = std::make_unique<lt::network::Proxy>(
            std::string(identityDir.fileSystemRepresentation), cfg);
        proxy->listen(std::string(sockCStr));

        std::string der = proxy->certificate();
        std::string fp = proxy->fingerprint();

        IOSNetworkProxy *wrapper = [[IOSNetworkProxy alloc] init];
        wrapper->_proxy = std::move(proxy);
        wrapper.socketPath = effectiveSocketPath;
        wrapper.certificateDER = [NSData dataWithBytes:der.data() length:der.size()];
        wrapper.certificateFingerprint = [NSString stringWithUTF8String:fp.c_str()] ?: @"";
        return wrapper;
    } catch (const std::exception &ex) {
        unlink(sockCStr);
        if (errorMessage) {
            *errorMessage = [NSString stringWithUTF8String:ex.what()] ?: @"Proxy startup failed";
        }
        return nil;
    }
}

- (void)stop {
    if (_proxy) {
        _proxy.reset();
    }
    if (self.socketPath.length) {
        unlink(self.socketPath.fileSystemRepresentation);
    }
}

- (void)dealloc {
    [self stop];
}

@end

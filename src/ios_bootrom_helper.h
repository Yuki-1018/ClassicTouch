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

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <string.h>

NS_ASSUME_NONNULL_BEGIN

static NSString * const kBootromS5L8900SHA256 = @"220027d6f8ea24603f8c5ad5e920ab553d85a9cd809d79c7e6f6f0eefdc2bc95";
static NSString * const kBootromS5L8720SHA256 = @"55f4d8ea2791ba51dd89934168f38f0fb21ce8762ff614c1e742407c0d3ca054";

typedef NS_ENUM(NSInteger, ClassicBootromSoC) {
    ClassicBootromSoCInvalid = 0,
    ClassicBootromSoCS5L8900 = 1,
    ClassicBootromSoCS5L8720 = 2,
    ClassicBootromSoCAmbiguous = 3,
};

static inline NSString * _Nullable ClassicBootromSHA256HexForData(NSData *data) {
    if (!data || data.length == 0 || data.length > (1ULL << 20)) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static inline BOOL ClassicBootromDataHasARM32ResetVector(NSData *data) {
    if (!data || data.length != 65536) return NO;
    const uint8_t *b = (const uint8_t *)data.bytes;
    uint32_t w0 = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    // ARM32 reset vector: B <rel> (0xEAxxxxxx) or LDR pc, [pc, #imm] (0xE59FFxxx).
    return ((w0 & 0xFF000000u) == 0xEA000000u) || ((w0 & 0xFFFFF000u) == 0xE59FF000u);
}

static inline BOOL ClassicBootromDataContainsTag(NSData *data, const char *lowerNeedle) {
    if (!data || data.length == 0 || !lowerNeedle || !*lowerNeedle) return NO;
    size_t nlen = strlen(lowerNeedle);
    if (data.length < nlen) return NO;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    for (size_t i = 0; i <= data.length - nlen; i++) {
        size_t j = 0;
        for (; j < nlen; j++) {
            uint8_t c = bytes[i + j];
            if (c >= 'A' && c <= 'Z') c = (uint8_t)(c + ('a' - 'A'));
            if (c != (uint8_t)lowerNeedle[j]) break;
        }
        if (j == nlen) return YES;
    }
    return NO;
}

static inline ClassicBootromSoC ClassicClassifyBootromFile(NSString *path, NSString * _Nullable * _Nullable outSHA256) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0 || data.length > (1ULL << 20)) return ClassicBootromSoCInvalid;

    NSString *sha = ClassicBootromSHA256HexForData(data);
    if (outSHA256) *outSHA256 = sha;

    if ([sha isEqualToString:kBootromS5L8900SHA256]) return ClassicBootromSoCS5L8900;
    if ([sha isEqualToString:kBootromS5L8720SHA256]) return ClassicBootromSoCInvalid;

    // Accept real 64 KiB ARM32 S5L8900 BootROM dumps (whose SHA-256 differs from patched releases),
    // while explicitly rejecting S5L8720 ROMs.
    if (!ClassicBootromDataHasARM32ResetVector(data)) return ClassicBootromSoCInvalid;

    if (ClassicBootromDataContainsTag(data, "s5l8720") || ClassicBootromDataContainsTag(data, "iboot-240")) {
        return ClassicBootromSoCInvalid;
    }

    NSString *name = path.lastPathComponent.lowercaseString;
    if ([name containsString:@"8720"] || [name containsString:@"240_4"] || [name containsString:@"240.4"] || [name containsString:@"n72"]) {
        return ClassicBootromSoCInvalid;
    }
    return ClassicBootromSoCS5L8900;
}

static inline BOOL ClassicBootromFileMatchesExpectedType(NSString *path, NSString *romType) {
    if (![romType isEqualToString:@"s5l8900"]) return NO;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0 || data.length > (1ULL << 20)) return NO;

    NSString *sha = ClassicBootromSHA256HexForData(data);
    if ([sha isEqualToString:kBootromS5L8900SHA256]) return YES;
    if ([sha isEqualToString:kBootromS5L8720SHA256]) return NO;
    if (!ClassicBootromDataHasARM32ResetVector(data)) return NO;
    if (ClassicBootromDataContainsTag(data, "s5l8720") || ClassicBootromDataContainsTag(data, "iboot-240")) return NO;
    if (![path.lastPathComponent.lowercaseString isEqualToString:@"bootrom.bin"]) return YES;
    return ClassicBootromDataContainsTag(data, "s5l8900") || ClassicBootromDataContainsTag(data, "iboot-121");
}

NS_ASSUME_NONNULL_END

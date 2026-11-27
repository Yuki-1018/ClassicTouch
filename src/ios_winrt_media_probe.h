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
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct ClassicWinRTMediaInfo {
    BOOL exists;
    uint64_t fileSize;
    BOOL hasISO9660PVD;
    BOOL hasElTorito;
    BOOL hasUDF;
    BOOL hasMBR;
    BOOL hasGPT;
    BOOL isVHD;
    BOOL isVHDX;
    BOOL isQCOW2;
} ClassicWinRTMediaInfo;

static inline ClassicWinRTMediaInfo ClassicProbeWinRTMedia(NSString *path) {
    ClassicWinRTMediaInfo info;
    memset(&info, 0, sizeof(info));
    if (path.length == 0) return info;

    int fd = open([path fileSystemRepresentation], O_RDONLY);
    if (fd < 0) return info;

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return info;
    }

    info.exists = YES;
    info.fileSize = (uint64_t)st.st_size;

    const size_t headCap = 65536;
    uint8_t *head = (uint8_t *)calloc(1, headCap);
    if (head) {
        ssize_t n = pread(fd, head, headCap, 0);
        if (n > 0) {
            size_t len = (size_t)n;
            if (len >= 512 && head[0x1FE] == 0x55 && head[0x1FF] == 0xAA) {
                info.hasMBR = YES;
            }
            if (len >= 520 && memcmp(head + 0x200, "EFI PART", 8) == 0) {
                info.hasGPT = YES;
            }
            if (len >= 8 && memcmp(head, "conectix", 8) == 0) {
                info.isVHD = YES;
            }
            if (len >= 8 && memcmp(head, "vhdxfile", 8) == 0) {
                info.isVHDX = YES;
            }
            if (len >= 4 && memcmp(head, "QFI\xfb", 4) == 0) {
                info.isQCOW2 = YES;
            }
            // Scan ISO-9660 Volume Descriptors (sectors 16..31 => 0x8000..0xF800)
            for (size_t off = 0x8000; off + 2048 <= len && off <= 0xF800; off += 2048) {
                uint8_t type = head[off];
                if (memcmp(head + off + 1, "CD001", 5) == 0) {
                    if (type == 0x01) {
                        info.hasISO9660PVD = YES;
                    } else if (type == 0x00 && off + 39 <= len &&
                               memcmp(head + off + 7, "EL TORITO SPECIFICATION", 23) == 0) {
                        info.hasElTorito = YES;
                    } else if (type == 0xFF) {
                        break;
                    }
                } else if (memcmp(head + off + 1, "BEA01", 5) == 0 ||
                           memcmp(head + off + 1, "NSR02", 5) == 0 ||
                           memcmp(head + off + 1, "NSR03", 5) == 0) {
                    info.hasUDF = YES;
                }
            }
        }
        free(head);
    }

    if (!info.isVHD && info.fileSize >= 512) {
        uint8_t tail[512];
        if (pread(fd, tail, sizeof(tail), (off_t)(info.fileSize - 512)) == 512 &&
            memcmp(tail, "conectix", 8) == 0) {
            info.isVHD = YES;
        }
    }

    close(fd);
    return info;
}

static inline NSString *ClassicDescribeWinRTMedia(ClassicWinRTMediaInfo info) {
    if (!info.exists) return @"Missing";
    if (info.fileSize == 0) return @"Empty (0 bytes)";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (info.isVHD) [parts addObject:@"VHD"];
    if (info.isVHDX) [parts addObject:@"VHDX"];
    if (info.isQCOW2) [parts addObject:@"QCOW2"];
    if (info.hasElTorito) {
        [parts addObject:@"ISO-9660 + El Torito (UEFI bootable)"];
    } else if (info.hasISO9660PVD) {
        [parts addObject:@"ISO-9660 (no El Torito boot record)"];
    } else if (info.hasUDF) {
        [parts addObject:@"UDF-only ISO (missing El Torito CD001 — UEFI Shell will show BLK0 only)"];
    }
    if (info.hasGPT) {
        [parts addObject:@"GPT"];
    } else if (info.hasMBR) {
        [parts addObject:@"MBR"];
    }
    if (parts.count == 0) {
        return @"Blank/unformatted";
    }
    return [parts componentsJoinedByString:@", "];
}

NS_ASSUME_NONNULL_END

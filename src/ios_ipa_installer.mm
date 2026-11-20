#import "ios_ipa_installer.h"
#import "ios_usb_mux.h"

#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <sys/socket.h>
#include <unistd.h>
#include <zlib.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <vector>

@interface IOSIpaInfo ()
@property (nonatomic, readwrite, copy) NSString *bundleId;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy, nullable) NSString *version;
@property (nonatomic, readwrite, copy, nullable) NSString *shortVersion;
@property (nonatomic, readwrite, copy, nullable) NSString *minimumOS;
@property (nonatomic, readwrite, assign) uint64_t ipaBytes;
@property (nonatomic, readwrite, assign) uint64_t unpackedBytes;
@end

@implementation IOSIpaInfo
@end

namespace {

static NSError *makeIpaError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"IOSIpaInstaller"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"Unknown IPA error"}];
}

// ---------- Byte helpers ----------
static uint16_t le16(const uint8_t *p) { return uint16_t(p[0] | (p[1] << 8)); }
static uint32_t le32(const uint8_t *p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
static uint64_t le64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; --i) v = (v << 8) | p[i];
    return v;
}
static uint32_t be32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
static uint64_t le64FromPtr(const uint8_t *p) { return le64(p); }

static void appendLe64(std::vector<uint8_t> &v, uint64_t val) {
    for (int i = 0; i < 8; i++) v.push_back(uint8_t((val >> (i * 8)) & 0xff));
}

// ---------- Guest Target & Version ----------
struct GuestTarget {
    std::string productType;
    std::string iosVersion;
    std::string arch;   // "armv6" or "armv7"
    std::string family; // "1" or "2"
    std::array<uint32_t, 3> iosParts{0, 0, 0};
};

static bool parseVersion(const std::string &text, std::array<uint32_t, 3> &out) {
    out = {0, 0, 0};
    if (text.empty()) return false;
    size_t pos = 0;
    int idx = 0;
    while (pos <= text.size()) {
        if (idx >= 3) return false;
        size_t dot = text.find('.', pos);
        std::string part = (dot == std::string::npos) ? text.substr(pos) : text.substr(pos, dot - pos);
        if (part.empty()) return false;
        for (char c : part) {
            if (c < '0' || c > '9') return false;
        }
        out[idx++] = uint32_t(std::stoul(part));
        if (dot == std::string::npos) break;
        pos = dot + 1;
    }
    return out[0] != 0;
}

static bool targetFromGuest(const std::string &product, const std::string &ios, GuestTarget &out) {
    if (!parseVersion(ios, out.iosParts)) return false;
    out.productType = product;
    out.iosVersion = ios;
    if (product == "iPod1,1" || product == "iPhone1,1" || product == "iPhone1,2" || product == "iPod2,1") {
        out.arch = "armv6";
    } else if (product == "iPhone5,2" || product == "iPhone5,1") {
        out.arch = "armv7s";
    } else {
        out.arch = "armv7";
    }
    out.family = (product.rfind("iPad", 0) == 0) ? "2" : "1";
    return true;
}

// ---------- Minimal ZIP / Preflight (ported from lighttouch-catalog/src/ipa.rs) ----------
static constexpr uint64_t kMaxIpaBytes = 2ULL << 30;
static constexpr uint64_t kMaxUnpackedBytes = 8ULL << 30;

struct ZipEntry {
    std::string name;
    uint16_t method = 0;
    uint16_t flags = 0;
    uint64_t compressed = 0;
    uint64_t size = 0;
    uint64_t localOffset = 0;
    uint32_t externalAttr = 0;
    uint64_t centralOffset = 0;

    uint32_t mode() const { return externalAttr >> 16; }
    bool isSymlink() const { return (mode() & 0xF000) == 0xA000; }
};

static bool readFileAt(FILE *f, uint64_t offset, void *dst, size_t len) {
    if (fseeko(f, off_t(offset), SEEK_SET) != 0) return false;
    return fread(dst, 1, len, f) == len;
}

static bool openZip(const char *path, FILE **outFile, std::vector<ZipEntry> &entries, NSError **error) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        if (error) *error = makeIpaError(1, @"IPAファイルを開けませんでした。");
        return false;
    }
    if (fseeko(f, 0, SEEK_END) != 0) {
        fclose(f);
        if (error) *error = makeIpaError(1, @"IPAファイルのサイズ取得に失敗しました。");
        return false;
    }
    off_t fsz = ftello(f);
    if (fsz <= 22 || uint64_t(fsz) > kMaxIpaBytes) {
        fclose(f);
        if (error) *error = makeIpaError(2, @"2 GB 未満の有効な IPA ファイルを選択してください。");
        return false;
    }
    uint64_t length = uint64_t(fsz);
    size_t tailLen = size_t(std::min<uint64_t>(length, 65557));
    std::vector<uint8_t> tail(tailLen);
    if (!readFileAt(f, length - tailLen, tail.data(), tailLen)) {
        fclose(f);
        if (error) *error = makeIpaError(3, @"IPA ファイルが破損しているか不完全です。");
        return false;
    }

    ssize_t eocd = -1;
    for (ssize_t i = ssize_t(tailLen) - 22; i >= 0; --i) {
        if (le32(&tail[i]) == 0x06054b50u) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        fclose(f);
        if (error) *error = makeIpaError(4, @"このファイルは ZIP/IPA アーカイブではありません。");
        return false;
    }

    uint64_t count = le16(&tail[eocd + 10]);
    uint64_t cdSize = le32(&tail[eocd + 12]);
    uint64_t cdOffset = le32(&tail[eocd + 16]);
    if (count == 0xffff || cdOffset == 0xffffffffu || cdSize == 0xffffffffu) {
        if (eocd < 20 || le32(&tail[eocd - 20]) != 0x07064b50u) {
            fclose(f);
            if (error) *error = makeIpaError(5, @"ZIP64 ディレクトリ情報が破損しています。");
            return false;
        }
        uint8_t record[56];
        if (!readFileAt(f, le64(&tail[eocd - 12]), record, sizeof(record)) || le32(record) != 0x06064b50u) {
            fclose(f);
            if (error) *error = makeIpaError(5, @"ZIP64 レコードが破損しています。");
            return false;
        }
        count = le64(&record[32]);
        cdSize = le64(&record[40]);
        cdOffset = le64(&record[48]);
    }
    if (count > 100000 || cdSize > (64ULL << 20) || cdOffset + cdSize > length) {
        fclose(f);
        if (error) *error = makeIpaError(6, @"IPA のディレクトリ情報が大きすぎるか破損しています。");
        return false;
    }

    std::vector<uint8_t> cd(cdSize);
    if (!readFileAt(f, cdOffset, cd.data(), size_t(cdSize))) {
        fclose(f);
        if (error) *error = makeIpaError(6, @"IPA ディレクトリの読み込みに失敗しました。");
        return false;
    }

    entries.reserve(size_t(count));
    size_t at = 0;
    for (uint64_t idx = 0; idx < count; idx++) {
        if (at + 46 > cd.size() || le32(&cd[at]) != 0x02014b50u) {
            fclose(f);
            if (error) *error = makeIpaError(7, @"IPA のセントラルディレクトリが破損しています。");
            return false;
        }
        size_t nameLen = le16(&cd[at + 28]);
        size_t extraLen = le16(&cd[at + 30]);
        size_t commentLen = le16(&cd[at + 32]);
        if (at + 46 + nameLen + extraLen + commentLen > cd.size()) {
            fclose(f);
            if (error) *error = makeIpaError(7, @"IPA のセントラルディレクトリが破損しています。");
            return false;
        }
        uint64_t comp = le32(&cd[at + 20]);
        uint64_t uncomp = le32(&cd[at + 24]);
        uint64_t local = le32(&cd[at + 42]);
        size_t extra = at + 46 + nameLen;
        size_t extraEnd = extra + extraLen;
        while (extra + 4 <= extraEnd) {
            uint16_t hid = le16(&cd[extra]);
            uint16_t hlen = le16(&cd[extra + 2]);
            if (hid == 1) {
                size_t p = extra + 4;
                if (uncomp == 0xffffffffu && p + 8 <= extraEnd) { uncomp = le64(&cd[p]); p += 8; }
                if (comp == 0xffffffffu && p + 8 <= extraEnd) { comp = le64(&cd[p]); p += 8; }
                if (local == 0xffffffffu && p + 8 <= extraEnd) { local = le64(&cd[p]); }
            }
            extra += 4 + hlen;
        }

        ZipEntry ze;
        ze.name.assign(reinterpret_cast<const char *>(&cd[at + 46]), nameLen);
        ze.method = le16(&cd[at + 10]);
        ze.flags = le16(&cd[at + 8]);
        ze.compressed = comp;
        ze.size = uncomp;
        ze.localOffset = local;
        ze.externalAttr = le32(&cd[at + 38]);
        ze.centralOffset = cdOffset + at;
        entries.push_back(std::move(ze));
        at = extraEnd + commentLen;
    }

    *outFile = f;
    return true;
}

static bool readZipEntry(FILE *f, const ZipEntry &entry, uint64_t limit,
                         std::vector<uint8_t> &out, NSError **error) {
    if (entry.size > limit || (entry.flags & 1) != 0 || entry.compressed > limit * 2 + 4096) {
        if (error) *error = makeIpaError(8, [NSString stringWithFormat:@"非対応または大きすぎるエントリです: %s", entry.name.c_str()]);
        return false;
    }
    uint8_t hdr[30];
    if (!readFileAt(f, entry.localOffset, hdr, sizeof(hdr)) || le32(hdr) != 0x04034b50u) {
        if (error) *error = makeIpaError(9, @"IPA 内のエントリヘッダが破損しています。");
        return false;
    }
    uint64_t skip = 30 + le16(&hdr[26]) + le16(&hdr[28]);
    std::vector<uint8_t> raw(size_t(entry.compressed));
    if (entry.compressed > 0 && !readFileAt(f, entry.localOffset + skip, raw.data(), raw.size())) {
        if (error) *error = makeIpaError(9, @"IPA エントリの読み込みに失敗しました。");
        return false;
    }
    if (entry.method == 0) {
        out = std::move(raw);
        return out.size() == entry.size;
    }
    if (entry.method == 8) {
        out.resize(size_t(entry.size));
        z_stream zs{};
        if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) {
            if (error) *error = makeIpaError(10, @"zlib の初期化に失敗しました。");
            return false;
        }
        zs.next_in = raw.data();
        zs.avail_in = uInt(raw.size());
        zs.next_out = out.data();
        zs.avail_out = uInt(out.size());
        int zrc = inflate(&zs, Z_FINISH);
        uLong got = zs.total_out;
        inflateEnd(&zs);
        if ((zrc != Z_STREAM_END && zrc != Z_OK) || got != entry.size) {
            if (error) *error = makeIpaError(10, @"IPA 内のデータ展開に失敗しました（ファイルが破損している可能性があります）。");
            return false;
        }
        return true;
    }
    if (error) *error = makeIpaError(11, @"IPA が未対応の圧縮方式を使用しています。");
    return false;
}

struct ArmSliceInfo {
    uint32_t subtype = 0;
    bool hasMinimum = false;
    std::array<uint32_t, 3> minimum{0, 0, 0};
};

static bool parseArmSlice(const uint8_t *data, size_t len, ArmSliceInfo &out, NSError **error) {
    if (len < 28 || le32(data) != 0xFEEDFACEu) {
        if (error) *error = makeIpaError(20, @"未対応の実行ファイル形式です（32bit ARM Mach-O が必要です）。");
        return false;
    }
    uint32_t cpu = le32(data + 4);
    uint32_t subtype = le32(data + 8) & 0x00FFFFFFu;
    uint32_t filetype = le32(data + 12);
    uint32_t ncmds = le32(data + 16);
    uint32_t sizeofcmds = le32(data + 20);
    if (cpu != 12 || filetype != 2 || ncmds > 65536 || 28 + sizeofcmds > len) {
        if (error) *error = makeIpaError(21, @"対応する 32bit ARM 実行バイナリが含まれていません。");
        return false;
    }

    size_t cursor = 28;
    out.subtype = subtype;
    out.hasMinimum = false;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (cursor + 8 > 28 + sizeofcmds) {
            if (error) *error = makeIpaError(22, @"Mach-O ロードコマンドが破損しています。");
            return false;
        }
        uint32_t cmd = le32(data + cursor);
        uint32_t cmdsize = le32(data + cursor + 4);
        if (cmdsize < 8 || cursor + cmdsize > 28 + sizeofcmds) {
            if (error) *error = makeIpaError(22, @"Mach-O ロードコマンドが破損しています。");
            return false;
        }
        if (cmd == 0x21 && (cmdsize < 20 || le32(data + cursor + 16) != 0)) {
            if (error) *error = makeIpaError(23, @"このアプリは FairPlay 暗号化されています。復号済みの IPA（cryptid = 0）を使用してください。");
            return false;
        }
        bool havePacked = false;
        uint32_t packed = 0;
        if (cmd == 0x25 && cmdsize >= 12) {
            havePacked = true;
            packed = le32(data + cursor + 8);
        } else if (cmd == 0x32 && cmdsize >= 16) {
            if (le32(data + cursor + 8) != 2) {
                if (error) *error = makeIpaError(24, @"実行ファイルが iOS 以外のプラットフォーム向けです。");
                return false;
            }
            havePacked = true;
            packed = le32(data + cursor + 12);
        }
        if (havePacked) {
            std::array<uint32_t, 3> v{packed >> 16, (packed >> 8) & 255, packed & 255};
            if (!out.hasMinimum || v > out.minimum) {
                out.hasMinimum = true;
                out.minimum = v;
            }
        }
        cursor += cmdsize;
    }
    return true;
}

static bool inspectArmSlices(const std::vector<uint8_t> &exeData,
                             std::vector<ArmSliceInfo> &slices,
                             NSError **error) {
    if (exeData.size() < 28) {
        if (error) *error = makeIpaError(20, @"アプリの実行ファイルが途中で切れています。");
        return false;
    }
    if (be32(exeData.data()) == 0xCAFEBABEu) {
        uint32_t count = be32(exeData.data() + 4);
        if (count == 0 || count > 32 || exeData.size() < 8 + size_t(count) * 20) {
            if (error) *error = makeIpaError(20, @"Universal Mach-O ヘッダが不正です。");
            return false;
        }
        for (uint32_t i = 0; i < count; i++) {
            uint32_t cpu = be32(exeData.data() + 8 + i * 20);
            uint32_t off = be32(exeData.data() + 16 + i * 20);
            uint32_t sz = be32(exeData.data() + 20 + i * 20);
            if (off < 8 + count * 20 || sz < 28 || uint64_t(off) + sz > exeData.size()) {
                if (error) *error = makeIpaError(20, @"Universal Mach-O スライスが不正です。");
                return false;
            }
            if (cpu == 12) {
                ArmSliceInfo sl;
                if (!parseArmSlice(exeData.data() + off, sz, sl, error)) return false;
                slices.push_back(sl);
            }
        }
        if (slices.empty()) {
            if (error) *error = makeIpaError(21, @"この IPA には対応する 32bit ARM スライスが含まれていません。");
            return false;
        }
        return true;
    }
    ArmSliceInfo sl;
    if (!parseArmSlice(exeData.data(), exeData.size(), sl, error)) return false;
    slices.push_back(sl);
    return true;
}

static IOSIpaInfo *prepareIpaFile(NSString *sourcePath,
                                  NSString *destPath,
                                  const GuestTarget &target,
                                  NSError **error) {
    FILE *zipFile = nullptr;
    std::vector<ZipEntry> entries;
    if (!openZip(sourcePath.fileSystemRepresentation, &zipFile, entries, error)) {
        return nil;
    }
    std::unique_ptr<FILE, decltype(&fclose)> zipGuard(zipFile, fclose);

    uint64_t unpackedTotal = 0;
    for (const auto &e : entries) unpackedTotal += e.size;
    if (unpackedTotal > kMaxUnpackedBytes) {
        if (error) *error = makeIpaError(30, @"展開後サイズが上限（8 GB）を超えています。");
        return nil;
    }

    std::set<std::string> seenNames;
    ssize_t infoIndex = -1;
    int infoCandidates = 0;
    for (size_t i = 0; i < entries.size(); i++) {
        const auto &e = entries[i];
        if (!seenNames.insert(e.name).second ||
            e.name.empty() || e.name[0] == '/' ||
            e.name.find('\\') != std::string::npos ||
            (e.flags & 1) != 0) {
            if (error) *error = makeIpaError(31, @"IPA に重複・不正パス・暗号化エントリが含まれています。");
            return nil;
        }
        // Check path components for '..' and match Payload/<App>.app/Info.plist
        std::vector<std::string> parts;
        size_t pos = 0;
        while (pos <= e.name.size()) {
            size_t slash = e.name.find('/', pos);
            std::string comp = (slash == std::string::npos) ? e.name.substr(pos) : e.name.substr(pos, slash - pos);
            if (comp == "..") {
                if (error) *error = makeIpaError(31, @"IPA に不正な相対パス（..）が含まれています。");
                return nil;
            }
            parts.push_back(comp);
            if (slash == std::string::npos) break;
            pos = slash + 1;
        }
        if (parts.size() == 3 && parts[0] == "Payload" &&
            parts[1].size() > 4 && parts[1].compare(parts[1].size() - 4, 4, ".app") == 0 &&
            parts[2] == "Info.plist") {
            infoIndex = ssize_t(i);
            infoCandidates++;
        }
        if (e.isSymlink()) {
            std::vector<uint8_t> linkBytes;
            if (!readZipEntry(zipFile, e, 4096, linkBytes, error)) return nil;
            std::string link(linkBytes.begin(), linkBytes.end());
            if (link.empty() || link[0] == '/' || link.find('\\') != std::string::npos ||
                link.find('\0') != std::string::npos || parts.size() < 3 ||
                parts[0] != "Payload" || parts[1].size() <= 4 ||
                parts[1].compare(parts[1].size() - 4, 4, ".app") != 0) {
                if (error) *error = makeIpaError(31, @"IPA に安全でないシンボリックリンクが含まれています。");
                return nil;
            }
            std::vector<std::string> resolved(parts.begin(), parts.end() - 1);
            size_t lp = 0;
            while (lp <= link.size()) {
                size_t sl = link.find('/', lp);
                std::string comp = (sl == std::string::npos) ? link.substr(lp) : link.substr(lp, sl - lp);
                if (comp == "..") {
                    if (resolved.size() <= 2) {
                        if (error) *error = makeIpaError(31, @"IPA 内のシンボリックリンクが .app 外を指しています。");
                        return nil;
                    }
                    resolved.pop_back();
                } else if (!comp.empty() && comp != ".") {
                    resolved.push_back(comp);
                }
                if (sl == std::string::npos) break;
                lp = sl + 1;
            }
        }
    }

    if (infoCandidates != 1 || infoIndex < 0) {
        if (error) *error = makeIpaError(32, @"Payload/*.app/Info.plist が 1 つだけ含まれる IPA を選択してください。");
        return nil;
    }

    std::vector<uint8_t> infoBytes;
    if (!readZipEntry(zipFile, entries[size_t(infoIndex)], 1ULL << 20, infoBytes, error)) return nil;
    NSData *infoNSData = [NSData dataWithBytesNoCopy:infoBytes.data() length:infoBytes.size() freeWhenDone:NO];
    id plistObj = [NSPropertyListSerialization propertyListWithData:infoNSData options:NSPropertyListImmutable format:NULL error:nil];
    if (![plistObj isKindOfClass:[NSDictionary class]]) {
        if (error) *error = makeIpaError(33, @"Info.plist を解析できませんでした。");
        return nil;
    }
    NSDictionary *infoDict = (NSDictionary *)plistObj;
    NSString *bundleId = [infoDict[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleIdentifier"] : nil;
    NSString *exeName = [infoDict[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleExecutable"] : nil;
    if (!bundleId.length || !exeName.length || [exeName containsString:@"/"] ||
        [exeName isEqualToString:@"."] || [exeName isEqualToString:@".."]) {
        if (error) *error = makeIpaError(34, @"Info.plist のバンドル ID または実行ファイル名が不正です。");
        return nil;
    }

    const std::string &infoPath = entries[size_t(infoIndex)].name;
    std::string appDir = infoPath.substr(0, infoPath.rfind('/'));
    std::string exePath = appDir + "/" + exeName.UTF8String;
    ssize_t exeIndex = -1;
    for (size_t i = 0; i < entries.size(); i++) {
        if (entries[i].name == exePath) {
            exeIndex = ssize_t(i);
            break;
        }
    }
    if (exeIndex < 0 || entries[size_t(exeIndex)].isSymlink()) {
        if (error) *error = makeIpaError(35, @"アプリ内の実行ファイルが見つかりません。");
        return nil;
    }

    std::vector<uint8_t> exeData;
    if (!readZipEntry(zipFile, entries[size_t(exeIndex)], 256ULL << 20, exeData, error)) return nil;
    std::vector<ArmSliceInfo> slices;
    if (!inspectArmSlices(exeData, slices, error)) return nil;

    uint32_t bestSubtype = 0;
    bool foundCompatSlice = false;
    for (const auto &sl : slices) {
        bool sup = false;
        if (target.arch == "armv6") {
            sup = (sl.subtype == 0 || sl.subtype == 6);
        } else if (target.arch == "armv7s") {
            sup = (sl.subtype == 0 || sl.subtype == 6 || sl.subtype == 9 || sl.subtype == 11);
        } else {
            sup = (sl.subtype == 0 || sl.subtype == 6 || sl.subtype == 9);
        }
        if (sup && (!foundCompatSlice || sl.subtype >= bestSubtype)) {
            bestSubtype = sl.subtype;
            foundCompatSlice = true;
        }
    }
    if (!foundCompatSlice) {
        if (error) *error = makeIpaError(36, [NSString stringWithFormat:@"このアプリは現在の仮想デバイス（%s）より新しい CPU を必要としています。", target.arch.c_str()]);
        return nil;
    }
    for (const auto &sl : slices) {
        if (sl.subtype == bestSubtype && sl.hasMinimum && sl.minimum > target.iosParts) {
            if (error) {
                *error = makeIpaError(37, [NSString stringWithFormat:@"このアプリの実行ファイルには iOS %u.%u.%u 以降が必要です（現在 %s）。",
                                           sl.minimum[0], sl.minimum[1], sl.minimum[2], target.iosVersion.c_str()]);
            }
            return nil;
        }
    }

    NSString *minOS = [infoDict[@"MinimumOSVersion"] isKindOfClass:[NSString class]] ? infoDict[@"MinimumOSVersion"] : nil;
    if (minOS.length > 0) {
        std::array<uint32_t, 3> req{};
        if (!parseVersion(minOS.UTF8String, req) || req > target.iosParts) {
            if (error) {
                *error = makeIpaError(38, [NSString stringWithFormat:@"このアプリは iOS %@ 以降が必要です（現在 %s）。", minOS, target.iosVersion.c_str()]);
            }
            return nil;
        }
    }

    id familiesObj = infoDict[@"UIDeviceFamily"];
    if ([familiesObj isKindOfClass:[NSArray class]] && [(NSArray *)familiesObj count] > 0) {
        bool familyOk = false;
        NSString *want = [NSString stringWithUTF8String:target.family.c_str()];
        for (id f in (NSArray *)familiesObj) {
            NSString *fs = [f isKindOfClass:[NSNumber class]] ? [(NSNumber *)f stringValue] : ([f isKindOfClass:[NSString class]] ? f : @"");
            if ([fs isEqualToString:want]) {
                familyOk = true;
                break;
            }
        }
        if (!familyOk) {
            if (error) *error = makeIpaError(39, @"このアプリは現在のデバイス種別（iPhone/iPad）向けではありません。");
            return nil;
        }
    }

    const ZipEntry &exeEntry = entries[size_t(exeIndex)];
    uint32_t exeMode = exeEntry.mode();
    uint64_t exeCentral = exeEntry.centralOffset;
    uint32_t exeExtAttr = exeEntry.externalAttr;
    zipGuard.reset(); // Close source before copying

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:destPath error:nil];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:sourcePath toPath:destPath error:&copyErr]) {
        if (error) *error = makeIpaError(40, copyErr.localizedDescription ?: @"IPA の一時コピーに失敗しました。");
        return nil;
    }

    if ((exeMode & 0111) == 0) {
        FILE *outF = fopen(destPath.fileSystemRepresentation, "r+b");
        if (!outF) {
            if (error) *error = makeIpaError(41, @"IPA の実行権限修復を開けませんでした。");
            return nil;
        }
        uint8_t hostByte = 3; // Unix
        uint32_t patchedAttr = (0100755u << 16) | (exeExtAttr & 0xFFFFu);
        uint8_t attrBytes[4] = {
            uint8_t(patchedAttr & 0xff),
            uint8_t((patchedAttr >> 8) & 0xff),
            uint8_t((patchedAttr >> 16) & 0xff),
            uint8_t((patchedAttr >> 24) & 0xff),
        };
        bool ok = (fseeko(outF, off_t(exeCentral + 5), SEEK_SET) == 0 && fwrite(&hostByte, 1, 1, outF) == 1 &&
                   fseeko(outF, off_t(exeCentral + 38), SEEK_SET) == 0 && fwrite(attrBytes, 1, 4, outF) == 4 &&
                   fflush(outF) == 0);
        fclose(outF);
        if (!ok) {
            if (error) *error = makeIpaError(41, @"IPA の実行権限修復に失敗しました。");
            return nil;
        }
    }

    NSDictionary *attrs = [fm attributesOfItemAtPath:destPath error:nil];
    NSString *dispName = [infoDict[@"CFBundleDisplayName"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleDisplayName"] : nil;
    if (!dispName.length) dispName = [infoDict[@"CFBundleName"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleName"] : bundleId;

    IOSIpaInfo *res = [[IOSIpaInfo alloc] init];
    res.bundleId = bundleId;
    res.name = dispName;
    res.version = [infoDict[@"CFBundleVersion"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleVersion"] : nil;
    res.shortVersion = [infoDict[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleShortVersionString"] : nil;
    res.minimumOS = minOS;
    res.ipaBytes = [attrs[NSFileSize] unsignedLongLongValue];
    res.unpackedBytes = unpackedTotal;
    return res;
}

// ---------- OpenSSL / Lockdown Stream ----------
class GuestConn {
public:
    int fd = -1;
    SSL *ssl = nullptr;

    GuestConn() = default;
    explicit GuestConn(int f) : fd(f) {
#ifdef SO_NOSIGPIPE
        if (fd >= 0) {
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        }
#endif
    }
    ~GuestConn() { closeConn(); }
    GuestConn(const GuestConn &) = delete;
    GuestConn &operator=(const GuestConn &) = delete;
    GuestConn(GuestConn &&o) noexcept : fd(o.fd), ssl(o.ssl) { o.fd = -1; o.ssl = nullptr; }
    GuestConn &operator=(GuestConn &&o) noexcept {
        if (this != &o) { closeConn(); fd = o.fd; ssl = o.ssl; o.fd = -1; o.ssl = nullptr; }
        return *this;
    }

    void closeConn() {
        if (ssl) { SSL_shutdown(ssl); SSL_free(ssl); ssl = nullptr; }
        if (fd >= 0) { close(fd); fd = -1; }
    }

    bool writeAll(const void *buf, size_t len) {
        const uint8_t *p = static_cast<const uint8_t *>(buf);
        size_t done = 0;
        while (done < len) {
            int n = ssl ? SSL_write(ssl, p + done, int(len - done))
                        : int(send(fd, p + done, len - done, 0));
            if (n > 0) done += size_t(n);
            else if (!ssl && n < 0 && errno == EINTR) continue;
            else return false;
        }
        return true;
    }

    bool readExact(void *buf, size_t len) {
        uint8_t *p = static_cast<uint8_t *>(buf);
        size_t done = 0;
        while (done < len) {
            int n = ssl ? SSL_read(ssl, p + done, int(len - done))
                        : int(recv(fd, p + done, len - done, 0));
            if (n > 0) done += size_t(n);
            else if (!ssl && n < 0 && errno == EINTR) continue;
            else return false;
        }
        return true;
    }

    bool sendPlist(NSDictionary *dict, NSError **error) {
        NSData *xml = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
        if (!xml) return false;
        uint32_t lenBe = htonl(uint32_t(xml.length));
        std::vector<uint8_t> frame(4 + xml.length);
        memcpy(frame.data(), &lenBe, 4);
        memcpy(frame.data() + 4, xml.bytes, xml.length);
        if (!writeAll(frame.data(), frame.size())) {
            if (error) *error = makeIpaError(50, @"仮想デバイスへのコマンド送信に失敗しました。");
            return false;
        }
        return true;
    }

    NSDictionary *receivePlist(NSError **error) {
        uint32_t lenBe = 0;
        if (!readExact(&lenBe, 4)) {
            if (error) *error = makeIpaError(51, @"仮想デバイスからの応答受信に失敗しました。");
            return nil;
        }
        uint32_t len = ntohl(lenBe);
        if (len == 0 || len > (32u << 20)) {
            if (error) *error = makeIpaError(51, @"仮想デバイスから不正な応答サイズを受信しました。");
            return nil;
        }
        std::vector<uint8_t> body(len);
        if (!readExact(body.data(), len)) {
            if (error) *error = makeIpaError(51, @"仮想デバイスからの応答データが途中で切れました。");
            return nil;
        }
        NSData *nsd = [NSData dataWithBytesNoCopy:body.data() length:body.size() freeWhenDone:NO];
        id obj = [NSPropertyListSerialization propertyListWithData:nsd options:NSPropertyListImmutable format:NULL error:error];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) *error = makeIpaError(51, @"仮想デバイスからの応答が辞書形式ではありません。");
            return nil;
        }
        return (NSDictionary *)obj;
    }

    bool upgradeToTLS(NSData *hostCertPem, NSData *hostKeyPem, uint32_t iosMajor, NSError **error) {
        SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
        if (!ctx) {
            if (error) *error = makeIpaError(52, @"TLS コンテキスト初期化に失敗しました。");
            return false;
        }
        std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> ctxGuard(ctx, SSL_CTX_free);
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nullptr);
        SSL_CTX_set_security_level(ctx, 0);
        SSL_CTX_set_min_proto_version(ctx, TLS1_VERSION);
        SSL_CTX_set_options(ctx, SSL_OP_LEGACY_SERVER_CONNECT);
        if (iosMajor < 10) {
            SSL_CTX_set_max_proto_version(ctx, TLS1_VERSION);
            SSL_CTX_set_cipher_list(ctx, "ALL:!aNULL:!eNULL:!kECDHE:@SECLEVEL=0");
        } else {
            SSL_CTX_set_cipher_list(ctx, "ALL:!aNULL:!eNULL:@SECLEVEL=0");
        }

        BIO *cbio = BIO_new_mem_buf(hostCertPem.bytes, int(hostCertPem.length));
        X509 *cert = cbio ? PEM_read_bio_X509(cbio, nullptr, nullptr, nullptr) : nullptr;
        if (cbio) BIO_free(cbio);
        BIO *kbio = BIO_new_mem_buf(hostKeyPem.bytes, int(hostKeyPem.length));
        EVP_PKEY *pkey = kbio ? PEM_read_bio_PrivateKey(kbio, nullptr, nullptr, nullptr) : nullptr;
        if (kbio) BIO_free(kbio);

        bool loaded = cert && pkey && SSL_CTX_use_certificate(ctx, cert) == 1 && SSL_CTX_use_PrivateKey(ctx, pkey) == 1;
        if (cert) X509_free(cert);
        if (pkey) EVP_PKEY_free(pkey);
        if (!loaded) {
            if (error) *error = makeIpaError(52, @"ペアリング証明書の読み込みに失敗しました。");
            return false;
        }

        SSL *s = SSL_new(ctx);
        if (!s || SSL_set_fd(s, fd) != 1 || SSL_connect(s) != 1) {
            if (s) SSL_free(s);
            if (error) *error = makeIpaError(52, @"仮想デバイスとの TLS セッション確立に失敗しました。");
            return false;
        }
        ssl = s;
        return true;
    }
};

// ---------- Pairing Generator (exact match to pairing.rs) ----------
using EvpKeyPtr = std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)>;
using X509Ptr = std::unique_ptr<X509, decltype(&X509_free)>;

static EvpKeyPtr generateRsa2048() {
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
    if (!ctx) return EvpKeyPtr(nullptr, EVP_PKEY_free);
    EVP_PKEY *pkey = nullptr;
    if (EVP_PKEY_keygen_init(ctx) <= 0 || EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 2048) <= 0 || EVP_PKEY_keygen(ctx, &pkey) <= 0) {
        EVP_PKEY_CTX_free(ctx);
        return EvpKeyPtr(nullptr, EVP_PKEY_free);
    }
    EVP_PKEY_CTX_free(ctx);
    return EvpKeyPtr(pkey, EVP_PKEY_free);
}

static NSData *x509ToPem(X509 *cert) {
    BIO *bio = BIO_new(BIO_s_mem());
    if (!bio) return nil;
    if (PEM_write_bio_X509(bio, cert) != 1) { BIO_free(bio); return nil; }
    BUF_MEM *mem = nullptr;
    BIO_get_mem_ptr(bio, &mem);
    NSData *d = mem && mem->data ? [NSData dataWithBytes:mem->data length:mem->length] : nil;
    BIO_free(bio);
    return d;
}

static NSData *pkeyToPem(EVP_PKEY *pkey) {
    BIO *bio = BIO_new(BIO_s_mem());
    if (!bio) return nil;
    if (PEM_write_bio_PrivateKey(bio, pkey, nullptr, nullptr, 0, nullptr, nullptr) != 1) { BIO_free(bio); return nil; }
    BUF_MEM *mem = nullptr;
    BIO_get_mem_ptr(bio, &mem);
    NSData *d = mem && mem->data ? [NSData dataWithBytes:mem->data length:mem->length] : nil;
    BIO_free(bio);
    return d;
}

static bool addX509Ext(X509 *cert, X509 *issuer, int nid, const char *val) {
    X509V3_CTX ctx{};
    X509V3_set_ctx(&ctx, issuer ? issuer : cert, cert, nullptr, nullptr, 0);
    X509_EXTENSION *ext = X509V3_EXT_conf_nid(nullptr, &ctx, nid, val);
    if (!ext) return false;
    int rc = X509_add_ext(cert, ext, -1);
    X509_EXTENSION_free(ext);
    return rc == 1;
}

static X509Ptr buildPairCert(EVP_PKEY *pubKey, EVP_PKEY *signer, int kind /* 0=root, 1=host, 2=device */, uint32_t iosMajor) {
    X509Ptr cert(X509_new(), X509_free);
    if (!cert) return X509Ptr(nullptr, X509_free);
    X509_set_version(cert.get(), 2);
    BIGNUM *bn = BN_new();
    BN_zero(bn);
    ASN1_INTEGER *ser = BN_to_ASN1_INTEGER(bn, nullptr);
    X509_set_serialNumber(cert.get(), ser);
    ASN1_INTEGER_free(ser);
    BN_free(bn);

    X509_gmtime_adj(X509_getm_notBefore(cert.get()), 0);
    X509_gmtime_adj(X509_getm_notAfter(cert.get()), 3650L * 86400L);
    X509_set_pubkey(cert.get(), pubKey);

    bool ok = true;
    if (kind == 0) {
        ok = ok && addX509Ext(cert.get(), cert.get(), NID_basic_constraints, "critical,CA:TRUE");
    } else if (kind == 1) {
        ok = ok && addX509Ext(cert.get(), nullptr, NID_basic_constraints, "critical,CA:FALSE");
        ok = ok && addX509Ext(cert.get(), nullptr, NID_key_usage, "critical,digitalSignature,keyEncipherment");
    } else {
        ok = ok && addX509Ext(cert.get(), nullptr, NID_basic_constraints, "critical,CA:FALSE");
        ok = ok && addX509Ext(cert.get(), nullptr, NID_subject_key_identifier, "hash");
        ok = ok && addX509Ext(cert.get(), nullptr, NID_key_usage, "critical,digitalSignature,keyEncipherment");
    }
    const EVP_MD *md = (iosMajor < 4) ? EVP_sha1() : EVP_sha256();
    ok = ok && X509_sign(cert.get(), signer, md) > 0;
    if (!ok) return X509Ptr(nullptr, X509_free);
    return cert;
}

static NSDictionary *generatePairRecord(NSData *devicePubKeyPem, NSString *hostId, NSString *systemBuid, uint32_t iosMajor, NSError **error) {
    EvpKeyPtr rootKey = generateRsa2048();
    EvpKeyPtr hostKey = generateRsa2048();
    if (!rootKey || !hostKey) {
        if (error) *error = makeIpaError(53, @"ペアリング用 RSA 鍵の生成に失敗しました。");
        return nil;
    }
    BIO *dbio = BIO_new_mem_buf(devicePubKeyPem.bytes, int(devicePubKeyPem.length));
    EVP_PKEY *rawDev = dbio ? PEM_read_bio_PUBKEY(dbio, nullptr, nullptr, nullptr) : nullptr;
    if (!rawDev && dbio) {
        BIO_reset(dbio);
        RSA *rsa = PEM_read_bio_RSAPublicKey(dbio, nullptr, nullptr, nullptr);
        if (rsa) {
            rawDev = EVP_PKEY_new();
            if (!rawDev || EVP_PKEY_assign_RSA(rawDev, rsa) != 1) {
                RSA_free(rsa);
                if (rawDev) EVP_PKEY_free(rawDev);
                rawDev = nullptr;
            }
        }
    }
    if (dbio) BIO_free(dbio);
    EvpKeyPtr devKey(rawDev, EVP_PKEY_free);
    if (!devKey) {
        if (error) *error = makeIpaError(53, @"デバイスの公開鍵を読み込めませんでした。");
        return nil;
    }

    X509Ptr rootCert = buildPairCert(rootKey.get(), rootKey.get(), 0, iosMajor);
    X509Ptr hostCert = buildPairCert(hostKey.get(), rootKey.get(), 1, iosMajor);
    X509Ptr devCert = buildPairCert(devKey.get(), rootKey.get(), 2, iosMajor);
    NSData *rootPem = rootCert ? x509ToPem(rootCert.get()) : nil;
    NSData *hostPem = hostCert ? x509ToPem(hostCert.get()) : nil;
    NSData *devPem = devCert ? x509ToPem(devCert.get()) : nil;
    NSData *rootKeyPem = pkeyToPem(rootKey.get());
    NSData *hostKeyPem = pkeyToPem(hostKey.get());
    if (!rootPem || !hostPem || !devPem || !rootKeyPem || !hostKeyPem) {
        if (error) *error = makeIpaError(53, @"ペアリング証明書の生成に失敗しました。");
        return nil;
    }

    return @{
        @"DeviceCertificate": devPem,
        @"HostCertificate": hostPem,
        @"HostPrivateKey": hostKeyPem,
        @"RootCertificate": rootPem,
        @"RootPrivateKey": rootKeyPem,
        @"HostID": hostId,
        @"SystemBUID": systemBuid,
    };
}

// ---------- Lockdown Client ----------
static NSDictionary *lockdownRequest(GuestConn &conn, NSString *req, NSDictionary *extra, NSString * __strong *outErrName, NSError **error) {
    if (outErrName) *outErrName = nil;
    NSMutableDictionary *msg = [NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
    msg[@"Label"] = @"LightTouch";
    msg[@"Request"] = req;
    if (!conn.sendPlist(msg, error)) return nil;
    NSDictionary *reply = conn.receivePlist(error);
    if (!reply) return nil;
    NSString *errStr = [reply[@"Error"] isKindOfClass:[NSString class]] ? reply[@"Error"] : nil;
    if (errStr.length > 0) {
        if (outErrName) *outErrName = errStr;
        if (error) {
            NSString *friendly = [errStr containsString:@"PairingDialogResponsePending"]
                ? @"仮想 iPhone 画面に表示された「このコンピュータを信頼しますか？」で「信頼」をタップしてからもう一度お試しください。"
                : [NSString stringWithFormat:@"%@ 失敗: %@", req, errStr];
            *error = makeIpaError(54, friendly);
        }
        return nil;
    }
    return reply;
}

static bool openLockdownSession(IOSUsbMuxBridge *bridge,
                                NSString *pairingFilePath,
                                GuestConn &outConn,
                                NSDictionary * __strong *outPairRecord,
                                GuestTarget &outTarget,
                                BOOL (^ _Nullable waitTrustBlock)(void),
                                NSError **error) {
    for (int outerAttempt = 0; outerAttempt < 2; outerAttempt++) {
        int fd = [bridge connectToGuestPort:62078 timeout:15.0 error:error];
        if (fd < 0) return false;
        GuestConn conn(fd);

        NSDictionary *q = lockdownRequest(conn, @"QueryType", nil, nil, error);
        if (!q || ![q[@"Type"] isEqual:@"com.apple.mobile.lockdown"]) {
            if (error && !*error) *error = makeIpaError(55, @"lockdownd の応答が不正です。");
            return false;
        }

        // Pre-session lockdownd (especially iOS 6 and earlier) returns GetProhibited for keys like ProductType
        // until after Pair + StartSession. Only ProductVersion is probed optionally here as a TLS/cert hint.
        std::array<uint32_t, 3> preParts{0, 0, 0};
        NSDictionary *verPre = lockdownRequest(conn, @"GetValue", @{@"Key": @"ProductVersion"}, nil, nil);
        NSString *preVerStr = [verPre[@"Value"] isKindOfClass:[NSString class]] ? verPre[@"Value"] : nil;
        if (preVerStr.length > 0) {
            parseVersion(preVerStr.UTF8String, preParts);
        }
        uint32_t preIosMajor = preParts[0];

        NSDictionary *pairRecord = nil;
        NSData *savedData = [NSData dataWithContentsOfFile:pairingFilePath];
        if (savedData.length > 0) {
            id parsed = [NSPropertyListSerialization propertyListWithData:savedData options:NSPropertyListImmutable format:NULL error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) pairRecord = (NSDictionary *)parsed;
        }

        if (!pairRecord) {
            NSDictionary *pkR = lockdownRequest(conn, @"GetValue", @{@"Key": @"DevicePublicKey"}, nil, error);
            NSData *devPub = [pkR[@"Value"] isKindOfClass:[NSData class]] ? pkR[@"Value"] : nil;
            if (!devPub.length) {
                if (error && !*error) *error = makeIpaError(56, @"デバイスの公開鍵を取得できませんでした。");
                return false;
            }
            NSDictionary *wifiR = lockdownRequest(conn, @"GetValue", @{@"Key": @"WiFiAddress"}, nil, nil);
            NSString *wifi = [wifiR[@"Value"] isKindOfClass:[NSString class]] ? wifiR[@"Value"] : nil;

            NSString *hostId = [[[NSUUID UUID] UUIDString] uppercaseString];
            NSString *sysBuid = [[[NSUUID UUID] UUIDString] uppercaseString];
            NSDictionary *generated = generatePairRecord(devPub, hostId, sysBuid, preIosMajor, error);
            if (!generated) return false;

            NSDictionary *wirePair = @{
                @"DeviceCertificate": generated[@"DeviceCertificate"],
                @"HostCertificate": generated[@"HostCertificate"],
                @"HostID": generated[@"HostID"],
                @"RootCertificate": generated[@"RootCertificate"],
                @"SystemBUID": generated[@"SystemBUID"],
            };

            NSDictionary *pairReply = nil;
            for (int trustWait = 0; trustWait < 45; trustWait++) {
                NSString *errName = nil;
                NSError *pairErr = nil;
                pairReply = lockdownRequest(conn, @"Pair", @{
                    @"PairRecord": wirePair,
                    @"ProtocolVersion": @"2",
                    @"PairingOptions": @{@"ExtendedPairingErrors": @YES},
                }, &errName, &pairErr);
                if (pairReply) break;
                if ([errName containsString:@"PairingDialogResponsePending"]) {
                    if (waitTrustBlock && !waitTrustBlock()) {
                        if (error) *error = makeIpaError(102, @"キャンセルされました。");
                        return false;
                    }
                    sleep(1);
                    continue;
                }
                if (error) *error = pairErr;
                return false;
            }
            if (!pairReply) {
                if (error) {
                    *error = makeIpaError(54, @"仮想 iPhone 画面の「このコンピュータを信頼しますか？」で「信頼」をタップしてからもう一度お試しください。");
                }
                return false;
            }

            NSMutableDictionary *full = [generated mutableCopy];
            if (pairReply[@"EscrowBag"]) full[@"EscrowBag"] = pairReply[@"EscrowBag"];
            if (wifi.length > 0) full[@"WiFiMACAddress"] = wifi;
            NSData *bin = [NSPropertyListSerialization dataWithPropertyList:full format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
            if (bin) [bin writeToFile:pairingFilePath atomically:YES];
            pairRecord = full;
        }

        if (preIosMajor < 7) {
            NSDictionary *wirePair = @{
                @"DeviceCertificate": pairRecord[@"DeviceCertificate"],
                @"HostCertificate": pairRecord[@"HostCertificate"],
                @"HostID": pairRecord[@"HostID"],
                @"RootCertificate": pairRecord[@"RootCertificate"],
                @"SystemBUID": pairRecord[@"SystemBUID"],
            };
            if (!lockdownRequest(conn, @"ValidatePair", @{@"PairRecord": wirePair, @"ProtocolVersion": @"2"}, nil, error)) {
                [[NSFileManager defaultManager] removeItemAtPath:pairingFilePath error:nil];
                if (outerAttempt == 0) continue;
                return false;
            }
        }

        NSString *sessErrName = nil;
        NSDictionary *sess = lockdownRequest(conn, @"StartSession", @{
            @"HostID": pairRecord[@"HostID"],
            @"SystemBUID": pairRecord[@"SystemBUID"],
        }, &sessErrName, error);
        if (!sess) {
            if (outerAttempt == 0 && (savedData.length > 0 || [sessErrName containsString:@"InvalidHostID"])) {
                [[NSFileManager defaultManager] removeItemAtPath:pairingFilePath error:nil];
                continue;
            }
            return false;
        }
        if ([sess[@"EnableSessionSSL"] isKindOfClass:[NSNumber class]] && [sess[@"EnableSessionSSL"] boolValue]) {
            if (!conn.upgradeToTLS(pairRecord[@"HostCertificate"], pairRecord[@"HostPrivateKey"], preIosMajor, error)) {
                return false;
            }
        }

        // Now inside the authenticated Lockdown session: query ProductType & ProductVersion safely.
        NSDictionary *prodR = lockdownRequest(conn, @"GetValue", @{@"Key": @"ProductType"}, nil, error);
        if (!prodR) return false;
        NSDictionary *verR = preVerStr.length > 0 ? nil : lockdownRequest(conn, @"GetValue", @{@"Key": @"ProductVersion"}, nil, error);
        if (!preVerStr.length && !verR) return false;
        NSString *product = [prodR[@"Value"] isKindOfClass:[NSString class]] ? prodR[@"Value"] : nil;
        NSString *iosVer = preVerStr.length > 0 ? preVerStr : ([verR[@"Value"] isKindOfClass:[NSString class]] ? verR[@"Value"] : nil);
        if (!product.length || !iosVer.length || !targetFromGuest(product.UTF8String, iosVer.UTF8String, outTarget)) {
            if (error && !*error) *error = makeIpaError(55, @"ゲストデバイスの情報を取得できませんでした。iOS 起動後にお試しください。");
            return false;
        }

        outConn = std::move(conn);
        if (outPairRecord) *outPairRecord = pairRecord;
        return true;
    }
    return false;
}

static bool startLockdownService(IOSUsbMuxBridge *bridge,
                                 GuestConn &lockdown,
                                 NSDictionary * __strong &pairRecord,
                                 GuestTarget &target,
                                 NSString *pairingFilePath,
                                 NSString *serviceName,
                                 NSTimeInterval timeout,
                                 GuestConn &outServiceConn,
                                 NSError **error) {
    NSError *lastErr = nil;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
            usleep(useconds_t(500000 * attempt));
            GuestConn fresh;
            if (!openLockdownSession(bridge, pairingFilePath, fresh, &pairRecord, target, nil, &lastErr)) {
                continue;
            }
            lockdown = std::move(fresh);
        }
        NSDictionary *reply = lockdownRequest(lockdown, @"StartService", @{@"Service": serviceName}, nil, &lastErr);
        if (!reply) continue;
        NSNumber *portNum = [reply[@"Port"] isKindOfClass:[NSNumber class]] ? reply[@"Port"] : nil;
        uint16_t port = portNum ? uint16_t([portNum unsignedIntValue]) : 0;
        if (!port) {
            lastErr = makeIpaError(57, [NSString stringWithFormat:@"サービス %@ がポートを返しませんでした。", serviceName]);
            continue;
        }
        int sfd = [bridge connectToGuestPort:port timeout:timeout error:&lastErr];
        if (sfd < 0) continue;
        GuestConn svc(sfd);
        if ([reply[@"EnableServiceSSL"] isKindOfClass:[NSNumber class]] && [reply[@"EnableServiceSSL"] boolValue]) {
            if (!svc.upgradeToTLS(pairRecord[@"HostCertificate"], pairRecord[@"HostPrivateKey"], target.iosParts[0], &lastErr)) {
                continue;
            }
        }
        outServiceConn = std::move(svc);
        return true;
    }
    if (error) *error = lastErr ?: makeIpaError(57, [NSString stringWithFormat:@"%@ を起動できませんでした。", serviceName]);
    return false;
}

// ---------- AFC Client (exact match to afc.rs) ----------
class AfcClient {
public:
    GuestConn conn;
    uint64_t packet = 0;

    bool call(uint64_t op, const void *args, size_t argsLen, const void *payload, size_t payloadLen,
              uint64_t *outOp, std::vector<uint8_t> *outArgs, std::vector<uint8_t> *outPayload, NSError **error) {
        static const char kMagic[8] = {'C','F','A','6','L','P','A','A'};
        uint64_t thisLen = 40 + argsLen;
        uint64_t entireLen = thisLen + payloadLen;
        std::vector<uint8_t> hdr;
        hdr.reserve(40 + argsLen);
        hdr.insert(hdr.end(), kMagic, kMagic + 8);
        appendLe64(hdr, entireLen);
        appendLe64(hdr, thisLen);
        appendLe64(hdr, packet++);
        appendLe64(hdr, op);
        if (args && argsLen) hdr.insert(hdr.end(), static_cast<const uint8_t *>(args), static_cast<const uint8_t *>(args) + argsLen);
        if (!conn.writeAll(hdr.data(), hdr.size()) || (payloadLen > 0 && !conn.writeAll(payload, payloadLen))) {
            if (error) *error = makeIpaError(60, @"AFC データ送信に失敗しました。");
            return false;
        }

        uint8_t rhead[40];
        if (!conn.readExact(rhead, 40) || memcmp(rhead, kMagic, 8) != 0) {
            if (error) *error = makeIpaError(61, @"AFC からの応答ヘッダが不正です。");
            return false;
        }
        uint64_t rEntire = le64FromPtr(rhead + 8);
        uint64_t rThis = le64FromPtr(rhead + 16);
        uint64_t rOp = le64FromPtr(rhead + 32);
        if (rEntire < 40 || rThis < 40 || rThis > rEntire || rEntire > (64ULL << 20)) {
            if (error) *error = makeIpaError(61, @"AFC 応答サイズが不正です。");
            return false;
        }
        std::vector<uint8_t> rArgs(size_t(rThis - 40));
        std::vector<uint8_t> rPayload(size_t(rEntire - rThis));
        if (!rArgs.empty() && !conn.readExact(rArgs.data(), rArgs.size())) {
            if (error) *error = makeIpaError(61, @"AFC 引数データ受信に失敗しました。");
            return false;
        }
        if (!rPayload.empty() && !conn.readExact(rPayload.data(), rPayload.size())) {
            if (error) *error = makeIpaError(61, @"AFC ペイロード受信に失敗しました。");
            return false;
        }
        if (rOp == 0x01 /* OP_STATUS */) {
            uint64_t status = rArgs.size() >= 8 ? le64FromPtr(rArgs.data()) : 0;
            if (status != 0) {
                if (error) *error = makeIpaError(62, [NSString stringWithFormat:@"AFC エラー (コード %llu)", status]);
                return false;
            }
        }
        if (outOp) *outOp = rOp;
        if (outArgs) *outArgs = std::move(rArgs);
        if (outPayload) *outPayload = std::move(rPayload);
        return true;
    }

    bool freeBytes(uint64_t &outFree, NSError **error) {
        std::vector<uint8_t> args, payload;
        if (!call(0x0B /* OP_GET_DEVINFO */, nullptr, 0, nullptr, 0, nullptr, &args, &payload, error)) return false;
        const std::vector<uint8_t> &buf = payload.empty() ? args : payload;
        std::vector<std::string> items;
        size_t s = 0;
        for (size_t i = 0; i <= buf.size(); i++) {
            if (i == buf.size() || buf[i] == 0) {
                if (i > s) items.emplace_back(reinterpret_cast<const char *>(&buf[s]), i - s);
                s = i + 1;
            }
        }
        for (size_t i = 0; i + 1 < items.size(); i += 2) {
            if (items[i] == "FSFreeBytes") {
                outFree = uint64_t(std::strtoull(items[i + 1].c_str(), nullptr, 10));
                return true;
            }
        }
        if (error) *error = makeIpaError(63, @"ゲストの空き容量を取得できませんでした。");
        return false;
    }

    bool makeDir(const std::string &path, NSError **error) {
        std::vector<uint8_t> arg(path.begin(), path.end());
        arg.push_back(0);
        NSError *tmpErr = nil;
        if (call(0x09 /* OP_MAKE_DIR */, arg.data(), arg.size(), nullptr, 0, nullptr, nullptr, nullptr, &tmpErr)) return true;
        if (tmpErr && [tmpErr.localizedDescription containsString:@"(19)"]) return true; // already exists
        if (error) *error = tmpErr;
        return false;
    }

    bool removePath(const std::string &path) {
        std::vector<uint8_t> arg(path.begin(), path.end());
        arg.push_back(0);
        return call(0x08 /* OP_REMOVE_PATH */, arg.data(), arg.size(), nullptr, 0, nullptr, nullptr, nullptr, nil);
    }

    bool openWrite(const std::string &path, uint64_t &outHandle, NSError **error) {
        std::vector<uint8_t> arg;
        appendLe64(arg, 3 /* WriteOnly */);
        arg.insert(arg.end(), path.begin(), path.end());
        arg.push_back(0);
        uint64_t op = 0;
        std::vector<uint8_t> rArgs;
        if (!call(0x0D /* OP_FILE_OPEN */, arg.data(), arg.size(), nullptr, 0, &op, &rArgs, nullptr, error)) return false;
        if (op != 0x0E || rArgs.size() < 8) {
            if (error) *error = makeIpaError(64, @"ゲスト側でステージングファイルを開けませんでした。");
            return false;
        }
        outHandle = le64FromPtr(rArgs.data());
        return true;
    }

    bool writeHandle(uint64_t handle, const uint8_t *data, size_t len, NSError **error) {
        std::vector<uint8_t> arg;
        appendLe64(arg, handle);
        return call(0x10 /* OP_FILE_WRITE */, arg.data(), arg.size(), data, len, nullptr, nullptr, nullptr, error);
    }

    void closeHandle(uint64_t handle) {
        std::vector<uint8_t> arg;
        appendLe64(arg, handle);
        (void)call(0x14 /* OP_FILE_CLOSE */, arg.data(), arg.size(), nullptr, 0, nullptr, nullptr, nullptr, nil);
    }
};

} // namespace

@implementation IOSIpaInstaller

+ (void)installIPAFromURL:(NSURL *)ipaURL
                   bridge:(IOSUsbMuxBridge *)bridge
             stateDirPath:(NSString *)stateDirPath
                 progress:(nullable IOSIpaProgressBlock)progress
               completion:(void (^)(IOSIpaInfo * _Nullable info, NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        auto finish = ^(IOSIpaInfo *info, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(info, err);
            });
        };
        auto report = ^BOOL(IOSIpaInstallStage stage, NSString *text, float pct) {
            if (!progress) return YES;
            __block BOOL cont = YES;
            if ([NSThread isMainThread]) {
                cont = progress(stage, text, pct);
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    cont = progress(stage, text, pct);
                });
            }
            return cont;
        };

        if (!ipaURL || !bridge || !stateDirPath.length) {
            finish(nil, makeIpaError(100, @"IPA インストールの引数が不正です。"));
            return;
        }

        report(IOSIpaInstallStageConnecting, @"仮想デバイスへ接続中...", -1.0f);

        BOOL secScoped = [ipaURL startAccessingSecurityScopedResource];
        NSString *localCopyDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ipa-%@", [[NSUUID UUID] UUIDString]]];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:localCopyDir withIntermediateDirectories:YES attributes:nil error:nil];

        auto cleanupTemp = ^{
            [fm removeItemAtPath:localCopyDir error:nil];
            if (secScoped) [ipaURL stopAccessingSecurityScopedResource];
        };

        NSString *sourceTempPath = [localCopyDir stringByAppendingPathComponent:@"Source.ipa"];
        NSError *err = nil;
        if (![fm copyItemAtURL:ipaURL toURL:[NSURL fileURLWithPath:sourceTempPath] error:&err]) {
            cleanupTemp();
            finish(nil, makeIpaError(101, err.localizedDescription ?: @"選択した IPA ファイルを読み込めませんでした。"));
            return;
        }

        NSString *pairingPath = [stateDirPath stringByAppendingPathComponent:@"usb-pairing.plist"];
        GuestConn lockdown;
        NSDictionary *pairRecord = nil;
        GuestTarget target;
        if (!openLockdownSession(bridge, pairingPath, lockdown, &pairRecord, target, ^BOOL{
            return report(IOSIpaInstallStageConnecting, @"仮想画面の「信頼」をタップしてください...", -1.0f);
        }, &err)) {
            cleanupTemp();
            finish(nil, err);
            return;
        }

        if (!report(IOSIpaInstallStagePreflight, @"IPA の互換性を確認中...", -1.0f)) {
            cleanupTemp();
            finish(nil, makeIpaError(102, @"キャンセルされました。"));
            return;
        }

        NSString *preparedPath = [localCopyDir stringByAppendingPathComponent:@"Install.ipa"];
        IOSIpaInfo *info = prepareIpaFile(sourceTempPath, preparedPath, target, &err);
        if (!info) {
            cleanupTemp();
            finish(nil, err);
            return;
        }

        GuestConn afcConn;
        if (!startLockdownService(bridge, lockdown, pairRecord, target, pairingPath, @"com.apple.afc", 20.0, afcConn, &err)) {
            cleanupTemp();
            finish(nil, err);
            return;
        }
        AfcClient afc;
        afc.conn = std::move(afcConn);

        uint64_t guestFree = 0;
        if (!afc.freeBytes(guestFree, &err)) {
            cleanupTemp();
            finish(nil, err);
            return;
        }
        uint64_t needed = info.ipaBytes * 2 + (16ULL << 20);
        if (guestFree < needed) {
            cleanupTemp();
            finish(nil, makeIpaError(103, [NSString stringWithFormat:@"仮想デバイスの空き容量が不足しています（必要: %llu MB / 空き: %llu MB）。",
                                           needed >> 20, guestFree >> 20]));
            return;
        }

        if (!afc.makeDir("PublicStaging", &err)) {
            cleanupTemp();
            finish(nil, err);
            return;
        }
        uint32_t nonce = 0;
        RAND_bytes(reinterpret_cast<uint8_t *>(&nonce), sizeof(nonce));
        std::string remotePath = "PublicStaging/lighttouch-" + std::to_string(nonce) + ".ipa";

        uint64_t afcHandle = 0;
        if (!afc.openWrite(remotePath, afcHandle, &err)) {
            cleanupTemp();
            finish(nil, err);
            return;
        }

        FILE *srcF = fopen(preparedPath.fileSystemRepresentation, "rb");
        if (!srcF) {
            afc.closeHandle(afcHandle);
            afc.removePath(remotePath);
            cleanupTemp();
            finish(nil, makeIpaError(104, @"準備済み IPA を開けませんでした。"));
            return;
        }

        constexpr size_t kChunk = 1u << 20;
        std::vector<uint8_t> buf(kChunk);
        uint64_t sent = 0;
        BOOL cancelled = NO;
        while (true) {
            size_t n = fread(buf.data(), 1, kChunk, srcF);
            if (n == 0) break;
            if (!afc.writeHandle(afcHandle, buf.data(), n, &err)) {
                fclose(srcF);
                afc.closeHandle(afcHandle);
                afc.removePath(remotePath);
                cleanupTemp();
                finish(nil, err);
                return;
            }
            sent += n;
            float frac = info.ipaBytes > 0 ? float(double(sent) / double(info.ipaBytes)) : 0.0f;
            if (!report(IOSIpaInstallStageUploading,
                        [NSString stringWithFormat:@"デバイスへ転送中 (%@)...", info.name], frac)) {
                cancelled = YES;
                break;
            }
        }
        fclose(srcF);
        afc.closeHandle(afcHandle);
        if (cancelled) {
            afc.removePath(remotePath);
            cleanupTemp();
            finish(nil, makeIpaError(102, @"キャンセルされました。"));
            return;
        }

        GuestConn instConn;
        if (!startLockdownService(bridge, lockdown, pairRecord, target, pairingPath,
                                  @"com.apple.mobile.installation_proxy", 300.0, instConn, &err)) {
            afc.removePath(remotePath);
            cleanupTemp();
            finish(nil, err);
            return;
        }

        report(IOSIpaInstallStageSubmitted, [NSString stringWithFormat:@"%@ をインストール中...", info.name], -1.0f);
        if (!instConn.sendPlist(@{
            @"Command": @"Install",
            @"PackagePath": [NSString stringWithUTF8String:remotePath.c_str()],
            @"ClientOptions": @{},
        }, &err)) {
            afc.removePath(remotePath);
            cleanupTemp();
            finish(nil, err);
            return;
        }

        bool installComplete = false;
        while (true) {
            NSDictionary *reply = instConn.receivePlist(&err);
            if (!reply) break;
            NSString *instErr = [reply[@"Error"] isKindOfClass:[NSString class]] ? reply[@"Error"] : nil;
            if (instErr.length > 0) {
                NSString *desc = [reply[@"ErrorDescription"] isKindOfClass:[NSString class]] ? reply[@"ErrorDescription"] : instErr;
                err = makeIpaError(105, desc);
                break;
            }
            NSString *status = [reply[@"Status"] isKindOfClass:[NSString class]] ? reply[@"Status"] : @"Installing";
            if ([status isEqualToString:@"Complete"]) {
                installComplete = true;
                break;
            }
            NSNumber *pctNum = [reply[@"PercentComplete"] isKindOfClass:[NSNumber class]] ? reply[@"PercentComplete"] : nil;
            float pct = pctNum ? float([pctNum doubleValue] / 100.0) : -1.0f;
            report(IOSIpaInstallStageInstalling,
                   [NSString stringWithFormat:@"%@ をインストール中 (%@)...", info.name, status], pct);
        }

        afc.removePath(remotePath);
        cleanupTemp();
        if (!installComplete) {
            finish(nil, err ?: makeIpaError(105, @"インストール中に予期しない切断が発生しました。"));
            return;
        }

        report(IOSIpaInstallStageVerifying, @"インストール完了を確認中...", 1.0f);
        GuestConn verifyConn;
        if (startLockdownService(bridge, lockdown, pairRecord, target, pairingPath,
                                 @"com.apple.mobile.installation_proxy", 60.0, verifyConn, nil)) {
            if (verifyConn.sendPlist(@{
                @"Command": @"Browse",
                @"ClientOptions": @{@"ApplicationType": @"User"},
            }, nil)) {
                bool found = false;
                while (NSDictionary *bReply = verifyConn.receivePlist(nil)) {
                    NSArray *list = [bReply[@"CurrentList"] isKindOfClass:[NSArray class]] ? bReply[@"CurrentList"] : nil;
                    for (id item in list) {
                        if ([item isKindOfClass:[NSDictionary class]] &&
                            [[item objectForKey:@"CFBundleIdentifier"] isEqualToString:info.bundleId]) {
                            found = true;
                        }
                    }
                    NSString *st = [bReply[@"Status"] isKindOfClass:[NSString class]] ? bReply[@"Status"] : nil;
                    if (!st || [st isEqualToString:@"Complete"]) break;
                }
                if (!found) {
                    finish(nil, makeIpaError(106, @"インストール完了応答がありましたがアプリ一覧に反映されませんでした。"));
                    return;
                }
            }
        }

        finish(info, nil);
    });
}

@end

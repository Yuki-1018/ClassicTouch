#import "ADBKey.h"
#import "RSAPublicKey.hpp"

#include <array>
#include <cstdint>
#include <span>

static NSString *const kAEADBKeyDomain = @"ClassicTouch.ADB.Key";
static NSString *const kAEADBKeyTagString = @"com.classictouch.adb.rsa2048";

static NSError *MakeKeyError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kAEADBKeyDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"ADB key error"}];
}

static BOOL ParseDERLength(const uint8_t *bytes, size_t total, size_t *offset, size_t *outLen) {
    if (*offset >= total) return NO;
    uint8_t first = bytes[(*offset)++];
    if ((first & 0x80u) == 0) {
        *outLen = first;
        return (*offset + *outLen <= total);
    }
    size_t count = first & 0x7Fu;
    if (count == 0 || count > 4 || *offset + count > total) return NO;
    size_t val = 0;
    for (size_t i = 0; i < count; ++i) {
        val = (val << 8) | bytes[(*offset)++];
    }
    *outLen = val;
    return (*offset + *outLen <= total);
}

static BOOL ReadDERInteger(const uint8_t *bytes, size_t total, size_t *offset, const uint8_t **outPtr, size_t *outLen) {
    if (*offset >= total || bytes[(*offset)++] != 0x02) return NO;
    size_t len = 0;
    if (!ParseDERLength(bytes, total, offset, &len)) return NO;
    const uint8_t *p = bytes + *offset;
    *offset += len;
    while (len > 1 && *p == 0x00) {
        ++p;
        --len;
    }
    *outPtr = p;
    *outLen = len;
    return YES;
}

@implementation AEADBKey

+ (nullable SecKeyRef)loadOrCreatePrivateKeyWithError:(NSError * _Nullable * _Nullable)error {
    NSData *tagData = [kAEADBKeyTagString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrApplicationTag: tagData,
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecReturnRef: @YES,
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result != NULL) {
        return (SecKeyRef)result;
    }
    if (result != NULL) {
        CFRelease(result);
        result = NULL;
    }

    NSDictionary *privAttrs = @{
        (__bridge id)kSecAttrIsPermanent: @YES,
        (__bridge id)kSecAttrApplicationTag: tagData,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    NSDictionary *params = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeySizeInBits: @2048,
        (__bridge id)kSecPrivateKeyAttrs: privAttrs,
    };

    CFErrorRef cfErr = NULL;
    SecKeyRef created = SecKeyCreateRandomKey((__bridge CFDictionaryRef)params, &cfErr);
    if (created != NULL) {
        if (cfErr) CFRelease(cfErr);
        return created;
    }

    // Fallback: transient in-memory key if Keychain add is restricted in simulator/entitlements.
    if (cfErr) {
        CFRelease(cfErr);
        cfErr = NULL;
    }
    NSDictionary *ephemeralParams = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeySizeInBits: @2048,
    };
    created = SecKeyCreateRandomKey((__bridge CFDictionaryRef)ephemeralParams, &cfErr);
    if (created != NULL) {
        if (cfErr) CFRelease(cfErr);
        return created;
    }
    if (error) {
        NSError *err = CFBridgingRelease(cfErr);
        *error = err ?: MakeKeyError(-1, @"Failed to generate ADB RSA-2048 key");
    } else if (cfErr) {
        CFRelease(cfErr);
    }
    return NULL;
}

+ (nullable NSData *)androidPublicKeyForPrivateKey:(SecKeyRef)privateKey
                                             error:(NSError * _Nullable * _Nullable)error {
    if (!privateKey) {
        if (error) *error = MakeKeyError(-2, @"Missing ADB private key");
        return nil;
    }
    SecKeyRef pubKey = SecKeyCopyPublicKey(privateKey);
    if (!pubKey) {
        if (error) *error = MakeKeyError(-3, @"Failed to derive ADB public key");
        return nil;
    }

    CFErrorRef cfErr = NULL;
    NSData *der = CFBridgingRelease(SecKeyCopyExternalRepresentation(pubKey, &cfErr));
    CFRelease(pubKey);
    if (!der) {
        if (error) {
            NSError *err = CFBridgingRelease(cfErr);
            *error = err ?: MakeKeyError(-4, @"Failed to export ADB public key");
        } else if (cfErr) {
            CFRelease(cfErr);
        }
        return nil;
    }

    const uint8_t *bytes = (const uint8_t *)der.bytes;
    size_t total = der.length;
    size_t offset = 0;
    size_t seqLen = 0;
    if (total == 0 || bytes[offset++] != 0x30 || !ParseDERLength(bytes, total, &offset, &seqLen)) {
        if (error) *error = MakeKeyError(-5, @"Invalid RSA public key ASN.1 header");
        return nil;
    }

    const uint8_t *modPtr = NULL;
    const uint8_t *expPtr = NULL;
    size_t modLen = 0, expLen = 0;
    if (!ReadDERInteger(bytes, total, &offset, &modPtr, &modLen) ||
        !ReadDERInteger(bytes, total, &offset, &expPtr, &expLen)) {
        if (error) *error = MakeKeyError(-6, @"Invalid RSA public key ASN.1 body");
        return nil;
    }

    std::array<uint8_t, 256> modulus{};
    if (modLen > modulus.size()) {
        if (error) *error = MakeKeyError(-7, @"Unexpected RSA modulus size");
        return nil;
    }
    std::copy_n(modPtr, modLen, modulus.data() + (modulus.size() - modLen));

    uint32_t exponent = 0;
    if (expLen == 0 || expLen > 4) {
        if (error) *error = MakeKeyError(-8, @"Unexpected RSA exponent size");
        return nil;
    }
    for (size_t i = 0; i < expLen; ++i) {
        exponent = (exponent << 8) | expPtr[i];
    }

    auto bin = emu::adb::androidPublicKey(modulus, exponent);
    NSData *rawBin = [NSData dataWithBytes:bin.data() length:bin.size()];
    NSString *b64 = [rawBin base64EncodedStringWithOptions:0];
    NSString *wire = [b64 stringByAppendingString:@" classictouch@ios"];
    NSMutableData *out = [[wire dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    const uint8_t nul = 0;
    [out appendBytes:&nul length:1];
    return out;
}

+ (nullable NSData *)signToken:(NSData *)token
                withPrivateKey:(SecKeyRef)privateKey
                         error:(NSError * _Nullable * _Nullable)error {
    if (!privateKey || token.length != 20) {
        if (error) *error = MakeKeyError(-9, @"Invalid ADB auth token or key");
        return nil;
    }
    CFErrorRef cfErr = NULL;
    NSData *sig = CFBridgingRelease(SecKeyCreateSignature(
        privateKey,
        kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1,
        (__bridge CFDataRef)token,
        &cfErr));
    if (!sig) {
        if (error) {
            NSError *err = CFBridgingRelease(cfErr);
            *error = err ?: MakeKeyError(-10, @"Failed to sign ADB auth token");
        } else if (cfErr) {
            CFRelease(cfErr);
        }
        return nil;
    }
    return sig;
}

@end

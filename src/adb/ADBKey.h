#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

@interface AEADBKey : NSObject

+ (nullable SecKeyRef)loadOrCreatePrivateKeyWithError:(NSError * _Nullable * _Nullable)error CF_RETURNS_RETAINED;
+ (nullable NSData *)androidPublicKeyForPrivateKey:(SecKeyRef)privateKey
                                             error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSData *)signToken:(NSData *)token
                withPrivateKey:(SecKeyRef)privateKey
                         error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
